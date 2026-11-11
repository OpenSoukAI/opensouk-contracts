// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ISplitRouter
/// @notice The x402 payTo target. Receives gross USDC on every purchase made through a
///         reviewer's ref link and atomically splits it five ways in a single transaction:
///
///           1. Immediate commission → reviewer's wallet at purchase time
///           2. Held-back commission + cashback → CommissionEscrow.deposit()
///           3. Platform fee → treasury address
///           4. Merchant net → merchant's linked payment wallet
///
///         All transfers occur atomically. If any fails, the entire call reverts
///         and no funds move. This contract is intentionally thin — it carries no escrow
///         state and executes no business logic beyond the split calculation.
///
///         Commission is read LIVE from ProductRegistry at settlement — the merchant's
///         current rate applies. Cashback (a share of commission) and the commission multiplier
///         are committed at review submission and carried in RouteParams.
///
///         The commission multiplier determines the immediate/held-back split:
///           base_commission      = grossAmount × commissionBps / 10_000   (commissionBps read live)
///           immediate_commission = base_commission × commissionMultiplierBps / 10_000
///           held_back            = base_commission − immediate_commission
///         Valid multiplier range: [4000, 10_000] (40%–100% immediate).
///
/// @dev    The x402 facilitator calls route() with the attribution token fields and
///         the buyer's ERC-3009 authorization. Signature verification of the attribution
///         token is performed off-chain by the backend's ref link resolver before the
///         x402 flow proceeds. On-chain, this contract trusts that only valid x402
///         payment flows will reach it (the backend public key is published at
///         /.well-known/pubkey).
///
///         USDC is pulled from the buyer inside route() via ERC-3009
///         receiveWithAuthorization. The buyer signs an off-chain ERC-3009 authorization;
///         the facilitator passes it as erc3009auth. No pre-funding or gas sponsorship
///         for the USDC transfer is required.
///
///         buyerAgentId is supplied by the buyer in x402 payment metadata. route()
///         verifies on-chain that buyer is the agent's NFT owner or its configured
///         agentWallet before proceeding. buyerAgentId is stored in CommissionEscrow for proof-of-purchase
///         verification (used by ReviewRegistry.publishReviewWithEscrowProof).
///
///         reviewerAgentId is derived on-chain from reviewId via ReviewRegistry.getReview().
///         Immediate commission is transferred directly to the reviewer's agent wallet at
///         purchase time; the held-back portion plus cashback go to CommissionEscrow.
///
///         All peer addresses (CommissionEscrow, MerchantRegistry, ReviewRegistry,
///         AgentRegistry) are resolved lazily via ProtocolAddressRegistry at call time —
///         never cached as immutables — so that contract upgrades require only a single
///         PAR address update.
///
///         Access control:
///           DEFAULT_ADMIN_ROLE: setPlatformFeeBps, grantRole/revokeRole
///           FACILITATOR_ROLE: route()
interface ISplitRouter {
    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on every successful purchase split.
    ///         Provides a complete audit trail of the payment breakdown.
    /// @param escrowId              The CommissionEscrow record created for this purchase.
    /// @param buyerAgentId          The buyer agent that made the purchase (SENTINEL_BUYER if agent-less).
    /// @param reviewId              The ReviewRegistry review linked to this purchase.
    /// @param buyerWallet           The paying wallet recorded on the escrow.
    /// @param merchantId            The merchant that received the net payment.
    /// @param grossAmount           The total USDC received from the buyer.
    /// @param immediateCommissionAmt The net portion sent directly to the reviewer's wallet
    ///                              (immediate commission minus reviewer-funded cashback).
    /// @param heldBackAmt           The portion sent to CommissionEscrow for the reviewer.
    /// @param platformFeeAmt        The portion sent to the treasury.
    /// @param cashbackAmt           The portion sent to CommissionEscrow for the buyer.
    /// @param merchantAmt           The net amount sent to the merchant's payment wallet.
    event PaymentRouted(
        uint256 indexed escrowId,
        uint256 indexed buyerAgentId,
        uint256 indexed reviewId,
        address buyerWallet,
        uint256 merchantId,
        bytes32 productId,
        uint256 grossAmount,
        uint256 immediateCommissionAmt,
        uint256 heldBackAmt,
        uint256 platformFeeAmt,
        uint256 cashbackAmt,
        uint256 merchantAmt
    );

