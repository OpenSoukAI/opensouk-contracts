// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IMerchantRegistry} from "./interfaces/IMerchantRegistry.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IProtocolAddressRegistry} from "./interfaces/IProtocolAddressRegistry.sol";
import {MerchantAccessControl} from "./MerchantAccessControl.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title MerchantRegistry
/// @notice Merchant status (active / suspended) plus per-merchant role delegation.
/// @dev A merchant IS an ERC-8004 identity: `merchantId` is a token id in the shared
///      `IdentityRegistry`, and "merchant owner" means `ownerOf(merchantId)`. There is no separate
///      merchant registration step — any identity holder can flip themselves active. Whether a
///      merchant can actually sell is decided downstream: `ProductRegistry.addProduct` and both
///      `SplitRouter` rails require `isActive(merchantId)`.
///
///      Two independent flags decide `isActive`:
///        - `_active`    — set by the merchant owner via `setActive`.
///        - `_suspended` — set by the protocol admin via `suspend`/`unsuspend`.
///      A merchant is active only when `_active && !_suspended`, and an owner cannot re-activate
///      while suspended (`MerchantIsSuspended`). Suspension therefore always wins.
///
///      Roles: the owner implicitly holds every merchant role (see `hasRole`) and is the only party
///      who may delegate them. Delegated grants live in `MerchantAccessControl` storage keyed by
///      `(merchantId, role)`; they are NOT cleared when the identity NFT changes hands, so a new
///      owner inherits the previous owner's grantees until it revokes them (known, accepted).
///
///      Trust: `_AGENT_REGISTRY` is cached as an immutable (see README §4) — this contract must
///      agree with `ReviewRegistry`, `CommissionEscrow` and `SplitRouter` on which identity
///      registry defines a merchant, otherwise the same `merchantId` could resolve to different owners.
contract MerchantRegistry is IMerchantRegistry, MerchantAccessControl {
    /// @dev Protocol address registry; only used in the constructor to resolve `AGENT_REGISTRY`.
    IProtocolAddressRegistry private immutable _PROTOCOL;
    /// @dev ERC-8004 identity registry, cached at deploy (never re-resolved; see the contract header).
    IIdentityRegistry private immutable _AGENT_REGISTRY;

    /// @dev Owner-controlled flag. Defaults false: a fresh identity is not a selling merchant.
    mapping(uint256 => bool) private _active;
    /// @dev Admin-controlled flag. Overrides `_active` in `isActive` and blocks `setActive(true)`.
    mapping(uint256 => bool) private _suspended;

    /// @dev Restricts a call to the current NFT owner of `merchantId`. Reverts `MerchantNotFound`
    ///      for a non-existent token (via `_requireMerchantExists`), `NotMerchantOwner` otherwise.
    modifier onlyMerchantAdmin(uint256 merchantId) {
        _onlyMerchantAdmin(merchantId);
        _;
    }

    /// @dev Body of `onlyMerchantAdmin`, split out so the modifier's bytecode is not inlined
    ///      into every guarded function.
    function _onlyMerchantAdmin(uint256 merchantId) internal view {
        address owner = _requireMerchantExists(merchantId);
        if (msg.sender != owner) {
            revert NotMerchantOwner(merchantId, msg.sender);
        }
    }

    /// @param protocolAddressRegistry ProtocolAddressRegistry (PAR). `AGENT_REGISTRY` must already
    ///                                be set on it or `getAddress` reverts `AddressNotSet`.
    /// @param admin                   Receives `DEFAULT_ADMIN_ROLE` (suspend/unsuspend + admin rotation).
    ///                                Not zero-checked: a zero admin permanently disables suspension.
    constructor(address protocolAddressRegistry, address admin) {
        _PROTOCOL = IProtocolAddressRegistry(protocolAddressRegistry);
        // Resolve once and cache: see README §4 for why AGENT_REGISTRY is immutable everywhere.
        _AGENT_REGISTRY = IIdentityRegistry(
            IProtocolAddressRegistry(protocolAddressRegistry)
                .getAddress(IProtocolAddressRegistry(protocolAddressRegistry).AGENT_REGISTRY())
        );
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // =========================================================================
    // Owner / MERCHANT_ADMIN — write
    // =========================================================================

    /// @inheritdoc IMerchantRegistry
    /// @dev Owner only. Re-activation is refused while suspended so the admin's suspension cannot
    ///      be undone by the merchant; deactivation is always allowed. Emits even on a no-op flip.
    function setActive(uint256 merchantId, bool active) external onlyMerchantAdmin(merchantId) {
        if (active && _suspended[merchantId]) {
            revert MerchantIsSuspended(merchantId);
        }
        _active[merchantId] = active;
        emit MerchantActiveSet(merchantId, active);
    }

    /// @inheritdoc IMerchantRegistry
    /// @dev Owner only. Whitelist + namespacing happen in `MerchantAccessControl._grantRole`;
    ///      this layer adds the owner gate and the indexed event (the flat OZ `RoleGranted` event
    ///      also fires, keyed by the derived role id).
    function grantRole(uint256 merchantId, bytes32 role, address account) external onlyMerchantAdmin(merchantId) {
        _grantRole(merchantId, role, account);
        emit MerchantRoleGranted(merchantId, role, account, msg.sender);
    }

    /// @inheritdoc IMerchantRegistry
    /// @dev Owner only. Mirror of `grantRole`.
    function revokeRole(uint256 merchantId, bytes32 role, address account) external onlyMerchantAdmin(merchantId) {
        _revokeRole(merchantId, role, account);
        emit MerchantRoleRevoked(merchantId, role, account, msg.sender);
    }

    /// @dev MR-01: lock down the inherited flat AccessControl grantRole/revokeRole(bytes32,address)
    ///      so DEFAULT_ADMIN cannot assign per-merchant roles directly (bypassing owner-gating,
    ///      _roleExists, and the MerchantRole* events). Only DEFAULT_ADMIN_ROLE itself may be moved
    ///      via the flat path (admin key rotation); everything else must use the 3-arg owner path.
    ///      `super.grantRole` still enforces OZ's `onlyRole(getRoleAdmin(role))`, i.e. only a
    ///      current admin can add another admin.
    function grantRole(bytes32 role, address account) public override {
        if (role != DEFAULT_ADMIN_ROLE) revert UseMerchantScopedRole();
        super.grantRole(role, account);
    }

    /// @dev Flat-path revoke, restricted exactly like the flat-path grant above. Note that a
    ///      derived merchant role id can never equal `DEFAULT_ADMIN_ROLE` (bytes32(0)) in practice,
    ///      so merchant grants are unreachable from here.
    function revokeRole(bytes32 role, address account) public override {
        if (role != DEFAULT_ADMIN_ROLE) revert UseMerchantScopedRole();
        super.revokeRole(role, account);
    }

    /// @inheritdoc IMerchantRegistry
    /// @dev The NFT owner implicitly holds every merchant role, so consumers (ProductRegistry,
    ///      off-chain facilitator) need a single call. Reverts `MerchantNotFound` for an unminted
    ///      id and `InvalidRole` for a role outside the whitelist — both are caller bugs, not
    ///      "false" answers. Ownership is read live: transferring the identity NFT moves the
    ///      implicit roles instantly, while explicit grants persist (see the contract header).
    function hasRole(uint256 merchantId, bytes32 role, address account) external view returns (bool) {
        address owner = _requireMerchantExists(merchantId);
        if (owner == account) {
            return true;
        }
        return _hasRole(merchantId, role, account);
    }

    // =========================================================================
    // Protocol admin — write
    // =========================================================================

    /// @inheritdoc IMerchantRegistry
    /// @dev `DEFAULT_ADMIN_ROLE` only. Idempotent (re-suspending re-emits). Does not touch
    ///      `_active`, so unsuspending restores whatever the owner had set. `reason` is
    ///      event-only — nothing on-chain reads it.
    function suspend(uint256 merchantId, string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireMerchantExists(merchantId);
        _suspended[merchantId] = true;
        emit MerchantSuspended(merchantId, reason);
    }

    /// @inheritdoc IMerchantRegistry
    /// @dev `DEFAULT_ADMIN_ROLE` only. Idempotent.
    function unsuspend(uint256 merchantId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireMerchantExists(merchantId);
        _suspended[merchantId] = false;
        emit MerchantUnsuspended(merchantId);
    }

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @inheritdoc IMerchantRegistry
    /// @dev Reverts `MerchantNotFound` for an unminted id rather than returning false. Callers
    ///      that must not revert on a missing merchant (`ProductRegistry.isProductActive`) wrap
    ///      this in try/catch.
    function isActive(uint256 merchantId) external view returns (bool) {
        _requireMerchantExists(merchantId);
        return _active[merchantId] && !_suspended[merchantId];
    }

    /// @inheritdoc IMerchantRegistry
    /// @dev Reverts `MerchantNotFound` for an unminted id.
    function isSuspended(uint256 merchantId) external view returns (bool) {
        _requireMerchantExists(merchantId);
        return _suspended[merchantId];
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Accessor for the cached identity registry (kept as a function so the read site
    ///      documents intent; it never re-resolves from PAR).
    function _identityRegistry() internal view returns (IIdentityRegistry) {
        return _AGENT_REGISTRY;
    }

    /// @dev Existence check doubling as owner lookup. ERC-721 `ownerOf` reverts for an unminted
    ///      token, so the try/catch converts that low-level revert into `MerchantNotFound`.
    ///      Any other revert reason from the registry (e.g. a broken registry address) is
    ///      also mapped to `MerchantNotFound` — the catch is not selective.
    /// @param merchantId Identity token id.
    /// @return owner Current NFT owner of `merchantId`.
    function _requireMerchantExists(uint256 merchantId) internal view returns (address owner) {
        try IERC721(address(_identityRegistry())).ownerOf(merchantId) returns (address o) {
            owner = o;
        } catch {
            revert MerchantNotFound(merchantId);
        }
    }
}
