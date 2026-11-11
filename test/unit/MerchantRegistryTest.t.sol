// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {MerchantRegistry} from "../../src/MerchantRegistry.sol";
import {MerchantAccessControl} from "../../src/MerchantAccessControl.sol";
import {MerchantRoles} from "../../src/MerchantRoles.sol";
import {IMerchantRegistry} from "../../src/interfaces/IMerchantRegistry.sol";

contract MerchantRegistryTest is MockFixture {
    MerchantRegistry internal merchantReg;

    address internal merchantOwner = makeAddr("merchantOwner");
    address internal delegate = makeAddr("delegate");
    uint256 internal merchantId;

    function setUp() public override {
        super.setUp();
        // Deploy real MerchantRegistry against mock PAR
        merchantReg = new MerchantRegistry(address(par), admin);
        // Mint a merchantId in the mock AgentRegistry
        merchantId = agentRegistry.mint(merchantOwner);
    }

    // =========================================================================
    // setActive
    // =========================================================================

    function test_SetActive_OwnerCanActivate() public {
        vm.prank(merchantOwner);
        merchantReg.setActive(merchantId, true);
        assertTrue(merchantReg.isActive(merchantId));
    }

    function test_SetActive_OwnerCanDeactivate() public {
        vm.startPrank(merchantOwner);
        merchantReg.setActive(merchantId, true);
        merchantReg.setActive(merchantId, false);
        vm.stopPrank();
        assertFalse(merchantReg.isActive(merchantId));
    }

    function test_SetActive_EmitsMerchantActiveSet() public {
        vm.expectEmit(true, false, false, true);
        emit IMerchantRegistry.MerchantActiveSet(merchantId, true);
        vm.prank(merchantOwner);
        merchantReg.setActive(merchantId, true);
    }

    function test_SetActive_Revert_NotMerchantAdmin() public {
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.NotMerchantOwner.selector, merchantId, delegate));
        merchantReg.setActive(merchantId, true);
    }

    function test_SetActive_Revert_WhenSuspended() public {
        vm.prank(admin);
        merchantReg.suspend(merchantId, "violation");

        vm.prank(merchantOwner);
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.MerchantIsSuspended.selector, merchantId));
        merchantReg.setActive(merchantId, true);
    }

    function test_SetActive_Deactivate_WhileSuspended_Succeeds() public {
        // Owner may set active=false even while suspended — only active=true is blocked.
        vm.prank(merchantOwner);
        merchantReg.setActive(merchantId, true);
        vm.prank(admin);
        merchantReg.suspend(merchantId, "violation");

        vm.prank(merchantOwner);
        merchantReg.setActive(merchantId, false); // must not revert
        assertFalse(merchantReg.isActive(merchantId));
    }

    function test_SetActive_Revert_MerchantNotFound() public {
        uint256 unknownId = 9999;
        vm.prank(merchantOwner);
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.MerchantNotFound.selector, unknownId));
        merchantReg.setActive(unknownId, true);
    }

    // =========================================================================
    // grantRole / revokeRole
    // =========================================================================

    function test_GrantRole_OwnerGrantsProductManager() public {
        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
        assertTrue(merchantReg.hasRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate));
    }

    function test_GrantRole_OwnerGrantsCommissionManager() public {
        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, delegate);
        assertTrue(merchantReg.hasRole(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, delegate));
    }

    // SETTLEMENT_SIGNER_ROLE: a hot key the merchant's server uses to sign facilitator
    // /verify + /settle requests. No on-chain consumer — the facilitator checks hasRole off-chain —
    // so what the contract owes is: grantable, revocable, scoped per merchant, and rejected for
    // anyone who never held it.
    function test_GrantRole_OwnerGrantsSettlementSigner() public {
        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate);
        assertTrue(merchantReg.hasRole(merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate));
    }

    function test_HasRole_SettlementSigner_FalseWhenNeverGranted() public view {
        // Must answer false, not revert InvalidRole: the facilitator asks this for every signer.
        assertFalse(merchantReg.hasRole(merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate));
    }

    function test_GrantRole_SettlementSigner_ScopedPerMerchant() public {
        address otherOwner = makeAddr("otherOwner");
        uint256 otherId = agentRegistry.mint(otherOwner);
        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate);
        assertFalse(merchantReg.hasRole(otherId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate));
    }

    function test_GrantRole_SettlementSigner_DoesNotGrantOtherRoles() public {
        // The whole point of the role: a settlement key must not be able to touch products or rates.
        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate);
        assertFalse(merchantReg.hasRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate));
        assertFalse(merchantReg.hasRole(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, delegate));
    }

    function test_RevokeRole_SettlementSigner() public {
        vm.startPrank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate);
        vm.expectEmit(true, true, true, true);
        emit IMerchantRegistry.MerchantRoleRevoked(
            merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate, merchantOwner
        );
        merchantReg.revokeRole(merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate);
        vm.stopPrank();
        assertFalse(merchantReg.hasRole(merchantId, MerchantRoles.SETTLEMENT_SIGNER_ROLE, delegate));
    }

    function test_SettlementSignerRole_HashPinned() public pure {
        // The backend mirrors this hash in Go; a renamed string here must break that test too.
        assertEq(MerchantRoles.SETTLEMENT_SIGNER_ROLE, keccak256("SETTLEMENT_SIGNER_ROLE"));
    }

    function test_GrantRole_EmitsMerchantRoleGranted() public {
        vm.expectEmit(true, true, true, true);
        emit IMerchantRegistry.MerchantRoleGranted(
            merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate, merchantOwner
        );
        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
    }

    function test_GrantRole_Revert_NotMerchantAdmin() public {
        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.NotMerchantOwner.selector, merchantId, delegate));
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, makeAddr("other"));
    }

    function test_GrantRole_Revert_InvalidRole() public {
        bytes32 badRole = keccak256("NONEXISTENT_ROLE");
        vm.prank(merchantOwner);
        vm.expectRevert(abi.encodeWithSelector(MerchantAccessControl.InvalidRole.selector, badRole));
        merchantReg.grantRole(merchantId, badRole, delegate);
    }

    function test_GrantRole_ScopedPerMerchant() public {
        // Role granted for merchantId must not bleed into a different merchantId.
        address otherOwner = makeAddr("otherOwner");
        uint256 otherId = agentRegistry.mint(otherOwner);

        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);

        assertFalse(merchantReg.hasRole(otherId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate));
    }

    function test_RevokeRole_OwnerRevokesRole() public {
        vm.startPrank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
        merchantReg.revokeRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
        vm.stopPrank();
        assertFalse(merchantReg.hasRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate));
    }

    function test_RevokeRole_EmitsMerchantRoleRevoked() public {
        vm.startPrank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);

        vm.expectEmit(true, true, true, true);
        emit IMerchantRegistry.MerchantRoleRevoked(
            merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate, merchantOwner
        );
        merchantReg.revokeRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
        vm.stopPrank();
    }

    function test_RevokeRole_Revert_NotMerchantAdmin() public {
        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);

        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.NotMerchantOwner.selector, merchantId, delegate));
        merchantReg.revokeRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
    }

    function test_RevokeRole_Revert_InvalidRole() public {
        bytes32 badRole = keccak256("NONEXISTENT_ROLE");
        vm.prank(merchantOwner);
        vm.expectRevert(abi.encodeWithSelector(MerchantAccessControl.InvalidRole.selector, badRole));
        merchantReg.revokeRole(merchantId, badRole, delegate);
    }

    // =========================================================================
    // MR-01 — inherited flat grantRole/revokeRole(bytes32,address) lockdown
    // =========================================================================

    function test_GrantRole2Arg_Revert_MerchantScopedBypass() public {
        // The attack: DEFAULT_ADMIN grants a namespaced per-merchant role directly via the
        // inherited 2-arg grantRole, bypassing owner-gating + _roleExists + MerchantRoleGranted.
        address attacker = makeAddr("attacker");
        bytes32 nsRole = keccak256(abi.encodePacked(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE));
        vm.prank(admin);
        vm.expectRevert(IMerchantRegistry.UseMerchantScopedRole.selector);
        merchantReg.grantRole(nsRole, attacker);
    }

    function test_GrantRole2Arg_Revert_RawMerchantRoleConstant() public {
        // Even the raw role constant (not namespaced) must be rejected on the flat path.
        address attacker = makeAddr("attacker");
        vm.prank(admin);
        vm.expectRevert(IMerchantRegistry.UseMerchantScopedRole.selector);
        merchantReg.grantRole(MerchantRoles.PRODUCT_MANAGER_ROLE, attacker);
    }

    function test_RevokeRole2Arg_Revert_MerchantScopedBypass() public {
        address account = makeAddr("account");
        bytes32 nsRole = keccak256(abi.encodePacked(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE));
        vm.prank(admin);
        vm.expectRevert(IMerchantRegistry.UseMerchantScopedRole.selector);
        merchantReg.revokeRole(nsRole, account);
    }

    function test_GrantRole2Arg_AllowsDefaultAdminRotation() public {
        // DEFAULT_ADMIN_ROLE must still be grantable via the flat path so admin key rotation works.
        address newAdmin = makeAddr("newAdmin");
        bytes32 adminRole = merchantReg.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        merchantReg.grantRole(adminRole, newAdmin);

        // The rotated-in admin can exercise a DEFAULT_ADMIN-only function.
        vm.prank(newAdmin);
        merchantReg.suspend(merchantId, "rotated admin works");
        assertTrue(merchantReg.isSuspended(merchantId));
    }

    function test_RevokeRole2Arg_AllowsDefaultAdminRotation() public {
        // Completing a key rotation: the new admin revokes DEFAULT_ADMIN_ROLE from the old key via
        // the flat path. The old key must lose every DEFAULT_ADMIN-only capability.
        address newAdmin = makeAddr("newAdmin");
        bytes32 adminRole = merchantReg.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        merchantReg.grantRole(adminRole, newAdmin);

        vm.prank(newAdmin);
        merchantReg.revokeRole(adminRole, admin);

        assertFalse(merchantReg.hasRole(adminRole, admin), "old admin still holds DEFAULT_ADMIN_ROLE");
        assertTrue(merchantReg.hasRole(adminRole, newAdmin), "new admin lost DEFAULT_ADMIN_ROLE");

        vm.prank(admin);
        vm.expectRevert();
        merchantReg.suspend(merchantId, "old key must be locked out");
    }

    // =========================================================================
    // hasRole
    // =========================================================================

    function test_HasRole_FalseBeforeGrant() public view {
        assertFalse(merchantReg.hasRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate));
    }

    function test_HasRole_TrueAfterGrant() public {
        vm.prank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
        assertTrue(merchantReg.hasRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate));
    }

    function test_HasRole_FalseAfterRevoke() public {
        vm.startPrank(merchantOwner);
        merchantReg.grantRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
        merchantReg.revokeRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
        vm.stopPrank();
        assertFalse(merchantReg.hasRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate));
    }

    function test_HasRole_OwnerAlwaysHasRole_ProductManager() public view {
        // Owner returns true without explicit grant.
        assertTrue(merchantReg.hasRole(merchantId, MerchantRoles.PRODUCT_MANAGER_ROLE, merchantOwner));
    }

    function test_HasRole_OwnerAlwaysHasRole_CommissionManager() public view {
        assertTrue(merchantReg.hasRole(merchantId, MerchantRoles.COMMISSION_MANAGER_ROLE, merchantOwner));
    }

    function test_HasRole_Revert_InvalidRole_ForNonOwner() public {
        // Non-owner + invalid role hits _hasRole → _roleExists → revert.
        bytes32 badRole = keccak256("NONEXISTENT_ROLE");
        vm.expectRevert(abi.encodeWithSelector(MerchantAccessControl.InvalidRole.selector, badRole));
        merchantReg.hasRole(merchantId, badRole, delegate);
    }

    function test_HasRole_Owner_InvalidRole_ReturnsTrue() public view {
        // Owner short-circuits before role validity check — always true.
        bytes32 badRole = keccak256("NONEXISTENT_ROLE");
        assertTrue(merchantReg.hasRole(merchantId, badRole, merchantOwner));
    }

    function test_HasRole_Revert_MerchantNotFound() public {
        uint256 unknownId = 9999;
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.MerchantNotFound.selector, unknownId));
        merchantReg.hasRole(unknownId, MerchantRoles.PRODUCT_MANAGER_ROLE, delegate);
    }

    // =========================================================================
    // suspend / unsuspend
    // =========================================================================

    function test_Suspend_AdminCanSuspend() public {
        vm.prank(admin);
        merchantReg.suspend(merchantId, "tos violation");
        assertTrue(merchantReg.isSuspended(merchantId));
    }

    function test_Suspend_EmitsMerchantSuspended() public {
        vm.expectEmit(true, false, false, true);
        emit IMerchantRegistry.MerchantSuspended(merchantId, "tos violation");
        vm.prank(admin);
        merchantReg.suspend(merchantId, "tos violation");
    }

    function test_Suspend_Revert_NotAdmin() public {
        vm.prank(merchantOwner);
        vm.expectRevert();
        merchantReg.suspend(merchantId, "tos violation");
    }

    function test_Suspend_Revert_MerchantNotFound() public {
        uint256 unknownId = 9999;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.MerchantNotFound.selector, unknownId));
        merchantReg.suspend(unknownId, "tos violation");
    }

    function test_Suspend_Idempotent() public {
        vm.startPrank(admin);
        merchantReg.suspend(merchantId, "first");
        merchantReg.suspend(merchantId, "second"); // must not revert
        vm.stopPrank();
        assertTrue(merchantReg.isSuspended(merchantId));
    }

    function test_Unsuspend_AdminCanUnsuspend() public {
        vm.startPrank(admin);
        merchantReg.suspend(merchantId, "tos violation");
        merchantReg.unsuspend(merchantId);
        vm.stopPrank();
        assertFalse(merchantReg.isSuspended(merchantId));
    }

    function test_Unsuspend_EmitsMerchantUnsuspended() public {
        vm.startPrank(admin);
        merchantReg.suspend(merchantId, "tos violation");

        vm.expectEmit(true, false, false, false);
        emit IMerchantRegistry.MerchantUnsuspended(merchantId);
        merchantReg.unsuspend(merchantId);
        vm.stopPrank();
    }

    function test_Unsuspend_Revert_NotAdmin() public {
        vm.prank(admin);
        merchantReg.suspend(merchantId, "tos violation");

        vm.prank(merchantOwner);
        vm.expectRevert();
        merchantReg.unsuspend(merchantId);
    }

    function test_Suspend_MerchantCannotUnsuspendSelf() public {
        vm.prank(admin);
        merchantReg.suspend(merchantId, "tos violation");

        vm.prank(merchantOwner);
        vm.expectRevert();
        merchantReg.unsuspend(merchantId);
    }

    function test_Unsuspend_Revert_MerchantNotFound() public {
        uint256 unknownId = 9999;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.MerchantNotFound.selector, unknownId));
        merchantReg.unsuspend(unknownId);
    }

    function test_Unsuspend_WhenNotSuspended_Idempotent() public {
        vm.prank(admin);
        merchantReg.unsuspend(merchantId); // must not revert
        assertFalse(merchantReg.isSuspended(merchantId));
    }

    // =========================================================================
    // isActive / isSuspended
    // =========================================================================

    function test_IsActive_FalseByDefault() public view {
        assertFalse(merchantReg.isActive(merchantId));
    }

    function test_IsActive_TrueWhenSet() public {
        vm.prank(merchantOwner);
        merchantReg.setActive(merchantId, true);
        assertTrue(merchantReg.isActive(merchantId));
    }

    function test_IsActive_FalseAfterDeactivate() public {
        vm.startPrank(merchantOwner);
        merchantReg.setActive(merchantId, true);
        merchantReg.setActive(merchantId, false);
        vm.stopPrank();
        assertFalse(merchantReg.isActive(merchantId));
    }

    function test_IsActive_FalseWhenSuspended() public {
        vm.prank(merchantOwner);
        merchantReg.setActive(merchantId, true);
        vm.prank(admin);
        merchantReg.suspend(merchantId, "violation");
        // _active=true but suspended=true → isActive=false
        assertFalse(merchantReg.isActive(merchantId));
    }

    function test_IsActive_TrueAfterUnsuspend_WhenPreviouslyActive() public {
        vm.prank(merchantOwner);
        merchantReg.setActive(merchantId, true);
        vm.startPrank(admin);
        merchantReg.suspend(merchantId, "violation");
        merchantReg.unsuspend(merchantId);
        vm.stopPrank();
        assertTrue(merchantReg.isActive(merchantId));
    }

    function test_IsActive_FalseAfterUnsuspend_WhenNotActive() public {
        // Suspended then unsuspended but never activated → still false.
        vm.startPrank(admin);
        merchantReg.suspend(merchantId, "violation");
        merchantReg.unsuspend(merchantId);
        vm.stopPrank();
        assertFalse(merchantReg.isActive(merchantId));
    }

    function test_IsActive_Revert_MerchantNotFound() public {
        uint256 unknownId = 9999;
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.MerchantNotFound.selector, unknownId));
        merchantReg.isActive(unknownId);
    }

    function test_IsSuspended_FalseByDefault() public view {
        assertFalse(merchantReg.isSuspended(merchantId));
    }

    function test_IsSuspended_TrueAfterSuspend() public {
        vm.prank(admin);
        merchantReg.suspend(merchantId, "violation");
        assertTrue(merchantReg.isSuspended(merchantId));
    }

    function test_IsSuspended_FalseAfterUnsuspend() public {
        vm.startPrank(admin);
        merchantReg.suspend(merchantId, "violation");
        merchantReg.unsuspend(merchantId);
        vm.stopPrank();
        assertFalse(merchantReg.isSuspended(merchantId));
    }

    function test_IsSuspended_Revert_MerchantNotFound() public {
        uint256 unknownId = 9999;
        vm.expectRevert(abi.encodeWithSelector(IMerchantRegistry.MerchantNotFound.selector, unknownId));
        merchantReg.isSuspended(unknownId);
    }
}