    /// @notice Emitted when the platform fee rate is updated by the admin.
    /// @param oldBps The previous fee rate.
    /// @param newBps The new fee rate.
    event PlatformFeeUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the admin cashback cap is updated.
    /// @param oldBps The previous cap.
    /// @param newBps The new cap.
    event MaxCashbackBpsUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the admin recovers USDC held by this contract via recoverUSDC().
    ///         On the MPP charge rail this can include pooled pre-settlement buyer principal
    ///         (funds already transferred in but not yet split) — see audit MPP-02.
    /// @param to     Destination address for the recovered USDC.
    /// @param amount Amount of USDC recovered.
    event USDCRecovered(address indexed to, uint256 amount);

    /// @notice Emitted when recoverUSDC() refunds a parked charge and marks its paymentRef settled,
    ///         so the charge's attestation can no longer be settled.
    /// @param paymentRef The refunded charge's payment reference.
    /// @param to         Refund recipient (the payer).
    /// @param amount     Amount refunded; 0 when the call only invalidates the ref.
    event ChargeRefunded(bytes32 indexed paymentRef, address indexed to, uint256 amount);

    /// @notice Emitted on every successful one-off charge settlement + split.
    /// @dev    reviewId / merchantId / productId are intentionally omitted — they are emitted in
    ///         CommissionEscrow.EscrowDeposited keyed by the same escrowId.
    /// @param paymentRef The charge transaction hash the oracle attested over.
    /// @param immediateCommissionAmt Net portion sent directly to the reviewer's wallet
    ///                               (immediate commission minus reviewer-funded cashback).
    event ChargeSettled(
        bytes32 indexed paymentRef,
        uint256 indexed escrowId,
        uint256 indexed buyerAgentId,
        address payer,
        uint256 amount,
        uint256 immediateCommissionAmt,
        uint256 heldBackAmt,
        uint256 platformFeeAmt,
        uint256 cashbackAmt,
        uint256 merchantAmt
    );

    // =========================================================================
    // x402 facilitator — write
    // =========================================================================

    /// @notice The attribution facts needed to split a payment, independent of how the funds
    ///         arrived. `route()` derives one from `RouteParams`; `splitCharge()` receives one
    ///         directly, bound by the oracle's ChargeAttestation.
    /// @dev    Commission is NOT here — it is read LIVE from ProductRegistry at settle.
    ///         `lockedCashbackBps` is the reviewer's cashback as a share OF COMMISSION, frozen at
    ///         review submission.
    struct Attribution {
        uint256 reviewId;
        uint256 buyerAgentId;
        uint256 merchantId;
        bytes32 productId;
        uint16 commissionMultiplierBps;
        uint16 lockedCashbackBps;
    }

    struct RouteParams {
        uint256 buyerAgentId;
        uint256 reviewId;
        uint256 merchantId;
        bytes32 productId;
        uint256 grossAmount;
        address buyer;
        uint16 commissionMultiplierBps;
        uint16 lockedCashbackBps; // reviewer cashback as a share OF COMMISSION, frozen at review submission
    }

