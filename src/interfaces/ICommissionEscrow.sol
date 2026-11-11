// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ICommissionEscrow
/// @notice Holds the held-back commission portion and cashback for each ref-link purchase.
///         Each purchase creates one independent escrow record. Settlement is time-based
///         (60-day window) and spend-based; the immediate commission portion is paid
///         directly by SplitRouter at purchase time and never enters escrow.
///
///         What sits in escrow:
///           - Held-back commission: (1 − commission_multiplier) × base_commission
///           - Cashback: reviewer-funded reserve; released to buyer on review, or back to reviewer at expiry
///
///         Settlement:
///           1. Oracle (ORACLE_ROLE): settleHeldBack() at day 60 with computed unlockPct.
///           2. Oracle (ORACLE_ROLE): releaseCashback() when buyer posts a review.
///           3. Oracle (ORACLE_ROLE): cashbackToReviewer() if no buyer review by day 60.
///           4. Public fallback: triggerSettleFallback() callable by anyone after day 70.
///              Sends all held-back to treasury; unreleased cashback to reviewer.
///
///         States: Holding → Settled (terminal). Dispute path is post-MVP; uint8 state
///         is forward-compatible with a future Disputed state.
///
///         Security:
///           - ReentrancyGuardTransient + CEI on all state-mutating functions.
///           - USDC address immutable at construction.
///           - Pausable circuit breaker (DEFAULT_ADMIN_ROLE).
///           - deposit() restricted to SplitRouter via address check against PAR.
///           - ORACLE_ROLE separately rotatable.
///           - PAUSER_ROLE may pause but not unpause; DEFAULT_ADMIN_ROLE unpauses.
interface ICommissionEscrow {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Lifecycle state of a single escrow record.
    ///         uint8 storage is forward-compatible with a future Disputed state.
    enum EscrowState {
        Holding, // 0 — 60-day window running, accumulating unlock signals.
        Settled // 1 — Day-60 batch fired. Terminal.
    }

    /// @notice Full on-chain record for a single escrow deposit.
    struct EscrowRecord {
        uint256 reviewerAgentId; // AgentRegistry token ID of the reviewer.
        uint256 buyerAgentId; // AgentRegistry token ID of the buyer (SENTINEL_BUYER if agent-less).
        address buyerWallet; // Paying wallet recorded at purchase (used by agent-less bind/claim).
        uint40 pausedTotalAtDeposit; // totalPausedSeconds() when this escrow was created.
        uint256 merchantId; // MerchantRegistry token ID.
        bytes32 productId; // ProductRegistry product identifier.
        uint128 heldBackAmt; // USDC held in escrow for the reviewer.
        uint128 cashbackAmt; // reviewer-funded buyer cashback reserve.
        uint128 originalPurchaseAmt; // Gross purchase amount. Used by oracle for tier math.
        uint40 depositTimestamp; // Block timestamp at deposit.
        uint40 windowEnd; // depositTimestamp + 60 days.
        uint8 productType; // 0 = Repeat, 1 = OneOff.
        EscrowState state;
        bool cashbackReleased;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new escrow record is created on purchase.
    event EscrowDeposited(
        uint256 indexed escrowId,
        uint256 indexed reviewerAgentId,
        uint256 indexed buyerAgentId,
        address buyerWallet,
        uint256 reviewId,
        uint256 merchantId,
        bytes32 productId,
        uint128 heldBackAmt,
        uint128 cashbackAmt
    );

    /// @notice Emitted when an agent-less (sentinel) escrow is bound to a registered identity.
    event EscrowBound(uint256 indexed escrowId, uint256 indexed agentId, address indexed boundBy);

    /// @notice Emitted when the held-back portion is settled between reviewer and treasury.
    ///         `reviewer` is address(0) when the reviewer's share is zero (it is not resolved).
    event HeldBackSettled(
        uint256 indexed escrowId,
        address indexed reviewer,
        address indexed treasury,
        uint128 reviewerAmt,
        uint128 treasuryAmt
    );

    /// @notice Emitted when cashback is released to the buyer.
    event CashbackReleased(uint256 indexed escrowId, address indexed buyer, uint128 amount);

    /// @notice Emitted when cashback is returned to the reviewer (no buyer review by day 60).
    event CashbackReturnedToReviewer(uint256 indexed escrowId, address indexed reviewer, uint128 amount);

