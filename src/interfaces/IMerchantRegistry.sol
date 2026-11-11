// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IMerchantRegistry
/// @notice Merchant status and access-control registry. Uses ERC-8004 IIdentityRegistry
///         NFTs as merchant identities — merchantId equals the agentId issued by that registry.
///         No NFT is minted here. Stores only what the protocol needs on-chain:
///         active/suspended status. Commission rates live in ProductRegistry — not here.
///
///         Per-merchant role-based access control allows the IIdentityRegistry NFT owner
///         to delegate specific permissions to team member addresses, scoped strictly to
///         their merchantId. The NFT owner always retains all permissions regardless of
///         role assignments.
///
/// @dev    Roles are stored in a three-dimensional mapping:
///           merchantId → role → address → granted (bool)
///         Ownership is resolved by querying IIdentityRegistry. Role checks for
///         ProductRegistry write operations are performed by calling hasRole() on this
///         contract from ProductRegistry.
///         Protocol-level suspension (suspend / unsuspend) requires DEFAULT_ADMIN_ROLE
///         and overrides the merchant's own active flag.
interface IMerchantRegistry {
    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a merchant changes their own active flag.
    /// @param merchantId The merchant whose active status changed.
    /// @param active     The new active status.
    event MerchantActiveSet(uint256 indexed merchantId, bool indexed active);

    /// @notice Emitted when the protocol admin suspends a merchant.
    /// @param merchantId The merchant that was suspended.
    /// @param reason     A human-readable reason string stored off-chain reference.
    event MerchantSuspended(uint256 indexed merchantId, string reason);

    /// @notice Emitted when the protocol admin lifts a suspension.
    /// @param merchantId The merchant that was unsuspended.
    event MerchantUnsuspended(uint256 indexed merchantId);

    /// @notice Emitted when a per-merchant role is granted to an address.
    /// @param merchantId The merchant whose role was granted.
    /// @param role       The role constant (PRODUCT_MANAGER or COMMISSION_MANAGER).
    /// @param account    The address that received the role.
    /// @param grantor    The address that performed the grant (owner or MERCHANT_ADMIN).
    event MerchantRoleGranted(
        uint256 indexed merchantId, bytes32 indexed role, address indexed account, address grantor
    );

    /// @notice Emitted when a per-merchant role is revoked from an address.
    /// @param merchantId The merchant whose role was revoked.
    /// @param role       The role constant that was revoked.
    /// @param account    The address from which the role was removed.
    /// @param revoker    The address that performed the revocation.
    event MerchantRoleRevoked(
        uint256 indexed merchantId, bytes32 indexed role, address indexed account, address revoker
    );

    // =========================================================================
    // Owner / MERCHANT_ADMIN — write
    // =========================================================================

    /// @notice Sets the merchant's own active flag. Inactive merchants will not have
    ///         their products discoverable and the SplitRouter will revert on purchases.
    ///         Does not override a protocol-level suspension — a suspended merchant
    ///         cannot reactivate themselves.
    /// @dev    Callable only by the IIdentityRegistry NFT owner for this merchantId.
    ///         Emits MerchantActiveSet.
    /// @param merchantId The agentId from IIdentityRegistry that identifies this merchant.
    /// @param active     True to mark the merchant active; false to pause.
    function setActive(uint256 merchantId, bool active) external;

    // =========================================================================
    // Protocol admin — write
    // =========================================================================

    /// @notice Suspends a merchant at the protocol level. Overrides their own active flag.
    ///         A suspended merchant cannot reinstate themselves — only the admin can lift it.
    ///         Used for compliance violations, fraud, or terms-of-service breaches.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Emits MerchantSuspended.
    /// @param merchantId The agentId from IIdentityRegistry that identifies this merchant.
    /// @param reason     A short human-readable reason (stored as an event, not in contract state).
    function suspend(uint256 merchantId, string calldata reason) external;

    /// @notice Lifts a protocol-level suspension, restoring the merchant's previous active state.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Emits MerchantUnsuspended.
    /// @param merchantId The agentId from IIdentityRegistry that identifies this merchant.
    function unsuspend(uint256 merchantId) external;

    // =========================================================================
    // Per-merchant role management
    // =========================================================================

    /// @notice Grants a per-merchant role to an address, scoped to the given merchantId.
    ///         Callable by the IIdentityRegistry NFT owner or any address holding
    ///         MERCHANT_ADMIN for this merchant. The NFT owner is implicitly a
    ///         MERCHANT_ADMIN and requires no explicit assignment.
    /// @dev    Emits MerchantRoleGranted.
    /// @param merchantId The agentId from IIdentityRegistry that identifies this merchant.
    /// @param role       The role to grant. Must be PRODUCT_MANAGER or COMMISSION_MANAGER.
    /// @param account    The address to grant the role to.
    function grantRole(uint256 merchantId, bytes32 role, address account) external;

    /// @notice Revokes a per-merchant role from an address.
    ///         Callable by the IIdentityRegistry NFT owner or any address holding
    ///         MERCHANT_ADMIN for this merchant.
    /// @dev    Emits MerchantRoleRevoked.
    /// @param merchantId The agentId from IIdentityRegistry that identifies this merchant.
    /// @param role       The role to revoke.
    /// @param account    The address to revoke the role from.
    function revokeRole(uint256 merchantId, bytes32 role, address account) external;

    // =========================================================================
    // Public — read
    // =========================================================================

    /// @notice Returns true if the given address holds the specified role for this merchant,
    ///         OR if the address is the IIdentityRegistry NFT owner (who holds all roles
    ///         implicitly). Called by ProductRegistry on all write operations to enforce
    ///         access control.
    /// @param merchantId The agentId from IIdentityRegistry that identifies this merchant.
    /// @param role       The role to check.
    /// @param account    The address to check.
    /// @return True if the address has the role or is the IIdentityRegistry NFT owner.
    function hasRole(uint256 merchantId, bytes32 role, address account) external view returns (bool);

    /// @notice Returns true if the merchant is active and not suspended.
    ///         Checked by SplitRouter before processing a purchase and by the backend
    ///         before resolving a ref link.
    /// @param merchantId The agentId from IIdentityRegistry that identifies this merchant.
    /// @return True if the merchant can currently accept purchases.
    function isActive(uint256 merchantId) external view returns (bool);

    /// @notice Returns true if the merchant has been suspended by the protocol admin.
    /// @param merchantId The agentId from IIdentityRegistry that identifies this merchant.
    function isSuspended(uint256 merchantId) external view returns (bool);

    // =========================================================================
    // Errors
    // =========================================================================
    /// @notice Thrown when an operation requires the IIdentityRegistry NFT owner but is
    ///         called by another address.
    error NotMerchantOwner(uint256 merchantId, address caller);

    /// @notice Thrown when a suspended merchant attempts to reactivate themselves.
    error MerchantIsSuspended(uint256 merchantId);

    /// @notice Thrown when a query is made for an agentId that has not been seen by this
    ///         registry (i.e. has no active/suspended state recorded).
    error MerchantNotFound(uint256 merchantId);

    /// @notice Thrown when the inherited flat AccessControl grantRole/revokeRole(bytes32,address)
    ///         is called for any role other than DEFAULT_ADMIN_ROLE. Per-merchant roles must be
    ///         managed via the owner-gated 3-arg grantRole/revokeRole(merchantId, role, account),
    ///         which validates the role and emits MerchantRoleGranted/Revoked (MR-01).
    error UseMerchantScopedRole();
}