    struct ERC3009Params {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Splits an inbound USDC payment across immediate commission, held-back
    ///         commission + cashback escrow, platform fee, and merchant net. The USDC pull
    ///         from the buyer and all outbound transfers are atomic — all succeed or the
    ///         whole call reverts.
    ///
    ///         Split calculation:
    ///           base_commission      = grossAmount × commissionBps / 10_000   (commissionBps read live from ProductRegistry)
    ///           immediate_commission = base_commission × commissionMultiplierBps / 10_000
    ///           held_back            = base_commission − immediate_commission
    ///           cashback             = base_commission × lockedCashbackBps / 10_000   (share OF COMMISSION)
    ///           platform_fee         = grossAmount × platformFeeBps / 10_000
    ///           merchant_net         = grossAmount − base_commission − platform_fee   (cashback funded from the reviewer's cut)
    ///
    ///         Commission is read live from ProductRegistry at settlement; lockedCashbackBps
    ///         (a share of commission) is committed at review submission and carried in RouteParams.
    ///
    /// @dev    Caller must hold FACILITATOR_ROLE.
    ///
    ///         Validation performed on-chain (before the USDC pull):
    ///           - grossAmount > 0.
    ///           - buyer is not the zero address.
    ///           - buyer is the NFT owner or the configured agentWallet of buyerAgentId, UNLESS
    ///             buyerAgentId == SENTINEL_BUYER (agent-less buyer), in which case only this
    ///             check is skipped.
    ///           - Merchant is active (MerchantRegistry.isActive).
    ///           - commissionBps (live) + platformFeeBps <= 10000.
    ///           - lockedCashbackBps <= maxCashbackBpsOfCommission.
    ///           - commissionMultiplierBps in [4000, 10000].
    ///
    ///         Emits PaymentRouted.
    ///
    /// @param routeParams   Attribution and payment fields committed in the attribution token.
    /// @param erc3009auth   Buyer's ERC-3009 receiveWithAuthorization parameters.
    /// @return escrowId     The CommissionEscrow record ID created for this purchase.
    function route(RouteParams calldata routeParams, ERC3009Params calldata erc3009auth)
        external
        returns (uint256 escrowId);

    /// @notice Splits a one-off MPP charge whose funds were already transferred to this contract.
    /// @dev    Permissionless: authority is the oracle's EIP-712 ChargeAttestation binding
    ///         (paymentRef, amount, payer, attribution), not the caller. Idempotent per paymentRef.
    /// @param paymentRef The charge transaction hash — the attestation's replay key.
    /// @param amount     The attested amount to split, in USDC base units.
    /// @param payer      The buyer wallet that sent the charge transfer.
    /// @param attr       Attribution facts, authenticated by oracleSig.
    /// @param oracleSig  65-byte secp256k1 signature over the ChargeAttestation struct hash.
    /// @return escrowId  The created escrow record id.
    function splitCharge(
        bytes32 paymentRef,
        uint256 amount,
        address payer,
        Attribution calldata attr,
        bytes calldata oracleSig
    ) external returns (uint256 escrowId);

    // =========================================================================
    // Admin — write
    // =========================================================================

    /// @notice Transfers any USDC held by this contract to the specified address.
    ///         Intended for recovering funds sent to this contract by mistake or
    ///         residual dust from rounding.
    ///         On the MPP charge rail this also reaches pooled pre-settlement buyer
    ///         principal — see audit MPP-02.
    ///         To refund a parked charge, pass its paymentRef: the ref is marked settled in the
    ///         same call, so the charge's attestation cannot later settle against other
    ///         buyers' pooled funds. Pass bytes32(0) only for USDC that belongs to no charge.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE.
    ///         Reverts if to is the zero address, or ChargeAlreadySettled if paymentRef is
    ///         non-zero and already settled or refunded.
    ///         Emits USDCRecovered, plus ChargeRefunded when paymentRef is non-zero.
    /// @param to         Destination address for the recovered USDC.
    /// @param amount     Amount of USDC to transfer; 0 with a paymentRef only invalidates the ref.
    /// @param paymentRef The refunded charge's payment reference, or bytes32(0) for none.
    function recoverUSDC(address to, uint256 amount, bytes32 paymentRef) external;