    /// @notice Emitted when the public fallback settles an escrow after day 70.
    ///         cashbackAmt is 0 if cashback had already been released, or if its transfer failed
    ///         this call (then getEscrow shows cashbackReleased == false).
    event FallbackSettled(uint256 indexed escrowId, address indexed treasury, uint128 heldBackAmt, uint128 cashbackAmt);

    /// @notice Emitted when the fallback could not pay the cashback leg (reviewer wallet
    ///         blacklisted, or identity unresolvable). The leg stays open for a later call.
    /// @param reviewer The resolved reviewer wallet, or address(0) if it could not be resolved.
    event FallbackCashbackFailed(uint256 indexed escrowId, address indexed reviewer, uint128 amount);

    /// @notice Emitted when the settlement window applied to new deposits is updated by admin.
    /// @param oldWindow The previous settlement window in seconds.
    /// @param newWindow The new settlement window in seconds.
    event SettlementWindowUpdated(uint40 oldWindow, uint40 newWindow);

    // =========================================================================
    // SplitRouter-only — write
    // =========================================================================

    /// @notice Creates a new escrow record for a purchase, with or without a ref link.
    ///         Called atomically by SplitRouter.route(). USDC is transferred to this
    ///         contract by SplitRouter before this call; deposit() creates the record only.
    /// @dev    Restricted to the SplitRouter address from ProtocolAddressRegistry.
    ///         Uses nonReentrant and whenNotPaused.
    /// @param reviewerAgentId    AgentRegistry token ID of the reviewer (SENTINEL_REVIEWER if no referral).
    /// @param buyerAgentId       AgentRegistry token ID of the buyer (SENTINEL_BUYER if agent-less).
    /// @param buyerWallet        Paying wallet recorded on the escrow (agent-less bind/claim).
    /// @param merchantId         MerchantRegistry token ID.
    /// @param productId          ProductRegistry product identifier.
    /// @param productType        0 = Repeat, 1 = OneOff.
    /// @param heldBackAmt        USDC held back for the reviewer.
    /// @param cashbackAmt        USDC held for buyer (or reviewer on expiry).
    /// @param originalPurchaseAmt Gross purchase amount for oracle tier calculations.
    /// @param reviewId            ReviewRegistry review ID linked to this purchase (0 = no attribution).
    /// @return escrowId          Auto-incremented ID of the newly created record.
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
    ) external returns (uint256 escrowId);

    /// @notice Bind an agent-less (sentinel) escrow to a now-registered identity.
    /// @dev    Caller must be the recorded buyerWallet AND control `agentId` (its NFT owner or the
    ///         configured agentWallet). One-shot: reverts AlreadyBound if not a sentinel. Unlocks
    ///         releaseCashback + the buyer review path for the deferred purchase.
    /// @param  escrowId  The escrow to bind.
    /// @param  agentId   The buyer's newly-registered ERC-8004 agent id.
    function bind(uint256 escrowId, uint256 agentId) external;

    // =========================================================================
    // Oracle — write
    // =========================================================================

    /// @notice Settles the held-back portion. Sends `unlockPct`% to reviewer and
    ///         the remainder to treasury. Sets state to Settled.
    /// @dev    Caller must hold ORACLE_ROLE. Reverts if already Settled.
    ///         unlockPct = 0 → 100% to treasury. unlockPct = 100 → 100% to reviewer.
    /// @param escrowId  The escrow record to settle.
    /// @param unlockPct Percentage of heldBackAmt to release to reviewer (0–100).
    function settleHeldBack(uint256 escrowId, uint8 unlockPct) external;

    /// @notice Releases cashback to the buyer's agent wallet. Idempotent — no-op if
    ///         cashback has already been released.
    /// @dev    Caller must hold ORACLE_ROLE. Release is oracle-only so it can be gated on
    ///         votes off-chain.
    function releaseCashback(uint256 escrowId) external;

    /// @notice Returns cashback to the reviewer if no buyer review was posted by windowEnd.
    /// @dev    Caller must hold ORACLE_ROLE.
    ///         Reverts if cashbackReleased == true.
    ///         Reverts if block.timestamp < windowEnd plus the time this contract spent paused
    ///         since the escrow was created.
    function cashbackToReviewer(uint256 escrowId) external;

