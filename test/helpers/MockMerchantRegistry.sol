// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMerchantRegistry} from "../../src/interfaces/IMerchantRegistry.sol";

/// @dev Configurable stub. Call setActive/setSuspended from tests to control return values.
contract MockMerchantRegistry is IMerchantRegistry {
    mapping(uint256 => bool) private _active;
    mapping(uint256 => bool) private _suspended;
    mapping(uint256 => mapping(bytes32 => mapping(address => bool))) private _roles;

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setActiveRaw(uint256 merchantId, bool active) external {
        _active[merchantId] = active;
    }

    function setSuspendedRaw(uint256 merchantId, bool suspended) external {
        _suspended[merchantId] = suspended;
    }

    function setRoleRaw(uint256 merchantId, bytes32 role, address account, bool granted) external {
        _roles[merchantId][role][account] = granted;
    }

    // -------------------------------------------------------------------------
    // IMerchantRegistry
    // -------------------------------------------------------------------------

    function setActive(uint256 merchantId, bool active) external {
        _active[merchantId] = active;
        emit MerchantActiveSet(merchantId, active);
    }

    function suspend(uint256 merchantId, string calldata reason) external {
        _suspended[merchantId] = true;
        emit MerchantSuspended(merchantId, reason);
    }

    function unsuspend(uint256 merchantId) external {
        _suspended[merchantId] = false;
        emit MerchantUnsuspended(merchantId);
    }

    function grantRole(uint256 merchantId, bytes32 role, address account) external {
        _roles[merchantId][role][account] = true;
        emit MerchantRoleGranted(merchantId, role, account, msg.sender);
    }

    function revokeRole(uint256 merchantId, bytes32 role, address account) external {
        _roles[merchantId][role][account] = false;
        emit MerchantRoleRevoked(merchantId, role, account, msg.sender);
    }

    function hasRole(uint256 merchantId, bytes32 role, address account) external view returns (bool) {
        return _roles[merchantId][role][account];
    }

    function isActive(uint256 merchantId) external view returns (bool) {
        return _active[merchantId] && !_suspended[merchantId];
    }

    function isSuspended(uint256 merchantId) external view returns (bool) {
        return _suspended[merchantId];
    }
}
