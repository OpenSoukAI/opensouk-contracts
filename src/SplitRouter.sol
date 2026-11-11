// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISplitRouter} from "./interfaces/ISplitRouter.sol";
import {ICommissionEscrow} from "./interfaces/ICommissionEscrow.sol";
import {IReviewRegistry} from "./interfaces/IReviewRegistry.sol";
import {IMerchantRegistry} from "./interfaces/IMerchantRegistry.sol";
import {IProductRegistry} from "./interfaces/IProductRegistry.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IProtocolAddressRegistry} from "./interfaces/IProtocolAddressRegistry.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC3009} from "./interfaces/IERC3009.sol";
import {SplitMath} from "./libraries/SplitMath.sol";
import {ProtocolConstants} from "./libraries/ProtocolConstants.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title SplitRouter
/// @notice The protocol's single payment entry point. Takes a buyer's USDC and splits it
///         atomically four ways: reviewer (immediate commission), CommissionEscrow (held-back
///         commission + buyer cashback), treasury (platform fee), merchant (net).
/// @dev Two rails share one split core (`_settleAndDeposit`) and one formula (`SplitMath`):
///
///      route()        x402 rail. `FACILITATOR_ROLE` only. The facilitator submits the buyer's
///                     ERC-3009 `receiveWithAuthorization` signature; this contract pulls the
///                     USDC from the buyer and splits in the same transaction. ALL validation
///                     runs before the pull, so a revert strands nothing.
///
///      splitCharge()  single-charge rail. Permissionless. The buyer has ALREADY transferred
///                     USDC to this contract by a plain ERC-20 transfer; anyone then submits the
///                     oracle-signed EIP-712 `ChargeAttestation` that says how to split it.
///                     Because funds are pre-pooled, a revert after delivery parks them here
///                     until admin `recoverUSDC()` (with the charge's `paymentRef`) — several checks are therefore softened on
///                     this rail (see `_validateSettlement` and the cashback clamp).
///
///      Attribution inputs: `reviewId` (0 = no referral), `buyerAgentId` (SENTINEL_BUYER = no
///      identity), merchant/product, `commissionMultiplierBps` (immediate vs held-back split)
///      and `lockedCashbackBps` (buyer rebate as a share of commission) come from calldata /
///      the attestation. `commissionBps` does NOT — it is read LIVE from ProductRegistry at
///      settlement and clamped to `10_000 - platformFeeBps`, and neither does the escrowed
///      `productType` — it is read from the same ProductRegistry record, so no caller can
///      choose it. `platformFeeBps` and the cashback cap `maxCashbackBpsOfCommission` are
///      admin-set storage on this contract.
///
///      Attribution is MERCHANT-scoped, not product-scoped: the referenced review must belong to
///      the purchase's merchant (`ReviewMerchantMismatch`), but may be for a different product
///      of that merchant — a review of product A earns commission on a purchase of product B.
///
///      Trust: the facilitator and the oracle signer are trusted for attribution correctness
///      (which review earns, which agent bought); the on-chain checks bound the VALUE they can
///      misdirect (SplitMath caps, live merchant/product state) but cannot verify off-chain facts.
///      `route()` is deliberately not `nonReentrant`: role-gated, one atomic ERC-3009 pull, and
///      USDC has no transfer hooks. `splitCharge()` IS `nonReentrant` because it is permissionless.
///      There is no pause on this contract: the x402 rail stops by revoking `FACILITATOR_ROLE`,
///      the charge rail stops by pausing CommissionEscrow (its `deposit()` is `whenNotPaused`).
///      Peers are resolved live from PAR except the identity registry (immutable, README §4).
contract SplitRouter is ISplitRouter, AccessControl, ReentrancyGuardTransient, EIP712 {
    using SafeERC20 for IERC20;
    /// @notice Only holder(s) may call `route()`. Revoking it halts the x402 rail instantly.
    bytes32 public constant FACILITATOR_ROLE = keccak256("FACILITATOR_ROLE");
    /// @notice Signer role for `ChargeAttestation`. Not a caller role: `splitCharge()` is
    ///         permissionless and checks that the RECOVERED signer holds this role. Two holders
    ///         may coexist during a key handover.
    bytes32 public constant ORACLE_SIGNER_ROLE = keccak256("ORACLE_SIGNER_ROLE");
    /// @dev Basis-point denominator, shared with SplitMath.
    uint256 private constant BPS_DENOM = 10_000;
    /// @notice Ceiling for `platformFeeBps` (20%), enforced by the constructor and
    ///         `setPlatformFeeBps`. Bounds the share the protocol can take from a merchant's sale.
    uint16 public constant MAX_PLATFORM_FEE_BPS = 2_000;

    /// @inheritdoc ISplitRouter
    uint256 public constant SENTINEL_BUYER = ProtocolConstants.SENTINEL_BUYER;

    /// @dev EIP-712 type hash of the oracle attestation consumed by `splitCharge()`. Domain is
    ///      `("SplitRouter", "1")` bound to chain id + this address. Field order must match the
    ///      backend signer byte-for-byte. Note there is NO deadline field: an attestation is a
    ///      bearer instrument until its `paymentRef` is consumed (README §9).
    bytes32 private constant CHARGE_ATTESTATION_TYPEHASH = keccak256(
        "ChargeAttestation(bytes32 paymentRef,uint256 amount,address payer,uint256 reviewId,uint256 buyerAgentId,uint256 merchantId,bytes32 productId,uint16 commissionMultiplierBps,uint16 lockedCashbackBps)"
    );

    /// @dev Single-use guard for one-off charges, keyed by paymentRef (the charge tx hash).
    mapping(bytes32 => bool) private _chargeSettled;

    /// @dev Protocol address registry; every peer except the identity registry is read from it live.
    IProtocolAddressRegistry private immutable _PROTOCOL;
    /// @dev Settlement token; must implement ERC-3009 for the x402 rail (Circle USDC does).
    IERC20 private immutable _USDC;

    /// @dev ERC-8004 identity registry, cached at deploy (README §4).
    IIdentityRegistry private immutable _AGENT_REGISTRY;

    /// @dev Platform fee in bps of gross; admin-set, bounded to [0, 10_000]. Read at settlement.
    uint16 private _platformFeeBps;
    /// @dev Cap on `lockedCashbackBps` (share OF COMMISSION); admin-set, bounded to [0, 4_000].
    uint16 private _maxCashbackBpsOfCommission;

    // Fields grouped into a struct (1 stack slot) to avoid stack-too-deep in _settleAndDeposit's
    // 10-arg deposit() call — Attribution memory alone was not enough to keep the build off
    // via-ir; see _settleAndDeposit.
    struct _Cached {
        uint256 reviewId;
        uint256 buyerAgentId;
        address buyer;
        uint256 merchantId;
        bytes32 productId;
        uint256 grossAmount;
        uint8 productType;
    }

    /// @param protocolAddressRegistry ProtocolAddressRegistry. `AGENT_REGISTRY` must already be set.
    /// @param admin                   Receives `DEFAULT_ADMIN_ROLE`; must grant `FACILITATOR_ROLE`
    ///                                and `ORACLE_SIGNER_ROLE` separately.
    /// @param usdcAddress             ERC-20 + ERC-3009 token. Not validated.
    /// @param platformFeeBps_         Initial platform fee; `> MAX_PLATFORM_FEE_BPS` reverts `FeeTooHigh`.
    /// @dev The cashback cap starts at its ceiling `MULTIPLIER_MIN` (4_000 = 40% of commission).
    ///      Emits `PlatformFeeUpdated` and `MaxCashbackBpsUpdated` with `oldBps == 0` so indexers
    ///      see the initial values in the same shape as a later setter call.
    constructor(address protocolAddressRegistry, address admin, address usdcAddress, uint16 platformFeeBps_)
        EIP712("SplitRouter", "1")
    {
        if (platformFeeBps_ > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh(platformFeeBps_);
        _PROTOCOL = IProtocolAddressRegistry(protocolAddressRegistry);
        _USDC = IERC20(usdcAddress);
        _AGENT_REGISTRY = IIdentityRegistry(
            IProtocolAddressRegistry(protocolAddressRegistry)
                .getAddress(IProtocolAddressRegistry(protocolAddressRegistry).AGENT_REGISTRY())
        );
        _platformFeeBps = platformFeeBps_;
        emit PlatformFeeUpdated(0, platformFeeBps_);
        _maxCashbackBpsOfCommission = SplitMath.MULTIPLIER_MIN;
        emit MaxCashbackBpsUpdated(0, SplitMath.MULTIPLIER_MIN);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // =========================================================================
    // x402 facilitator — write
    // =========================================================================

    /// @inheritdoc ISplitRouter
    /// @dev x402 rail. Order is validate → pull → split, so every revert path except those
    ///      inside `_routeInner` happens before any USDC moves, and `_routeInner` reverts roll
    ///      back the pull atomically. The ERC-3009 authorization is signed by the buyer for
    ///      exactly `grossAmount` to THIS contract; the token contract enforces the signature,
    ///      validity window and nonce — this contract does not inspect them. Rate inputs in
    ///      `routeParams` are trusted from the facilitator but bounded by `SplitMath` (a cap
    ///      violation reverts here, unlike the charge rail which clamps). Not `nonReentrant` —
    ///      see contract header.
    function route(RouteParams calldata routeParams, ERC3009Params calldata erc3009auth)
        external
        onlyRole(FACILITATOR_ROLE)
        returns (uint256 escrowId)
    {
        if (routeParams.grossAmount == 0) revert ZeroAmount();

        Attribution memory attr = _attributionOf(routeParams);
        _validateEntry(routeParams.buyer, attr);

        // Pull the buyer's USDC. `to` is pinned to address(this) so an authorization signed for
        // this router cannot be redirected by the facilitator.
        IERC3009(address(_USDC))
            .receiveWithAuthorization(
                routeParams.buyer,
                address(this),
                routeParams.grossAmount,
                erc3009auth.validAfter,
                erc3009auth.validBefore,
                erc3009auth.nonce,
                erc3009auth.v,
                erc3009auth.r,
                erc3009auth.s
            );

        escrowId = _routeInner(routeParams, attr);
    }

    /// @dev Second half of route() extracted to avoid stack-too-deep in the outer frame.
    ///      Runs the shared split core and emits the x402-rail event.
    function _routeInner(RouteParams calldata routeParams, Attribution memory attr) private returns (uint256 escrowId) {
        SplitMath.Split memory s;
        (escrowId, s) = _settleAndDeposit(attr, routeParams.grossAmount, routeParams.buyer);

        emit PaymentRouted(
            escrowId,
            attr.buyerAgentId,
            attr.reviewId,
            routeParams.buyer,
            attr.merchantId,
            attr.productId,
            routeParams.grossAmount,
            s.reviewerImmediateNet,
            s.heldBack,
            s.platformFeeAmt,
            s.cashbackAmt,
            s.merchantAmt
        );
    }

    /// @dev Entry validation for the x402 rail (`route()`). Zero-amount is checked by the caller.
    ///      Strict form: includes the buyer-agent ownership check that the charge rail omits,
    ///      because here nothing has been pulled yet and a revert costs the buyer nothing.
    function _validateEntry(address buyer, Attribution memory a) private view {
        // A zero buyer would persist buyerWallet == 0 on the escrow (unbindable). SENTINEL_BUYER
        // skips the ownerOf check, so this must be guarded explicitly.
        if (buyer == address(0)) revert ZeroBuyerAddress();

        // Agent-less buyer: a SENTINEL_BUYER agent id skips ONLY the
        // buyer-ownership check. The paying wallet is still recorded on the escrow.
        // The buyer must control the agent: its NFT owner or its configured agentWallet.
        if (a.buyerAgentId != SENTINEL_BUYER && !_isAgentController(a.buyerAgentId, buyer)) {
            revert InvalidBuyerAgent(a.buyerAgentId, buyer);
        }

        _validateActiveState(a);
    }

    /// @dev Validation for the MPP charge rail (`splitCharge()`), which runs AFTER the buyer's funds
    ///      have already been delivered to this router and the merchant has served the resource.
    ///      Every revert here parks those funds until admin recovery, so this form deliberately
    ///      OMITS the buyer-agent `ownerOf` re-check that `_validateEntry` keeps:
    ///      that check protects escrow-record bindability rather than gating the sale, it is
    ///      bypassed entirely by SENTINEL_BUYER, and a buyer transferring their own agent NFT after
    ///      paying would otherwise brick a completed sale. The payer wallet is recorded on the
    ///      escrow either way, and the oracle checks `ownerOf` at attestation time — the only
    ///      moment it can be checked correctly.
    function _validateSettlement(address payer, Attribution memory a) private view {
        // A zero payer would persist buyerWallet == 0 on the escrow (unbindable).
        if (payer == address(0)) revert ZeroBuyerAddress();

        _validateActiveState(a);
    }

    /// @dev Merchant + product active state, shared by both rails. Both are resolved live from
    ///      PAR and both fold in suspension (merchant) and deactivation (product). Retained on
    ///      the charge rail even though the oracle also checks at attestation time — defence in
    ///      depth against a compromised or lagging oracle (README §9).
    function _validateActiveState(Attribution memory a) private view {
        if (!IMerchantRegistry(_PROTOCOL.getAddress(_PROTOCOL.MERCHANT_REGISTRY())).isActive(a.merchantId)) {
            revert MerchantNotActive(a.merchantId);
        }

        if (!IProductRegistry(_PROTOCOL.getAddress(_PROTOCOL.PRODUCT_REGISTRY()))
                .isProductActive(a.merchantId, a.productId)) {
            revert ProductNotActive(a.merchantId, a.productId);
        }
    }

    /// @dev Projects RouteParams onto the rail-independent Attribution struct.
    ///      (`grossAmount` and `buyer` are carried separately; they are not attribution.)
    function _attributionOf(RouteParams calldata p) private pure returns (Attribution memory) {
        return Attribution({
            reviewId: p.reviewId,
            buyerAgentId: p.buyerAgentId,
            merchantId: p.merchantId,
            productId: p.productId,
            commissionMultiplierBps: p.commissionMultiplierBps,
            lockedCashbackBps: p.lockedCashbackBps
        });
    }

    /// @dev Event-less split core shared by route() and splitCharge(). Splits `amount`, transfers
    ///      the four ways (reviewer / escrow held-back+cashback / treasury / merchant) and creates
    ///      the escrow record. Callers emit their own rail-specific event.
    ///
    ///      Preconditions (caller's job): `amount > 0`, active-state validated, and `amount` USDC
    ///      already held by this contract (pulled by route(), pre-delivered for splitCharge()).
    ///
    ///      Transfer order: reviewer immediate net → escrow (held-back + cashback) → deposit()
    ///      → treasury fee → merchant net. The escrow transfer precedes `deposit()` because the
    ///      escrow trusts (does not check) that it was funded. Value conservation
    ///      (`reviewerImmediateNet + heldBack + cashbackAmt + platformFeeAmt + merchantAmt ==
    ///      amount`) is a `SplitMath` property covered by the fuzz + invariant suites.
    ///
    ///      Reviewer resolution: `reviewId == 0` means "no referral". Such a purchase settles
    ///      with zero commission (`_computeSplitFor`), so the commission stays with the merchant,
    ///      and the escrow records `SENTINEL_REVIEWER` rather than agent 0, which is a real
    ///      ERC-8004 identity. `MissingReviewerForCommission` is therefore unreachable; it stays
    ///      as the backstop that no commission is ever escrowed under the sentinel. A `reviewId`
    ///      that does not exist reverts inside `ReviewRegistry.getReview`; one for another
    ///      merchant reverts `ReviewMerchantMismatch` (the product may differ — see the contract
    ///      header).
    function _settleAndDeposit(Attribution memory a, uint256 amount, address buyer)
        private
        returns (uint256 escrowId, SplitMath.Split memory s)
    {
        // Grouped into a memory struct (1 stack slot) to avoid stack-too-deep when building the
        // 10-arg deposit() call below.
        _Cached memory c = _Cached({
            reviewId: a.reviewId,
            buyerAgentId: a.buyerAgentId,
            buyer: buyer,
            merchantId: a.merchantId,
            productId: a.productId,
            grossAmount: amount,
            productType: 0 // set from ProductRegistry by _computeSplitFor below
        });

        uint256 reviewerAgentId = ProtocolConstants.SENTINEL_REVIEWER;
        if (c.reviewId != 0) {
            // Reviewer is whoever authored the referenced review; read live from ReviewRegistry.
            IReviewRegistry.Review memory r =
                IReviewRegistry(_PROTOCOL.getAddress(_PROTOCOL.REVIEW_REGISTRY())).getReview(c.reviewId);
            if (r.merchantId != c.merchantId) revert ReviewMerchantMismatch(c.reviewId, r.merchantId, c.merchantId);
            reviewerAgentId = r.agentId;
        }

        (s, c.productType) = _computeSplitFor(c.grossAmount, a);

        address escrowAddr = _PROTOCOL.getAddress(_PROTOCOL.ESCROW());

        // Unreachable for reviewId=0 (commission is zeroed in _computeSplitFor); kept as the
        // backstop. Guards heldBack too: integer division can make immediateCommission=0 while
        // heldBack>0.
        if (s.immediateCommission > 0 || s.heldBack > 0) {
            if (c.reviewId == 0) revert MissingReviewerForCommission();
            if (s.reviewerImmediateNet > 0) {
                // Reviewer receives immediate commission MINUS the buyer's cashback: cashback is
                // reviewer-funded and parked in escrow until the buyer reviews (or the window ends).
                // Reverts if the reviewer's wallet is blocked, by design: on route() nothing has
                // been pulled yet, so the sale simply fails and buyers use another ref link. On the
                // charge rail the facilitator and the settlement worker both refuse a charge whose
                // reviewer wallet is blocked, so it never reaches this transfer.
                _safeTransfer(_resolveWallet(reviewerAgentId), s.reviewerImmediateNet);
            }
        }

        // Transfer held-back + cashback to escrow before calling deposit.
        if (s.heldBack + s.cashbackAmt > 0) _safeTransfer(escrowAddr, s.heldBack + s.cashbackAmt);

        // deposit() checks msg.sender == PAR SPLIT_ROUTER, so a stale/replaced router reverts here.
        escrowId = ICommissionEscrow(escrowAddr)
            .deposit(
                reviewerAgentId,
                c.buyerAgentId,
                c.buyer,
                c.merchantId,
                c.productId,
                c.productType,
                uint128(s.heldBack), // amounts are bounded by grossAmount (uint256) — a >uint128 purchase would truncate; USDC supply makes this unreachable
                uint128(s.cashbackAmt),
                uint128(c.grossAmount),
                c.reviewId
            );

        if (s.platformFeeAmt > 0) _safeTransfer(_PROTOCOL.getAddress(_PROTOCOL.TREASURY()), s.platformFeeAmt);
        // Merchant is an identity too: paid to its agentWallet if set, else the NFT owner.
        if (s.merchantAmt > 0) _safeTransfer(_resolveWallet(c.merchantId), s.merchantAmt);
    }

    // =========================================================================
    // MPP charge — write (permissionless)
    // =========================================================================

    /// @dev Recovers the EIP-712 signer of a `ChargeAttestation` and requires it to hold
    ///      `ORACLE_SIGNER_ROLE`. `ECDSA.recover` reverts on malformed signatures, so a garbage
    ///      signature can never recover to `address(0)` and pass a role check. Every field of
    ///      the attestation (including `payer` and `amount`) is under the signature, so the
    ///      submitter cannot alter any of them.
    function _verifyChargeAttestation(
        bytes32 paymentRef,
        uint256 amount,
        address payer,
        Attribution calldata attr,
        bytes calldata oracleSig
    ) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                CHARGE_ATTESTATION_TYPEHASH,
                paymentRef,
                amount,
                payer,
                attr.reviewId,
                attr.buyerAgentId,
                attr.merchantId,
                attr.productId,
                attr.commissionMultiplierBps,
                attr.lockedCashbackBps
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), oracleSig);
        if (!hasRole(ORACLE_SIGNER_ROLE, signer)) revert OracleAttestationInvalid();
    }

    /// @inheritdoc ISplitRouter
    /// @dev Charge rail. Anyone may submit; authority comes from the oracle signature, not the
    ///      caller. Order: zero-amount → replay (`paymentRef`) → signature → cashback clamp →
    ///      active-state → pooled balance ≥ amount → mark settled → split. `paymentRef` is
    ///      burned BEFORE the split (effects before interactions); a revert inside the split
    ///      rolls the burn back, so a failed attempt can be retried once the cause is fixed.
    ///
    ///      Pooled-funds caveat: the balance check proves this contract holds ENOUGH USDC, not
    ///      that it holds THIS charge's USDC. Correct attribution rests on the oracle attesting
    ///      only after confirming the specific transfer at depth (README §9). Value is always
    ///      conserved; only attribution can be wrong.
    function splitCharge(
        bytes32 paymentRef,
        uint256 amount,
        address payer,
        Attribution calldata attr,
        bytes calldata oracleSig
    ) external nonReentrant returns (uint256 escrowId) {
        if (amount == 0) revert ZeroAmount();
        if (_chargeSettled[paymentRef]) revert ChargeAlreadySettled(paymentRef);

        _verifyChargeAttestation(paymentRef, amount, payer, attr, oracleSig);

        // `calldata -> memory` is a copy, so mutating `a` below does NOT alias the caller's calldata.
        Attribution memory a = attr;

        // Charge rail only: an admin lowering the cap after the oracle attested must not brick a
        // sale whose funds are already here — a revert would park them until admin recovery
        // route() keeps reverting with CashbackExceedsCommissionCap because its revert
        // precedes the ERC-3009 pull, so nothing is stranded there. Mirrors the existing commission
        // clamp's rationale. Clamped HERE rather than in the shared `_computeSplitFor`, which would
        // invert two reviewed route() tests for no benefit.
        if (a.lockedCashbackBps > _maxCashbackBpsOfCommission) {
            a.lockedCashbackBps = _maxCashbackBpsOfCommission;
        }

        _validateSettlement(payer, a);

        // Funds were delivered by the buyer's standard MPP charge transfer
        // (pooled here, no per-charge accounting).
        // Correct attribution depends on the oracle signing a ChargeAttestation
        // only after confirming that specific transfer at depth.
        if (_USDC.balanceOf(address(this)) < amount) revert InsufficientChargeBalance();

        _chargeSettled[paymentRef] = true; // effects before interactions

        SplitMath.Split memory s;
        (escrowId, s) = _settleAndDeposit(a, amount, payer);

        emit ChargeSettled(
            paymentRef,
            escrowId,
            a.buyerAgentId,
            payer,
            amount,
            s.reviewerImmediateNet,
            s.heldBack,
            s.platformFeeAmt,
            s.cashbackAmt,
            s.merchantAmt
        );
    }

    // =========================================================================
    // Admin — write
    // =========================================================================

    /// @inheritdoc ISplitRouter
    /// @dev Admin only. Intended for funds parked by a charge-rail revert or sent here by
    ///      mistake. There is no per-charge accounting, so this CAN move pooled pre-settlement
    ///      charge principal (accepted, MPP-02); the event makes any such move observable.
    ///      `amount` is not bounded — an over-large amount simply fails inside `safeTransfer`.
    ///      A non-zero `paymentRef` refunds that parked charge: the ref is marked settled BEFORE
    ///      the transfer, so its attestation can never later settle against another buyer's
    ///      pooled funds. `amount == 0` with a ref only invalidates it (e.g. a charge refunded
    ///      earlier without one).
    function recoverUSDC(address to, uint256 amount, bytes32 paymentRef) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroRecipientAddress();
        if (paymentRef != bytes32(0)) {
            if (_chargeSettled[paymentRef]) revert ChargeAlreadySettled(paymentRef);
            _chargeSettled[paymentRef] = true;
            emit ChargeRefunded(paymentRef, to, amount);
        }
        if (amount > 0) _safeTransfer(to, amount);
        emit USDCRecovered(to, amount);
    }

    /// @inheritdoc ISplitRouter
    /// @dev Admin only. Bounded to [0, MAX_PLATFORM_FEE_BPS]. Takes effect for every subsequent settlement on
    ///      both rails (the fee is not locked into attestations). Also moves the live commission
    ///      clamp `10_000 - fee` in `_computeSplitFor`.
    function setPlatformFeeBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh(newBps);
        uint16 old = _platformFeeBps;
        _platformFeeBps = newBps;
        emit PlatformFeeUpdated(old, newBps);
    }

    /// @inheritdoc ISplitRouter
    /// @dev Admin only. Bounded to [0, MULTIPLIER_MIN = 4_000]: because the immediate share of
    ///      commission is at least 40% and cashback is at most 40% of commission, cashback can
    ///      always be funded from the reviewer's immediate cut. Lowering the cap below an
    ///      already-authorized `lockedCashbackBps` makes `route()` revert but is CLAMPED on
    ///      `splitCharge()` (see there). Reuses SplitMath's error so the bound has one definition.
    function setMaxCashbackBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > SplitMath.MULTIPLIER_MIN) revert SplitMath.CapAboveCeiling(newBps);
        uint16 old = _maxCashbackBpsOfCommission;
        _maxCashbackBpsOfCommission = newBps;
        emit MaxCashbackBpsUpdated(old, newBps);
    }

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @inheritdoc ISplitRouter
    function platformFeeBps() external view returns (uint16) {
        return _platformFeeBps;
    }

    /// @inheritdoc ISplitRouter
    function maxCashbackBpsOfCommission() external view returns (uint16) {
        return _maxCashbackBpsOfCommission;
    }

    /// @inheritdoc ISplitRouter
    function usdc() external view returns (address) {
        return address(_USDC);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Reads the product once via `getSettlementTerms` (live commission rate, clamped, and
    ///      `productType`) and runs the shared formula. Reverts inside `getSettlementTerms` for a
    ///      product that does not exist. Every SplitMath constraint
    ///      (rates ≤ 100%, multiplier range, cashback cap) is enforced here for BOTH rails; the
    ///      charge rail pre-clamps cashback so only the multiplier check can still revert there.
    function _computeSplitFor(uint256 amount, Attribution memory a)
        private
        view
        returns (SplitMath.Split memory s, uint8 productType)
    {
        // Commission is read live, the merchant's current rate applies
        (uint16 commissionBps, IProductRegistry.ProductType pt) = IProductRegistry(
                _PROTOCOL.getAddress(_PROTOCOL.PRODUCT_REGISTRY())
            ).getSettlementTerms(a.merchantId, a.productId);
        productType = uint8(pt);
        if (a.reviewId == 0) commissionBps = 0;
        // Clamp so commission + platform fee can never exceed 100% — a merchant raising commission
        // after authorization must not brick settlement (SplitMath would revert RatesExceedTotal).
        // No-op for normal rates; only bites in the pathological >(100%-fee) regime.
        // The uint16 cast is safe: _platformFeeBps ≤ MAX_PLATFORM_FEE_BPS (< BPS_DENOM) is enforced
        // by the constructor and setPlatformFeeBps, so the difference is in [0, 10_000]. (forge-lint unsafe-typecast, see README.)
        uint16 maxCommissionBps = uint16(BPS_DENOM - _platformFeeBps);
        if (commissionBps > maxCommissionBps) commissionBps = maxCommissionBps;

        s = SplitMath.compute(
            amount,
            commissionBps,
            a.lockedCashbackBps,
            _platformFeeBps,
            a.commissionMultiplierBps,
            _maxCashbackBpsOfCommission
        );
    }

    /// @dev True if `who` is the agent's NFT owner or its configured (non-zero) `agentWallet`.
    ///      Same rule as `CommissionEscrow.bind` and `ReviewRegistry._isAgentCaller`; the wallet
    ///      is read only for a non-owner. `ownerOf` reverts (raw ERC-721) for an unminted id.
    function _isAgentController(uint256 agentId, address who) private view returns (bool) {
        if (IERC721(address(_AGENT_REGISTRY)).ownerOf(agentId) == who) return true;
        address wallet = _AGENT_REGISTRY.getAgentWallet(agentId);
        return wallet != address(0) && wallet == who;
    }

    /// @dev Payout address for an identity (reviewer or merchant): the configured `agentWallet`
    ///      if non-zero, else the NFT owner. Same rule as CommissionEscrow._resolveWallet so a
    ///      sale's immediate and deferred legs go to the same party. Reverts (raw ERC-721) for
    ///      an unminted id.
    function _resolveWallet(uint256 agentId) private view returns (address wallet) {
        wallet = _AGENT_REGISTRY.getAgentWallet(agentId);
        if (wallet == address(0)) {
            wallet = IERC721(address(_AGENT_REGISTRY)).ownerOf(agentId);
        }
    }

    /// @dev Single transfer choke point (SafeERC20: reverts on false-returning tokens).
    function _safeTransfer(address to, uint256 amount) private {
        _USDC.safeTransfer(to, amount);
    }
}
