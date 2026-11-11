// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MerchantRoles} from "./MerchantRoles.sol";

/// @title MerchantAccessControl
/// @notice Per-merchant role namespacing layered over OpenZeppelin `AccessControl`.
/// @dev A merchant is identified by its ERC-8004 identity token id (`merchantId`). Every
///      per-merchant grant is stored under the derived role id
///      `keccak256(abi.encodePacked(merchantId, role))`, so the same logical role
///      (e.g. `PRODUCT_MANAGER_ROLE`) held for merchant A confers nothing for merchant B.
///
///      Only the three roles enumerated in `MerchantRoles` may be namespaced. The whitelist in
///      `_roleExists` is what stops a caller from deriving a namespaced id that collides with a
///      flat OZ role (e.g. `DEFAULT_ADMIN_ROLE`) or from granting a role no contract understands.
///
///      The three-argument helpers below deliberately overload the OZ two-argument
///      `_grantRole`/`_revokeRole` internals: the inheriting `MerchantRegistry` is responsible for
///      gating WHO may call them (merchant owner only) and for emitting the `MerchantRole*` events.
///      This contract only handles the derivation and the whitelist.
contract MerchantAccessControl is AccessControl {
    /// @notice Thrown when `role` is not one of the roles enumerated in `MerchantRoles`.
    error InvalidRole(bytes32);

    /// @dev Grants `role` to `account` scoped to `merchantId`.
    ///      Reverts `InvalidRole` for any role outside the `MerchantRoles` whitelist, so no
    ///      unknown or flat role can be namespaced. Delegates the actual storage write to OZ
    ///      `_grantRole(bytes32,address)` (idempotent: re-granting is a no-op that returns false).
    /// @param merchantId Identity token id of the merchant the grant applies to.
    /// @param role       Logical role constant from `MerchantRoles`.
    /// @param account    Address receiving the merchant-scoped role.
    function _grantRole(uint256 merchantId, bytes32 role, address account) internal {
        if (!_roleExists(role)) {
            revert InvalidRole(role);
        }
        // Namespaced id: same logical role, different merchant => different storage key.
        bytes32 merchantRole = keccak256(abi.encodePacked(merchantId, role));
        _grantRole(merchantRole, account);
    }

    /// @dev Revokes `role` from `account` scoped to `merchantId`. Mirror of `_grantRole`:
    ///      same whitelist check, same derivation, delegates to OZ `_revokeRole(bytes32,address)`.
    /// @param merchantId Identity token id of the merchant the revocation applies to.
    /// @param role       Logical role constant from `MerchantRoles`.
    /// @param account    Address losing the merchant-scoped role.
    function _revokeRole(uint256 merchantId, bytes32 role, address account) internal {
        if (!_roleExists(role)) {
            revert InvalidRole(role);
        }
        bytes32 merchantRole = keccak256(abi.encodePacked(merchantId, role));
        _revokeRole(merchantRole, account);
    }

    /// @dev Merchant-scoped role query. Reverts (rather than returning false) for a role outside
    ///      the whitelist so a typo in a role constant surfaces loudly instead of silently denying.
    ///      Does NOT treat the merchant owner as an implicit holder — that short-circuit lives in
    ///      `MerchantRegistry.hasRole`, which is the public entry point.
    /// @param merchantId Identity token id of the merchant.
    /// @param role       Logical role constant from `MerchantRoles`.
    /// @param account    Address being queried.
    /// @return True if `account` holds the namespaced role.
    function _hasRole(uint256 merchantId, bytes32 role, address account) internal view returns (bool) {
        if (!_roleExists(role)) {
            revert InvalidRole(role);
        }
        bytes32 merchantRole = keccak256(abi.encodePacked(merchantId, role));
        return hasRole(merchantRole, account);
    }

    /// @dev Whitelist of roles that may be namespaced per merchant. Adding a new merchant role
    ///      requires extending BOTH `MerchantRoles` and this predicate; a constant declared in
    ///      `MerchantRoles` but missing here is ungrantable (reverts `InvalidRole`).
    /// @param role Logical role constant to check.
    /// @return True for `PRODUCT_MANAGER_ROLE`, `COMMISSION_MANAGER_ROLE`, `SETTLEMENT_SIGNER_ROLE`.
    function _roleExists(bytes32 role) internal pure returns (bool) {
        return role == MerchantRoles.PRODUCT_MANAGER_ROLE || role == MerchantRoles.COMMISSION_MANAGER_ROLE
            || role == MerchantRoles.SETTLEMENT_SIGNER_ROLE;
    }
}