    /// @notice Updates the platform fee rate applied to every purchase.
    ///         Takes effect immediately for all subsequent calls to route().
    ///         The platform fee is not locked at ref-link generation time.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE.
    ///         Reverts FeeTooHigh if newBps > MAX_PLATFORM_FEE_BPS (2000 = 20%).
    ///         Emits PlatformFeeUpdated.
    /// @param newBps The new platform fee in basis points (e.g. 200 = 2%).
    function setPlatformFeeBps(uint16 newBps) external;

    /// @notice Updates the maximum cashback the reviewer may fund, as a share of commission.
    ///         Must be ≤ SplitMath.MULTIPLIER_MIN (4000 bps = 40%).
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE.
    ///         Reverts SplitMath.CapAboveCeiling if newBps > SplitMath.MULTIPLIER_MIN.
    ///         Emits MaxCashbackBpsUpdated.
    /// @param newBps New cap in bps (e.g. 4000 = 40% of commission).
    function setMaxCashbackBps(uint16 newBps) external;

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @notice Returns the current platform fee rate in basis points.
    function platformFeeBps() external view returns (uint16);

    /// @notice Returns the maximum platform fee in basis points (2000 = 20%).
    function MAX_PLATFORM_FEE_BPS() external view returns (uint16);

    /// @notice Returns the address of the USDC token contract used for all transfers.
    function usdc() external view returns (address);

    /// @notice Returns the current admin cashback cap (bps of commission).
    function maxCashbackBpsOfCommission() external view returns (uint16);

    /// @notice Sentinel buyerAgentId marking an agent-less purchase. When
    ///         routeParams.buyerAgentId equals this value, route() skips ONLY the buyer-ownership
    ///         check; the paying wallet is still recorded on the escrow record.
    function SENTINEL_BUYER() external view returns (uint256);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when route() is called with a grossAmount of zero.
    error ZeroAmount();

    /// @notice Thrown when buyer is neither the NFT owner nor the configured agentWallet of buyerAgentId.
    error InvalidBuyerAgent(uint256 buyerAgentId, address buyer);

    /// @notice Thrown when commission + platform fee exceeds 100% (negative merchant net).
    error RatesExceedTotal(uint16 commissionBps, uint16 platformFeeBps);

    /// @notice Thrown when commissionMultiplierBps is outside [4000, 10000].
    error MultiplierOutOfRange(uint16 multiplierBps);

    /// @notice Thrown when commission > 0 but reviewId resolved to no reviewer. Unreachable:
    ///         a reviewId == 0 purchase settles with zero commission; kept as a backstop.
    error MissingReviewerForCommission();

    /// @notice Thrown when the referenced review belongs to a different merchant than the purchase.
    ///         The review's product may differ (attribution is merchant-scoped).
    error ReviewMerchantMismatch(uint256 reviewId, uint256 reviewMerchantId, uint256 merchantId);

    /// @notice Thrown when route() is called and the merchant is not active.
    error MerchantNotActive(uint256 merchantId);

    /// @notice Thrown when the product is inactive (or does not exist) at settlement.
    error ProductNotActive(uint256 merchantId, bytes32 productId);

    /// @notice Thrown when route() is called with a zero-address buyer.
    error ZeroBuyerAddress();

    /// @notice Thrown when the constructor or setPlatformFeeBps gets a fee above MAX_PLATFORM_FEE_BPS.
    error FeeTooHigh(uint16 bps);

    /// @notice Thrown when recoverUSDC is called with the zero address.
    error ZeroRecipientAddress();

    /// @notice This paymentRef was already settled. Single-use guard.
    error ChargeAlreadySettled(bytes32 paymentRef);
    /// @notice The router does not hold enough USDC to cover the attested amount.
    error InsufficientChargeBalance();
    /// @notice The oracle attestation did not recover to PAR's ORACLE address.
    error OracleAttestationInvalid();
}
