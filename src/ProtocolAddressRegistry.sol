// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProtocolAddressRegistry} from "./interfaces/IProtocolAddressRegistry.sol";

/// @title ProtocolAddressRegistry (PAR)
/// @notice Single source of truth for protocol contract addresses, with time-locked updates.
/// @dev Every core contract resolves its peers through `getAddress(key)` at call time, so
///      re-pointing one key here is how an immutable contract is "upgraded": deploy the new
///      implementation, queue the new address, wait out the delay, execute. The exception is
///      `AGENT_REGISTRY`, which peers cache as an `immutable` at construction and which therefore
///      cannot be re-pointed once set: `setAddress` reverts `ImmutableKey` (README §4).
///
///      Two-phase updates: `setAddress` queues `(value, effectiveAt = now + delay)` under `key`;
///      `executeUpdate` (permissionless) applies it once `effectiveAt` has passed; `cancelUpdate`
///      (owner) discards it. At most one pending update per key. The permissionless execute means
///      the owner cannot queue-and-forget as a way of stalling — anyone can finish the update —
///      and conversely cannot reliably cancel at the last instant (a known, accepted race).
///
///      The delay itself is mutable but self-timelocked: `setTimelockDelay` queues behind the
///      CURRENT delay, so shortening the delay takes as long as the delay being replaced. A
///      compromised owner therefore cannot collapse the delay and re-point in one bundle.
///      Hard cap `MAX_TIMELOCK_DELAY` prevents the owner from parking the delay out of reach.
///
///      Trust: the owner is a single `Ownable2Step` key (intended to become a multisig). It cannot
///      set a zero address, cannot bypass the delay for existing keys, and cannot bypass the delay
///      when changing the delay. `renounceOwnership()` reverts, so the address set can never be
///      frozen, and ownership moves in two steps, so a handover to a wrong address is recoverable.
///      The constructor is the only path that writes without delay and runs while the deployer is
///      sole owner (`Deploy.s.sol` seeds AGENT_REGISTRY + TREASURY).
///
///      Guardian: an immutable second key that may CANCEL a queued update, alongside the owner.
///      It can never queue or execute one. It is what survives a stolen owner key: ownership
///      itself is not timelocked, so an attacker can queue a malicious update and then take
///      ownership, leaving nobody able to cancel before the permissionless `executeUpdate`
///      applies it. The guardian cancels regardless of who owns the contract. Losing the guardian
///      key costs only the second brake — the owner can still cancel.
contract ProtocolAddressRegistry is IProtocolAddressRegistry, Ownable2Step {
    // =========================================================================
    // Registry keys
    // =========================================================================
    // Keys are keccak256 of their names so off-chain tooling can derive them without an ABI call.
    // Constants are also exposed as view functions via the interface for on-chain callers.

    bytes32 public constant AGENT_REGISTRY = keccak256("AGENT_REGISTRY"); // ERC-8004 IdentityRegistry; cached by peers, never re-pointed
    bytes32 public constant MERCHANT_REGISTRY = keccak256("MERCHANT_REGISTRY");
    bytes32 public constant PRODUCT_REGISTRY = keccak256("PRODUCT_REGISTRY");
    bytes32 public constant REVIEW_REGISTRY = keccak256("REVIEW_REGISTRY");
    bytes32 public constant ESCROW = keccak256("ESCROW"); // CommissionEscrow
    bytes32 public constant SPLIT_ROUTER = keccak256("SPLIT_ROUTER"); // the ONLY address allowed to call CommissionEscrow.deposit
    bytes32 public constant KEEPER = keccak256("KEEPER"); // registered, not read by any contract today
    bytes32 public constant TREASURY = keccak256("TREASURY"); // platform-fee + fallback recipient; read at every settlement

    /// @dev Second key that may cancel a queued update. Immutable on purpose: an owner-settable
    ///      guardian is one that a stolen owner key rotates away before queueing.
    address private immutable _GUARDIAN;

    // =========================================================================
    // State
    // =========================================================================

    /// @dev Mutable, unlike the address entries' own delay semantics: changing it queues behind
    ///      the CURRENT value, so a compromised owner cannot set zero and repoint in one bundle.
    ///      NOT bounded by `MAX_TIMELOCK_DELAY` in the constructor — `Deploy.s.sol` passes 0 and
    ///      raises it through the self-timelocked path as its final step.
    uint256 private _timelockDelay;

    /// @dev Ceiling so an owner cannot park the delay beyond reach and lock out rotation.
    uint256 private constant MAX_TIMELOCK_DELAY = 7 days;

    /// @dev Live addresses. A zero value means "not set" and makes `getAddress` revert.
    mapping(bytes32 => address) private _addresses;

    /// @dev Queued address update. `effectiveAt == 0` doubles as "nothing pending" because
    ///      `block.timestamp + delay` is never zero on a live chain.
    struct Pending {
        address value;
        uint256 effectiveAt;
    }

    /// @dev Queued delay update; same `effectiveAt == 0` sentinel convention.
    struct PendingTimelockDelay {
        uint256 value;
        uint256 effectiveAt;
    }

    /// @dev One pending slot per key; a second `setAddress` on the same key reverts until the
    ///      first is executed or cancelled.
    mapping(bytes32 => Pending) private _pending;

    /// @dev Single pending slot for the delay itself.
    PendingTimelockDelay private _pendingTimelockDelay;

    /// @dev Cancelling is the one action the guardian shares with the owner.
    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != _GUARDIAN) revert NotOwnerOrGuardian(msg.sender);
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param initialOwner   `Ownable2Step` owner (queues/cancels updates, changes delay).
    /// @param guardian_       Immutable second key that may cancel a queued update. Cannot be zero.
    /// @param timelockDelay_ Initial delay in seconds. Not bounded here (see `_timelockDelay`).
    /// @param keys           Registry keys to seed without a delay.
    /// @param values         Addresses for `keys`, positionally. Zero addresses rejected.
    /// @dev Seeding here is the only delay-free write path. `Deploy.s.sol` uses it for
    ///      `AGENT_REGISTRY` (peers cache it as immutable at their own construction, so it must
    ///      exist first) and `TREASURY` (read at every settlement; queueing it would brick payments
    ///      for one delay window). Emits `TimelockDelayUpdated(0, delay)` and
    ///      `AddressUpdated(key, 0, value)` per seeded key so indexers see the same event shapes
    ///      as a later execute.
    constructor(
        address initialOwner,
        address guardian_,
        uint256 timelockDelay_,
        bytes32[] memory keys,
        address[] memory values
    ) Ownable(initialOwner) {
        if (guardian_ == address(0)) revert ZeroAddress();
        _GUARDIAN = guardian_;
        if (keys.length != values.length) revert LengthMismatch();
        _timelockDelay = timelockDelay_;
        emit TimelockDelayUpdated(0, timelockDelay_);
        for (uint256 i = 0; i < keys.length; ++i) {
            if (values[i] == address(0)) revert ZeroAddress();
            _addresses[keys[i]] = values[i];
            emit AddressUpdated(keys[i], address(0), values[i]);
        }
    }

    // =========================================================================
    // Admin — write
    // =========================================================================

    /// @inheritdoc IProtocolAddressRegistry
    /// @dev Owner only. Queues, never applies. Applies to first-time sets as well: a key that has
    ///      never been set still waits out the full delay (hence constructor seeding, above).
    ///      Reverts `UpdateAlreadyPending` rather than overwriting — the owner must cancel first,
    ///      which emits its own event and keeps the queue auditable. Reverts `ImmutableKey` for
    ///      `AGENT_REGISTRY` once it holds a value; an unseeded key may still be set once.
    function setAddress(bytes32 key, address newValue) external onlyOwner {
        if (newValue == address(0)) revert ZeroAddress();
        if (key == AGENT_REGISTRY && _addresses[key] != address(0)) revert ImmutableKey(key);
        if (_pending[key].effectiveAt != 0) revert UpdateAlreadyPending(key);

        uint256 effectiveAt = block.timestamp + _timelockDelay;
        _pending[key] = Pending({value: newValue, effectiveAt: effectiveAt});
        emit AddressQueued(key, newValue, effectiveAt);
    }

    /// @inheritdoc IProtocolAddressRegistry
    /// @dev Permissionless by design: once the delay has elapsed the update is considered
    ///      approved, and anyone (keeper, owner, watcher) may apply it. Reads the pending slot
    ///      into memory, clears it, then writes — the `effectiveAt == 0` check makes an execute
    ///      on an empty slot revert `NoPendingUpdate` instead of writing a zero address.
    function executeUpdate(bytes32 key) external {
        Pending memory p = _pending[key];
        if (p.effectiveAt == 0) revert NoPendingUpdate(key);
        if (block.timestamp < p.effectiveAt) revert TimelockNotExpired(p.effectiveAt, block.timestamp);

        address oldValue = _addresses[key];
        _addresses[key] = p.value;
        delete _pending[key];
        emit AddressUpdated(key, oldValue, p.value);
    }

    /// @inheritdoc IProtocolAddressRegistry
    /// @dev Owner or guardian. Discards the pending value without touching the live address.
    ///      Cannot cancel an update already executed (slot is empty → `NoPendingUpdate`).
    function cancelUpdate(bytes32 key) external onlyOwnerOrGuardian {
        if (_pending[key].effectiveAt == 0) revert NoPendingUpdate(key);
        delete _pending[key];
        emit AddressUpdateCancelled(key);
    }

    /// @inheritdoc IProtocolAddressRegistry
    /// @dev Owner only. Queues under the CURRENT `_timelockDelay`, not the new one, so lowering
    ///      the delay is as slow as the delay it replaces (raising it is equally slow — there is
    ///      no fast path in either direction). Bounded by `MAX_TIMELOCK_DELAY`; zero is allowed
    ///      (that is what `Deploy.s.sol` starts from) but reaching zero from a non-zero delay
    ///      still requires waiting out the non-zero delay.
    function setTimelockDelay(uint256 newDelay) external onlyOwner {
        if (newDelay > MAX_TIMELOCK_DELAY) revert InvalidTimelockDelay();
        if (_pendingTimelockDelay.effectiveAt != 0) revert TimelockDelayUpdateAlreadyPending();

        uint256 effectiveAt = block.timestamp + _timelockDelay;
        _pendingTimelockDelay = PendingTimelockDelay({value: newDelay, effectiveAt: effectiveAt});

        emit TimelockDelayQueued(newDelay, effectiveAt);
    }

    /// @inheritdoc IProtocolAddressRegistry
    /// @dev Permissionless, like `executeUpdate`. The `NoPendingTimelockDelayUpdate` guard is
    ///      load-bearing: without it an unqueued call would read a zero pending struct, pass the
    ///      maturity check (`effectiveAt == 0` is always in the past) and write `0` into the live
    ///      delay — disabling the time-lock permissionlessly (README §4).
    function executeTimelockDelayUpdate() external {
        PendingTimelockDelay memory p = _pendingTimelockDelay;
        if (p.effectiveAt == 0) revert NoPendingTimelockDelayUpdate();
        if (block.timestamp < p.effectiveAt) revert TimelockNotExpired(p.effectiveAt, block.timestamp);

        uint256 oldValue = _timelockDelay;
        _timelockDelay = p.value;
        delete _pendingTimelockDelay;
        emit TimelockDelayUpdated(oldValue, p.value);
    }

    /// @inheritdoc IProtocolAddressRegistry
    /// @dev Owner or guardian. Discards a queued delay change; the live delay is untouched. The
    ///      guardian needs this as well as `cancelUpdate`: a delay cut to zero, left to mature,
    ///      would let every later update be queued and executed in one block, leaving no window
    ///      to cancel in.
    function cancelTimelockDelayUpdate() external onlyOwnerOrGuardian {
        if (_pendingTimelockDelay.effectiveAt == 0) revert NoPendingTimelockDelayUpdate();
        delete _pendingTimelockDelay;
        emit TimelockDelayUpdateCancelled();
    }

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @inheritdoc IProtocolAddressRegistry
    function timelockDelay() external view returns (uint256) {
        return _timelockDelay;
    }

    /// @inheritdoc IProtocolAddressRegistry
    /// @dev Reverts `AddressNotSet` for an unset key instead of returning zero. Every peer
    ///      resolves through this on the hot path, so an unset `TREASURY`/`ESCROW`/`SPLIT_ROUTER`
    ///      fails settlement loudly rather than transferring to `address(0)`.
    function getAddress(bytes32 key) external view returns (address) {
        address addr = _addresses[key];
        if (addr == address(0)) revert AddressNotSet(key);
        return addr;
    }

    /// @inheritdoc IProtocolAddressRegistry
    /// @dev Returns `(0, 0)` when nothing is pending; does not revert.
    function getPending(bytes32 key) external view returns (address pendingValue, uint256 effectiveAt) {
        Pending memory p = _pending[key];
        return (p.value, p.effectiveAt);
    }

    /// @inheritdoc IProtocolAddressRegistry
    function guardian() external view returns (address) {
        return _GUARDIAN;
    }

    /// @notice Permanently disabled: always reverts `RenounceDisabled`.
    /// @dev Renouncing would freeze every address forever, and the two-step transfer already
    ///      makes handing ownership to a multisig recoverable.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
