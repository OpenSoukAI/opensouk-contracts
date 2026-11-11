// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IProtocolAddressRegistry
/// @notice Single source of truth for the canonical address of every protocol contract.
///         All other contracts read peer addresses from this registry at construction time
///         and cache them as immutables. This contract's own address is the one truly
///         permanent value in the system — it must be hardcoded in Go config and frontend.
/// @dev    Not upgradeable. Uses OpenZeppelin Ownable for admin access.
///         A time-lock on setAddress is strongly recommended for mainnet to prevent an
///         admin from instantly redirecting critical addresses such as ESCROW or ORACLE.
///         See protocol design doc 07-open-questions.md Q6.
interface IProtocolAddressRegistry {
    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a contract address is queued for update.
    /// @param key      The registry key being updated (e.g. keccak256("ESCROW")).
    /// @param newValue The address that will take effect after the time-lock delay.
    /// @param effectiveAt The timestamp at which the new address becomes active.
    event AddressQueued(bytes32 indexed key, address indexed newValue, uint256 effectiveAt);

    /// @notice Emitted when a queued address update is executed and takes effect.
    /// @param key      The registry key that was updated.
    /// @param oldValue The address that was previously active.
    /// @param newValue The address now active.
    event AddressUpdated(bytes32 indexed key, address indexed oldValue, address indexed newValue);

    /// @notice Emitted when a queued address update is cancelled before execution.
    /// @param key The registry key whose pending update was cancelled.
    event AddressUpdateCancelled(bytes32 indexed key);

    /// @notice Emitted when a change to the timelock delay is queued. Watched off chain: a queued
    ///         change that nobody expected is the signal that the owner key is in the wrong hands.
    event TimelockDelayQueued(uint256 newValue, uint256 effectiveAt);

    /// @notice Emitted when a queued timelock delay change is applied.
    event TimelockDelayUpdated(uint256 oldValue, uint256 newValue);

    /// @notice Emitted when a queued timelock delay change is withdrawn before it applies.
    event TimelockDelayUpdateCancelled();

    // =========================================================================
    // Registry keys — used as arguments to setAddress / getAddress
    // =========================================================================

    /// @notice Returns the key for the AgentRegistry contract address.
    function AGENT_REGISTRY() external view returns (bytes32);

    /// @notice Returns the key for the MerchantRegistry contract address.
    function MERCHANT_REGISTRY() external view returns (bytes32);

    /// @notice Returns the key for the ProductRegistry contract address.
    function PRODUCT_REGISTRY() external view returns (bytes32);

    /// @notice Returns the key for the ReviewRegistry contract address.
    function REVIEW_REGISTRY() external view returns (bytes32);

    /// @notice Returns the key for the CommissionEscrow contract address.
    function ESCROW() external view returns (bytes32);

    /// @notice Returns the key for the SplitRouter contract address.
    function SPLIT_ROUTER() external view returns (bytes32);

    /// @notice Returns the key for the Chainlink Automation forwarder address.
    function KEEPER() external view returns (bytes32);

    /// @notice Returns the key for the protocol fee treasury address.
    function TREASURY() external view returns (bytes32);

    // =========================================================================
    // Admin — write
    // =========================================================================

    /// @notice Queues an address update for a given registry key.
    ///         The update takes effect after the time-lock delay has elapsed.
    ///         Only one pending update per key is permitted at a time.
    /// @dev    Caller must hold the owner / admin role.
    ///         Emits AddressQueued.
    ///         Reverts ImmutableKey for AGENT_REGISTRY once it has been set.
    /// @param key      The registry key to update. Must be one of the defined key constants.
    /// @param newValue The new address to set. Must not be the zero address.
    function setAddress(bytes32 key, address newValue) external;

    /// @notice Executes a previously queued address update after the time-lock has elapsed.
    /// @dev    Anyone may call this once the time-lock delay has passed, allowing the
    ///         update to be executed without requiring admin involvement if they are unavailable.
    ///         Emits AddressUpdated.
    /// @param key The registry key whose queued update should be executed.
    function executeUpdate(bytes32 key) external;

    /// @notice Cancels a pending address update before it takes effect.
    /// @dev    Caller must hold the owner / admin role.
    ///         Emits AddressUpdateCancelled.
    /// @param key The registry key whose pending update should be cancelled.
    function cancelUpdate(bytes32 key) external;

    /// @notice Queues a change to the timelock delay. The change itself waits out the CURRENT
    ///         delay, so the delay can never be shortened faster than it currently promises.
    /// @param newDelay The new delay in seconds; must not exceed the contract's ceiling.
    function setTimelockDelay(uint256 newDelay) external;

    /// @notice Applies a matured timelock delay change. Permissionless, like executeUpdate.
    function executeTimelockDelayUpdate() external;

    /// @notice Withdraws a queued timelock delay change before it applies.
    function cancelTimelockDelayUpdate() external;

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @notice Returns the currently active address for a given registry key.
    /// @dev    Reverts with AddressNotSet if the key has never been set.
    ///         Contracts should call this at construction and cache the result
    ///         as an immutable to avoid repeated external calls on hot paths.
    /// @param key The registry key to look up.
    /// @return The active address registered under that key.
    function getAddress(bytes32 key) external view returns (address);

    /// @notice Returns the pending (not yet active) address for a key, if any.
    /// @param key The registry key to query.
    /// @return pendingValue The queued address, or zero address if none pending.
    /// @return effectiveAt  The timestamp at which it will become active, or zero if none pending.
    function getPending(bytes32 key) external view returns (address pendingValue, uint256 effectiveAt);

    /// @notice Returns the time-lock delay in seconds applied to all address updates.
    function timelockDelay() external view returns (uint256);

    /// @notice Returns the guardian: an immutable second key that may cancel a queued update,
    ///         alongside the owner. It can never queue or execute one.
    function guardian() external view returns (address);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when getAddress is called for a key that has never been set.
    error AddressNotSet(bytes32 key);

    /// @notice Thrown when setAddress is called with the zero address, or the constructor is
    ///         given a zero guardian.
    error ZeroAddress();

    /// @notice Thrown when a cancel is attempted by neither the owner nor the guardian.
    error NotOwnerOrGuardian(address caller);

    /// @notice Thrown by renounceOwnership, which is permanently disabled.
    error RenounceDisabled();

    /// @notice Thrown when executeUpdate is called before the time-lock has elapsed.
    error TimelockNotExpired(uint256 effectiveAt, uint256 currentTime);

    /// @notice Thrown when executeUpdate or cancelUpdate is called with no pending update.
    error NoPendingUpdate(bytes32 key);

    /// @notice Thrown when setAddress is called while an update for that key is already pending.
    error UpdateAlreadyPending(bytes32 key);

    /// @notice Thrown when setAddress targets AGENT_REGISTRY after it has been set; peers cache it
    ///         as an immutable, so a re-point would diverge them.
    error ImmutableKey(bytes32 key);

    /// @notice Thrown when the constructor keys and values arrays have different lengths.
    error LengthMismatch();

    /// @notice Thrown when the requested delay exceeds the contract's ceiling.
    error InvalidTimelockDelay();

    /// @notice Thrown when executing or cancelling a timelock delay change that was never queued.
    error NoPendingTimelockDelayUpdate();

    /// @notice Thrown when queuing a timelock delay change while one is already pending.
    error TimelockDelayUpdateAlreadyPending();
}
