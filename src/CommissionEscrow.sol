// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICommissionEscrow} from "./interfaces/ICommissionEscrow.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IProtocolAddressRegistry} from "./interfaces/IProtocolAddressRegistry.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProtocolConstants} from "./libraries/ProtocolConstants.sol";

/// @title CommissionEscrow
/// @notice Holds the deferred part of every purchase — the reviewer's held-back commission and
///         the buyer's cashback — and settles both after the settlement window.
/// @dev One `EscrowRecord` per purchase, created by `SplitRouter` via `deposit()`. Two amounts
///      are held per record and are discharged INDEPENDENTLY:
///
///        heldBackAmt  — reviewer commission withheld until the oracle scores the review.
///                       Discharged once, by `settleHeldBack` (oracle, day ≥ 0) or
///                       `triggerSettleFallback` (anyone, day ≥ windowEnd +
///                       `FALLBACK_GRACE_PERIOD`). Tracked by `state` (Holding → Settled,
///                       terminal).
///        cashbackAmt  — buyer rebate, funded out of the reviewer's immediate commission.
///                       Discharged once, by `releaseCashback` (oracle → buyer),
///                       `cashbackToReviewer` (oracle → reviewer, day ≥ windowEnd) or
///                       `triggerSettleFallback` (→ reviewer). Tracked by `cashbackReleased`.
///
///      Because the two flags are independent, `settleHeldBack` does not block a later cashback
///      release and vice versa; `triggerSettleFallback` refuses only when BOTH are discharged.
///      Amounts are never zeroed on settle — the flags are the sole double-pay guard, and every
///      settlement function sets its flag BEFORE transferring (checks-effects-interactions).
///
///      Funding model: the router transfers `heldBackAmt + cashbackAmt` USDC to this contract
///      immediately before calling `deposit()`. `deposit()` does not verify the transfer; the
///      contract's balance is commingled across all escrows, and solvency is a cross-contract
///      invariant maintained by `SplitRouter` (tested by the invariant suite). Any stray USDC
///      sent here has no sweep path.
///
///      Agent-less buyers: a purchase without an ERC-8004 identity is deposited with
///      `buyerAgentId == SENTINEL_BUYER` and the paying wallet in `buyerWallet`. `bind()` lets
///      that wallet attach an identity later. Until bound, `releaseCashback` reverts
///      `BuyerNotBound`, and the cashback eventually returns to the reviewer.
///
///      Roles: `ORACLE_ROLE` decides settlement outcomes (bounded to the escrowed amounts);
///      `PAUSER_ROLE` can pause (halting `deposit()` and therefore BOTH payment rails);
///      `DEFAULT_ADMIN_ROLE` unpauses, sets the window for future deposits and rotates roles.
///      Treasury and SplitRouter addresses are resolved live from PAR; the identity registry is
///      cached as an immutable (README §4). Payouts go to an agent's `agentWallet` if set, else
///      to the NFT owner, resolved at payout time.
contract CommissionEscrow is ICommissionEscrow, AccessControl, ReentrancyGuardTransient, Pausable {
    using SafeERC20 for IERC20;
    /// @notice Role that settles held-back and releases/returns cashback (the backend hot wallet).
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    /// @dev Separate role, this emergency lever must stay reachable quickly. Admin will be multisig.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev `unlockPct` is a whole percentage in [0, 100]; the remainder of held-back goes to treasury.
    uint8 private constant MAX_UNLOCK_PCT = 100;

    /// @dev Default settlement window and admin-settable bounds.
    uint40 private constant DEFAULT_SETTLEMENT_WINDOW = uint40(60 days);
    uint40 private constant MIN_SETTLEMENT_WINDOW = uint40(1 days);
    uint40 private constant MAX_SETTLEMENT_WINDOW = uint40(180 days);

    /// @notice Delay after `windowEnd` before `triggerSettleFallback` opens.
    uint256 public constant FALLBACK_GRACE_PERIOD = 10 days;

    /// @dev Protocol address registry; `SPLIT_ROUTER` and `TREASURY` are read from it live.
    IProtocolAddressRegistry private immutable _PROTOCOL;
    /// @dev Settlement token. All amounts in this contract are in its base units (USDC: 6 dp).
    IERC20 private immutable _USDC;
    // ERC-8004 address cached as immutable per design requirement.
    address private immutable _AGENT_REGISTRY;

    /// @dev Next id to assign. Starts at 1 so `escrowId == 0` is never a valid record.
    uint256 private _nextEscrowId = 1;
    /// @dev Settlement window (seconds) stamped onto new deposits; existing escrows keep their stamp.
    uint40 private _settlementWindow = DEFAULT_SETTLEMENT_WINDOW;
    /// @dev Seconds this contract has spent paused, summed over every completed pause. Escrows
    ///      snapshot it at deposit; the difference is what a deadline owes them.
    uint40 private _pausedTotal;
    /// @dev Start of the pause in progress; 0 when not paused.
    uint40 private _pauseStartedAt;
    /// @dev Escrow storage. Existence is `depositTimestamp != 0`.
    mapping(uint256 => EscrowRecord) private _escrows;

    /// @param protocolAddressRegistry ProtocolAddressRegistry. `AGENT_REGISTRY` must already be set.
    /// @param admin                   Receives `DEFAULT_ADMIN_ROLE`. Must separately grant
    ///                                `ORACLE_ROLE` and `PAUSER_ROLE` (see `Deploy.s.sol`).
    /// @param usdcAddress             ERC-20 used for every transfer. Not validated.
    /// @dev Emits `SettlementWindowUpdated(0, DEFAULT_SETTLEMENT_WINDOW)` so indexers see the
    ///      initial window in the same shape as a later `setSettlementWindow`.
    constructor(address protocolAddressRegistry, address admin, address usdcAddress) {
        _PROTOCOL = IProtocolAddressRegistry(protocolAddressRegistry);
        _USDC = IERC20(usdcAddress);
        _AGENT_REGISTRY = _PROTOCOL.getAddress(_PROTOCOL.AGENT_REGISTRY());
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        emit SettlementWindowUpdated(0, DEFAULT_SETTLEMENT_WINDOW);
    }

    // =========================================================================
    // SplitRouter-only — write
    // =========================================================================

    /// @inheritdoc ICommissionEscrow
    /// @dev Caller is address-matched against the CURRENT PAR `SPLIT_ROUTER` (resolved live), so
    ///      re-pointing the router key through the PAR time-lock is enough to swap routers; no
    ///      role grant is needed. The escrow trusts that the router has already transferred
    ///      `heldBackAmt + cashbackAmt` — nothing is pulled and no balance is checked here.
    ///      `whenNotPaused` on this function is what makes pausing the escrow halt both rails.
    ///      `windowEnd` is fixed at deposit from the window in force at that moment.
    ///      `reviewId` is event-only (indexer linkage); it is not stored on the record.
    ///      `buyerAgentId` is stored verbatim — `SENTINEL_BUYER` for agent-less purchases; no
    ///      ownership check is made here (the router did it, or deliberately skipped it).
    function deposit(
        uint256 reviewerAgentId,
        uint256 buyerAgentId,
        address buyerWallet,
        uint256 merchantId,
        bytes32 productId,
        uint8 productType,
        uint128 heldBackAmt,
        uint128 cashbackAmt,
        uint128 originalPurchaseAmt,
        uint256 reviewId
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        if (msg.sender != _PROTOCOL.getAddress(_PROTOCOL.SPLIT_ROUTER())) {
            revert CallerNotSplitRouter(msg.sender);
        }
        // Every escrow must record a real paying wallet.
        // Agentless purchases use ProtocolConstants.SENTINEL_BUYER.
        if (buyerWallet == address(0)) revert ZeroBuyerWallet();

        escrowId = _nextEscrowId;
        _nextEscrowId = escrowId + 1;

        uint40 ts = uint40(block.timestamp);
        _escrows[escrowId] = EscrowRecord({
            reviewerAgentId: reviewerAgentId,
            buyerAgentId: buyerAgentId,
            buyerWallet: buyerWallet,
            pausedTotalAtDeposit: _pausedTotal, // deposit is whenNotPaused, so no pause is in progress
            merchantId: merchantId,
            productId: productId,
            heldBackAmt: heldBackAmt,
            cashbackAmt: cashbackAmt,
            originalPurchaseAmt: originalPurchaseAmt,
            depositTimestamp: ts,
            windowEnd: ts + _settlementWindow, // uint40 + uint40; cannot overflow for realistic timestamps
            productType: productType,
            state: EscrowState.Holding,
            cashbackReleased: false
        });

        emit EscrowDeposited(
            escrowId,
            reviewerAgentId,
            buyerAgentId,
            buyerWallet,
            reviewId,
            merchantId,
            productId,
            heldBackAmt,
            cashbackAmt
        );
    }

    /// @inheritdoc ICommissionEscrow
    /// @dev No time gate: binding is allowed at any point, even after the held-back is settled
    ///      (it only affects where cashback can go). No funds move. Reverts with the raw ERC-721
    ///      error if `agentId` is unminted (`ownerOf` is not wrapped here, unlike ReviewRegistry).
    function bind(uint256 escrowId, uint256 agentId) external nonReentrant whenNotPaused {
        EscrowRecord storage rec = _escrows[escrowId];
        _requireExists(escrowId, rec);
        // One-shot, agent-less only: only a sentinel escrow can be bound. Once bound, buyerAgentId
        // is a real id, so a second bind (or any non-sentinel escrow) reverts.
        if (rec.buyerAgentId != ProtocolConstants.SENTINEL_BUYER) revert AlreadyBound(escrowId);
        // Caller must be the wallet that paid the (agent-less) purchase...
        if (msg.sender != rec.buyerWallet) revert NotBuyerWallet(escrowId, msg.sender);
        // ...and must control the identity being bound — its NFT owner OR the configured
        // agentWallet, matching ReviewRegistry._isAgentCaller / _resolveWallet. The wallet is
        // read only when the caller is not the owner.
        if (msg.sender != IERC721(_AGENT_REGISTRY).ownerOf(agentId)) {
            address agentWallet = IIdentityRegistry(_AGENT_REGISTRY).getAgentWallet(agentId);
            if (agentWallet == address(0) || msg.sender != agentWallet) {
                revert NotAgentController(agentId, msg.sender);
            }
        }

        rec.buyerAgentId = agentId;
        emit EscrowBound(escrowId, agentId, msg.sender);
    }

    // =========================================================================
    // Oracle — write
    // =========================================================================

    /// @inheritdoc ICommissionEscrow
    /// @dev Oracle only. No time gate — the oracle may settle early (e.g. after the review is
    ///      scored). Splits `heldBackAmt` as `unlockPct%` to the reviewer and the remainder to
    ///      the PAR `TREASURY`; `unlockPct` is the oracle's only degree of freedom and is bounded
    ///      to [0, 100]. `state` flips to `Settled` BEFORE any transfer (CEI) and is terminal.
    ///      Cashback is untouched here: it has its own flag and its own functions.
    ///      `heldBackAmt * unlockPct` is computed in uint128 — it reverts (checked arithmetic)
    ///      rather than corrupts, and only for held-back > ~3.4e30 base units.
    ///      Emits even when both legs are zero so indexers see every settlement.
    function settleHeldBack(uint256 escrowId, uint8 unlockPct)
        external
        onlyRole(ORACLE_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (unlockPct > MAX_UNLOCK_PCT) revert UnlockPctOutOfRange(unlockPct);

        EscrowRecord storage rec = _escrows[escrowId];
        _requireExists(escrowId, rec);
        if (rec.state == EscrowState.Settled) revert AlreadySettled(escrowId);

        rec.state = EscrowState.Settled; // effect before interactions; terminal

        uint128 reviewerAmt = rec.heldBackAmt * unlockPct / MAX_UNLOCK_PCT;
        uint128 treasuryAmt = rec.heldBackAmt - reviewerAmt; // rounding dust goes to treasury

        address treasury = _PROTOCOL.getAddress(_PROTOCOL.TREASURY());

        // Resolved only when paid: a no-referral escrow holds SENTINEL_REVIEWER, whose ownerOf
        // reverts. The event reports address(0) when nothing goes to the reviewer.
        // A blocked reviewer wallet reverts this call, by design: it is oracle-only, so the revert
        // reaches an operator who can settle with unlockPct = 0 and send the lot to the treasury.
        address reviewer;
        if (reviewerAmt > 0) {
            reviewer = _resolveWallet(rec.reviewerAgentId);
            _safeTransfer(reviewer, reviewerAmt);
        }
        if (treasuryAmt > 0) _safeTransfer(treasury, treasuryAmt);

        emit HeldBackSettled(escrowId, reviewer, treasury, reviewerAmt, treasuryAmt);
    }

    /// @inheritdoc ICommissionEscrow
    /// @dev Oracle only; the backend calls this after the buyer's own review has passed its
    ///      vote gate. Pays `cashbackAmt` to the buyer identity's payout wallet, resolved NOW
    ///      (agentWallet, else NFT owner). Idempotent: a repeat call returns silently WITHOUT
    ///      emitting, so a duplicate backend job is harmless. Independent of `state` — works
    ///      before or after `settleHeldBack`. Emits `CashbackReleased(id, 0, 0)` when the
    ///      escrowed cashback is zero, so the flag flip is still observable. A blocked buyer
    ///      wallet reverts this call: oracle-only, and the cashback still reaches the reviewer
    ///      through the day-70 fallback.
    function releaseCashback(uint256 escrowId) external onlyRole(ORACLE_ROLE) nonReentrant whenNotPaused {
        EscrowRecord storage rec = _escrows[escrowId];
        _requireExists(escrowId, rec);
        // Un-bound agent-less escrow: the buyer can't be resolved until bind sets a real agent
        // id. Revert with a clear reason rather than a raw ERC-721 panic (funds still return to the
        // reviewer at day-60/70 if never bound). Once bound, buyerAgentId != SENTINEL_BUYER.
        if (rec.buyerAgentId == ProtocolConstants.SENTINEL_BUYER) revert BuyerNotBound(escrowId);
        if (rec.cashbackReleased) return; // idempotent no-op

        rec.cashbackReleased = true; // effect before interaction
        uint128 amt = rec.cashbackAmt;
        if (amt > 0) {
            address buyer = _resolveWallet(rec.buyerAgentId);
            _safeTransfer(buyer, amt);
            emit CashbackReleased(escrowId, buyer, amt);
        } else {
            emit CashbackReleased(escrowId, address(0), 0);
        }
    }

    /// @inheritdoc ICommissionEscrow
    /// @dev Oracle only; the "buyer never reviewed" outcome. Returns `cashbackAmt` to the
    ///      REVIEWER (it was carved out of the reviewer's immediate commission at purchase).
    ///      Time-gated to `windowEnd` so the oracle cannot pre-empt a buyer still inside the
    ///      window. Unlike `releaseCashback`, a repeat call REVERTS (`CashbackAlreadyReleased`)
    ///      — the asymmetry is deliberate: releasing twice is a benign duplicate job, returning
    ///      after a release would be a wrong outcome and should surface. No event on the
    ///      zero-amount path (known indexer blind spot, CE-04). A blocked reviewer wallet reverts
    ///      this call: oracle-only, so the revert reaches an operator rather than stranding a
    ///      permissionless caller.
    function cashbackToReviewer(uint256 escrowId) external onlyRole(ORACLE_ROLE) nonReentrant whenNotPaused {
        EscrowRecord storage rec = _escrows[escrowId];
        _requireExists(escrowId, rec);
        if (rec.cashbackReleased) revert CashbackAlreadyReleased(escrowId);
        uint256 eligibleAt = uint256(rec.windowEnd) + _pauseShift(rec);
        if (block.timestamp < eligibleAt) revert TooEarly(escrowId, eligibleAt, block.timestamp);

        rec.cashbackReleased = true; // effect before interaction
        uint128 amt = rec.cashbackAmt;
        if (amt > 0) {
            address reviewer = _resolveWallet(rec.reviewerAgentId);
            _safeTransfer(reviewer, amt);
            emit CashbackReturnedToReviewer(escrowId, reviewer, amt);
        }
    }

    // =========================================================================
    // Public — write (oracle failure fallback)
    // =========================================================================

    /// @inheritdoc ICommissionEscrow
    /// @dev Permissionless safety net for an oracle that has gone dark. Eligible
    ///      `FALLBACK_GRACE_PERIOD` after `windowEnd`, giving the oracle a grace period after the
    ///      window. Outcome is the most conservative one: held-back → treasury (as if
    ///      `unlockPct == 0`), unreleased cashback → reviewer (as if the buyer never reviewed). Each leg runs only if its own flag is
    ///      still open, so it composes with a partial oracle settlement (e.g. held-back settled
    ///      but cashback pending). Reverts `AlreadySettled` only when both legs are already done.
    ///      A cashback leg that cannot be paid (reviewer wallet blacklisted by USDC, or the
    ///      reviewer identity unresolvable) does not block the treasury leg: it stays open and a
    ///      later call retries it.
    ///      Still `whenNotPaused`: a paused-and-abandoned contract outlasts this fallback
    ///      (accepted, CE-01) — admin can always grant `ORACLE_ROLE` to a fresh key instead.
    function triggerSettleFallback(uint256 escrowId) external nonReentrant whenNotPaused {
        EscrowRecord storage rec = _escrows[escrowId];
        _requireExists(escrowId, rec);

        if (rec.state == EscrowState.Settled && rec.cashbackReleased) revert AlreadySettled(escrowId);

        uint256 eligibleAt = uint256(rec.windowEnd) + FALLBACK_GRACE_PERIOD + _pauseShift(rec);
        if (block.timestamp < eligibleAt) revert TooEarly(escrowId, eligibleAt, block.timestamp);

        address treasury = _PROTOCOL.getAddress(_PROTOCOL.TREASURY());

        // heldBackAmt is never zeroed on settle, so the treasury leg is gated on state.
        // This leg is allowed to revert: TREASURY is admin-set through PAR, so a payee that
        // blocks the transfer is a misconfiguration to fix, not a state to settle around.
        uint128 heldAmt = 0;
        if (rec.state != EscrowState.Settled) {
            rec.state = EscrowState.Settled; // effect before interaction
            heldAmt = rec.heldBackAmt;
            if (heldAmt > 0) _safeTransfer(treasury, heldAmt);
        }

        // Cashback leg: the flag is set only after the transfer succeeds, so a failed transfer
        // leaves the leg open for a retry (nonReentrant covers the ordering). Non-reverting
        // unlike the oracle paths, because this is the only permissionless exit and the reviewer
        // chooses its own payout address: letting it revert would hand the reviewer a veto over
        // the treasury leg.
        uint128 cashbackSent = 0;
        if (!rec.cashbackReleased) {
            uint128 amt = rec.cashbackAmt;
            if (amt == 0) {
                rec.cashbackReleased = true;
            } else {
                (bool resolved, address reviewer) = _tryResolveWallet(rec.reviewerAgentId);
                if (resolved && _USDC.trySafeTransfer(reviewer, amt)) {
                    rec.cashbackReleased = true;
                    cashbackSent = amt;
                } else {
                    emit FallbackCashbackFailed(escrowId, reviewer, amt);
                }
            }
        }

        // Amounts in the event are what THIS call moved (zero for a leg that was already done).
        emit FallbackSettled(escrowId, treasury, heldAmt, cashbackSent);
    }

    // =========================================================================
    // Admin — write
    // =========================================================================

    /// @inheritdoc ICommissionEscrow
    /// @dev Admin only. Bounded to [1 day, 180 days]. Applies only to escrows deposited AFTER
    ///      this call; every existing record keeps the `windowEnd` it was stamped with.
    function setSettlementWindow(uint40 newWindow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newWindow < MIN_SETTLEMENT_WINDOW || newWindow > MAX_SETTLEMENT_WINDOW) {
            revert SettlementWindowOutOfBounds(newWindow);
        }
        uint40 old = _settlementWindow;
        _settlementWindow = newWindow;
        emit SettlementWindowUpdated(old, newWindow);
    }

    /// @inheritdoc ICommissionEscrow
    /// @dev `PAUSER_ROLE`, not admin, so the circuit breaker can be pulled without the (slower)
    ///      admin key. Pausing blocks deposit (both rails), bind, and every settlement function
    ///      including the permissionless fallback. Views keep working.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pauseStartedAt = uint40(block.timestamp);
        _pause();
    }

    /// @inheritdoc ICommissionEscrow
    /// @dev Admin only — unpausing is the considered action, pausing is the reflex.
    ///      Banks the length of the pause into `_pausedTotal`, which moves the deadline of every
    ///      escrow that was already open when the pause began, and of no other.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pausedTotal += uint40(block.timestamp - _pauseStartedAt);
        _pauseStartedAt = 0;
        _unpause();
    }

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @inheritdoc ICommissionEscrow
    /// @dev Reverts `EscrowNotFound` for an unknown id. `ReviewRegistry.publishReviewWithEscrowProof`
    ///      relies on this revert.
    function getEscrow(uint256 escrowId) external view returns (EscrowRecord memory) {
        EscrowRecord storage rec = _escrows[escrowId];
        _requireExists(escrowId, rec);
        return rec;
    }

    /// @inheritdoc ICommissionEscrow
    /// @dev Equals the highest assigned id (ids are dense from 1).
    function totalEscrows() external view returns (uint256) {
        return _nextEscrowId - 1;
    }

    /// @inheritdoc ICommissionEscrow
    function usdc() external view returns (address) {
        return address(_USDC);
    }

    /// @inheritdoc ICommissionEscrow
    function totalPausedSeconds() external view returns (uint40) {
        return _pausedTotal;
    }

    /// @inheritdoc ICommissionEscrow
    /// @dev The window that NEW deposits will be stamped with.
    function settlementWindow() external view returns (uint40) {
        return _settlementWindow;
    }

    /// @inheritdoc ICommissionEscrow
    /// @dev Explicit override only because both `Pausable` and the interface declare `paused()`.
    function paused() public view override(Pausable, ICommissionEscrow) returns (bool) {
        return super.paused();
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Seconds this escrow spent paused: everything banked since its own deposit. The
    ///      pause in progress is deliberately excluded — both callers are `whenNotPaused`, so
    ///      `_pausedTotal` is always settled by the time they read it.
    function _pauseShift(EscrowRecord storage rec) private view returns (uint256) {
        return _pausedTotal - rec.pausedTotalAtDeposit;
    }

    /// @dev Existence check via `depositTimestamp != 0`. Takes the storage pointer so callers
    ///      that already loaded the record do not pay a second SLOAD.
    function _requireExists(uint256 escrowId, EscrowRecord storage rec) private view {
        if (rec.depositTimestamp == 0) revert EscrowNotFound(escrowId);
    }

    /// @dev Payout address for an identity: the configured `agentWallet` if non-zero, else the
    ///      NFT owner. Resolved at payout time, so a transferred identity (or a rotated wallet)
    ///      redirects funds not yet paid. Reverts with the raw ERC-721 error if the id is not
    ///      minted — settlement of an escrow whose reviewer identity no longer exists would fail.
    function _resolveWallet(uint256 agentId) private view returns (address wallet) {
        wallet = IIdentityRegistry(_AGENT_REGISTRY).getAgentWallet(agentId);
        if (wallet == address(0)) {
            wallet = IERC721(_AGENT_REGISTRY).ownerOf(agentId);
        }
    }

    /// @dev `_resolveWallet` that returns `ok = false` instead of reverting, for the fallback's
    ///      cashback leg.
    function _tryResolveWallet(uint256 agentId) private view returns (bool ok, address wallet) {
        try IIdentityRegistry(_AGENT_REGISTRY).getAgentWallet(agentId) returns (address w) {
            if (w != address(0)) return (true, w);
        } catch {
            return (false, address(0));
        }
        try IERC721(_AGENT_REGISTRY).ownerOf(agentId) returns (address owner) {
            return (true, owner);
        } catch {
            return (false, address(0));
        }
    }

    /// @dev Single transfer choke point (SafeERC20: reverts on false-returning tokens).
    function _safeTransfer(address to, uint256 amount) private {
        _USDC.safeTransfer(to, amount);
    }
}