    // =========================================================================
    // Public — write (oracle failure fallback)
    // =========================================================================

    /// @notice Public fallback callable by anyone after windowEnd + FALLBACK_GRACE_PERIOD (day 70).
    ///         Sends heldBackAmt to treasury and, if cashback not yet released,
    ///         sends cashbackAmt to reviewer. Sets state to Settled.
    ///         Purpose: prevent USDC sitting indefinitely if oracle fails.
    ///         If the cashback transfer fails, the treasury leg still settles and the cashback
    ///         stays unreleased for a later call.
    /// @dev    Reverts if already Settled. Reverts before day 70 plus the time this contract
    ///         spent paused since the escrow was created.
    function triggerSettleFallback(uint256 escrowId) external;

    // =========================================================================
    // Admin — write
    // =========================================================================

    /// @notice Updates the settlement window (in seconds) stamped onto NEW deposits.
    ///         Existing escrows keep the windowEnd stamped at their deposit time.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE.
    ///         Reverts SettlementWindowOutOfBounds if newWindow < 1 days or > 180 days.
    ///         Emits SettlementWindowUpdated.
    /// @param newWindow The new settlement window in seconds.
    function setSettlementWindow(uint40 newWindow) external;

    /// @notice Pauses the contract. All state-mutating functions revert while paused.
    /// @dev Caller must hold PAUSER_ROLE, which is deliberately not DEFAULT_ADMIN_ROLE: pausing
    ///      halts both payment rails and must stay fast once admin is a multisig.
    function pause() external;

    /// @notice Unpauses the contract.
    /// @dev Caller must hold DEFAULT_ADMIN_ROLE. Lifting a pause is the privileged half of the
    ///      pair, so a compromised pauser cannot undo its own halt. Banks the length of the
    ///      pause, shifting the deadlines of escrows that were open while it ran.
    function unpause() external;

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @notice Returns the full on-chain record for an escrow deposit.
    function getEscrow(uint256 escrowId) external view returns (EscrowRecord memory);

    /// @notice Returns the total number of escrow records created (including settled ones).
    function totalEscrows() external view returns (uint256);

    /// @notice Returns the USDC token contract address.
    function usdc() external view returns (address);

    /// @notice Returns the seconds this contract has spent paused, over every completed pause.
    function totalPausedSeconds() external view returns (uint40);

    /// @notice Returns the settlement window (in seconds) applied to new deposits.
    function settlementWindow() external view returns (uint40);

    /// @notice Returns true if the contract is currently paused.
    function paused() external view returns (bool);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when deposit is called by an address other than SplitRouter.
    error CallerNotSplitRouter(address caller);

    /// @notice Thrown when a settlement function is called on an already-Settled escrow.
    error AlreadySettled(uint256 escrowId);

    /// @notice Thrown when cashbackToReviewer is called after cashback was already released.
    error CashbackAlreadyReleased(uint256 escrowId);

    /// @notice Thrown when a time-gated function is called before the required delay.
    error TooEarly(uint256 escrowId, uint256 eligibleAt, uint256 currentTime);

    /// @notice Thrown when a query targets an escrowId that does not exist.
    error EscrowNotFound(uint256 escrowId);

    /// @notice Thrown when unlockPct > 100 is passed to settleHeldBack.
    error UnlockPctOutOfRange(uint8 unlockPct);

    /// @notice Thrown when setSettlementWindow is called with a value < 1 days or > 180 days.
    error SettlementWindowOutOfBounds(uint40 window);

    /// @notice Thrown when deposit is called with buyerWallet == address(0). Every escrow must
    ///         record a real paying wallet (consumed by the agent-less bind/claim flow).
    error ZeroBuyerWallet();

    /// @notice Thrown when releaseCashback is called for an un-bound agent-less escrow
    ///         (buyerAgentId == SENTINEL_BUYER). The buyer can't be resolved until bind.
    error BuyerNotBound(uint256 escrowId);

    /// @notice Thrown when bind targets an escrow that isn't an agent-less sentinel (already bound).
    error AlreadyBound(uint256 escrowId);

    /// @notice Thrown when bind's caller is not the wallet recorded at purchase.
    error NotBuyerWallet(uint256 escrowId, address caller);

    /// @notice Thrown when bind's caller is neither the owner nor the agentWallet of the agent id.
    error NotAgentController(uint256 agentId, address caller);
}
