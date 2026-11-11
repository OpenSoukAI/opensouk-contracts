// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAddressRegistry} from "../../src/ProtocolAddressRegistry.sol";
import {IProtocolAddressRegistry} from "../../src/interfaces/IProtocolAddressRegistry.sol";

contract ProtocolAddressRegistryTest is Test {
    ProtocolAddressRegistry internal par;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal addr1 = makeAddr("addr1");
    address internal addr2 = makeAddr("addr2");

    // KEY_A is a generic re-pointable key; AGENT_REGISTRY has its own tests (ImmutableKey).
    bytes32 internal constant KEY_A = keccak256("MERCHANT_REGISTRY");
    bytes32 internal constant AGENT_KEY = keccak256("AGENT_REGISTRY");
    bytes32 internal constant KEY_B = keccak256("ESCROW");
    uint256 internal constant DELAY = 2 days;

    function _deployWithDelay(uint256 delay) internal returns (ProtocolAddressRegistry) {
        bytes32[] memory keys = new bytes32[](2);
        address[] memory vals = new address[](2);
        keys[0] = KEY_A;
        keys[1] = KEY_B;
        vals[0] = addr1;
        vals[1] = addr2;
        return new ProtocolAddressRegistry(owner, guardian, delay, keys, vals);
    }

    function setUp() public {
        par = _deployWithDelay(DELAY);
    }

    // =========================================================================
    // constructor
    // =========================================================================

    function test_Constructor_SetsInitialAddresses() public view {
        assertEq(par.getAddress(KEY_A), addr1);
        assertEq(par.getAddress(KEY_B), addr2);
    }

    function test_Constructor_EmitsAddressUpdated() public {
        bytes32[] memory keys = new bytes32[](1);
        address[] memory vals = new address[](1);
        keys[0] = KEY_A;
        vals[0] = addr1;

        vm.expectEmit(true, true, true, true);
        emit IProtocolAddressRegistry.AddressUpdated(KEY_A, address(0), addr1);
        new ProtocolAddressRegistry(owner, guardian, DELAY, keys, vals);
    }

    function test_Constructor_EmitsTimelockDelayUpdated() public {
        bytes32[] memory keys = new bytes32[](0);
        address[] memory vals = new address[](0);

        vm.expectEmit(false, false, false, true);
        emit IProtocolAddressRegistry.TimelockDelayUpdated(0, DELAY);
        new ProtocolAddressRegistry(owner, guardian, DELAY, keys, vals);
    }

    function test_Constructor_Revert_LengthMismatch() public {
        bytes32[] memory keys = new bytes32[](2);
        address[] memory vals = new address[](1);
        keys[0] = KEY_A;
        keys[1] = KEY_B;
        vals[0] = addr1;

        vm.expectRevert(IProtocolAddressRegistry.LengthMismatch.selector);
        new ProtocolAddressRegistry(owner, guardian, DELAY, keys, vals);
    }

    function test_Constructor_Revert_ZeroAddress() public {
        bytes32[] memory keys = new bytes32[](1);
        address[] memory vals = new address[](1);
        keys[0] = KEY_A;
        vals[0] = address(0);

        vm.expectRevert(IProtocolAddressRegistry.ZeroAddress.selector);
        new ProtocolAddressRegistry(owner, guardian, DELAY, keys, vals);
    }

    function test_Constructor_ZeroDelay_Allowed() public {
        ProtocolAddressRegistry p = _deployWithDelay(0);
        assertEq(p.timelockDelay(), 0);
    }

    function test_Constructor_EmptyArrays_Allowed() public {
        bytes32[] memory keys = new bytes32[](0);
        address[] memory vals = new address[](0);
        ProtocolAddressRegistry p = new ProtocolAddressRegistry(owner, guardian, DELAY, keys, vals);
        assertEq(p.timelockDelay(), DELAY);
    }

    // =========================================================================
    // key constants
    // =========================================================================

    function test_KeyConstants_MatchExpectedKeccak() public view {
        assertEq(par.AGENT_REGISTRY(), keccak256("AGENT_REGISTRY"));
        assertEq(par.MERCHANT_REGISTRY(), keccak256("MERCHANT_REGISTRY"));
        assertEq(par.PRODUCT_REGISTRY(), keccak256("PRODUCT_REGISTRY"));
        assertEq(par.REVIEW_REGISTRY(), keccak256("REVIEW_REGISTRY"));
        assertEq(par.ESCROW(), keccak256("ESCROW"));
        assertEq(par.SPLIT_ROUTER(), keccak256("SPLIT_ROUTER"));
        assertEq(par.KEEPER(), keccak256("KEEPER"));
        assertEq(par.TREASURY(), keccak256("TREASURY"));
    }

    // =========================================================================
    // setAddress
    // =========================================================================

    function test_SetAddress_QueuesPendingUpdate() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        (address pending, uint256 effectiveAt) = par.getPending(KEY_A);
        assertEq(pending, newAddr);
        assertEq(effectiveAt, block.timestamp + DELAY);
    }

    function test_SetAddress_EmitsAddressQueued() public {
        address newAddr = makeAddr("newAddr");
        uint256 expectedAt = block.timestamp + DELAY;

        vm.expectEmit(true, true, false, true);
        emit IProtocolAddressRegistry.AddressQueued(KEY_A, newAddr, expectedAt);

        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);
    }

    function test_SetAddress_Revert_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        par.setAddress(KEY_A, addr1);
    }

    function test_SetAddress_Revert_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IProtocolAddressRegistry.ZeroAddress.selector);
        par.setAddress(KEY_A, address(0));
    }

    function test_SetAddress_Revert_UpdateAlreadyPending() public {
        address newAddr = makeAddr("newAddr");
        vm.startPrank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.UpdateAlreadyPending.selector, KEY_A));
        par.setAddress(KEY_A, addr2);
        vm.stopPrank();
    }

    function test_SetAddress_Revert_ImmutableKey_AgentRegistrySeeded() public {
        bytes32[] memory keys = new bytes32[](1);
        address[] memory vals = new address[](1);
        keys[0] = AGENT_KEY;
        vals[0] = addr1;
        ProtocolAddressRegistry p = new ProtocolAddressRegistry(owner, guardian, DELAY, keys, vals);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.ImmutableKey.selector, AGENT_KEY));
        p.setAddress(AGENT_KEY, addr2);
    }

    function test_SetAddress_AgentRegistry_FirstSetAllowedThenImmutable() public {
        bytes32[] memory keys = new bytes32[](0);
        address[] memory vals = new address[](0);
        ProtocolAddressRegistry p = new ProtocolAddressRegistry(owner, guardian, DELAY, keys, vals);

        vm.prank(owner);
        p.setAddress(AGENT_KEY, addr1);
        vm.warp(block.timestamp + DELAY);
        p.executeUpdate(AGENT_KEY);
        assertEq(p.getAddress(AGENT_KEY), addr1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.ImmutableKey.selector, AGENT_KEY));
        p.setAddress(AGENT_KEY, addr2);
    }

    function test_SetAddress_TwoDistinctKeys_Simultaneous() public {
        address newAddr1 = makeAddr("new1");
        address newAddr2 = makeAddr("new2");

        vm.startPrank(owner);
        par.setAddress(KEY_A, newAddr1);
        par.setAddress(KEY_B, newAddr2); // different key — must not revert
        vm.stopPrank();

        (address pa,) = par.getPending(KEY_A);
        (address pb,) = par.getPending(KEY_B);
        assertEq(pa, newAddr1);
        assertEq(pb, newAddr2);
    }

    // =========================================================================
    // executeUpdate
    // =========================================================================

    function test_ExecuteUpdate_AppliesAfterDelay() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.warp(block.timestamp + DELAY);
        par.executeUpdate(KEY_A);

        assertEq(par.getAddress(KEY_A), newAddr);
    }

    function test_ExecuteUpdate_EmitsAddressUpdated() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.warp(block.timestamp + DELAY);

        vm.expectEmit(true, true, true, true);
        emit IProtocolAddressRegistry.AddressUpdated(KEY_A, addr1, newAddr);
        par.executeUpdate(KEY_A);
    }

    function test_ExecuteUpdate_ClearsPending() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.warp(block.timestamp + DELAY);
        par.executeUpdate(KEY_A);

        (address pending, uint256 effectiveAt) = par.getPending(KEY_A);
        assertEq(pending, address(0));
        assertEq(effectiveAt, 0);
    }

    function test_ExecuteUpdate_PermissionlessAfterDelay() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.warp(block.timestamp + DELAY);
        vm.prank(alice); // non-owner calls
        par.executeUpdate(KEY_A); // must succeed

        assertEq(par.getAddress(KEY_A), newAddr);
    }

    function test_ExecuteUpdate_Revert_NoPendingUpdate() public {
        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.NoPendingUpdate.selector, KEY_A));
        par.executeUpdate(KEY_A);
    }

    function test_ExecuteUpdate_Revert_TimelockNotExpired() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IProtocolAddressRegistry.TimelockNotExpired.selector, block.timestamp + 1, block.timestamp
            )
        );
        par.executeUpdate(KEY_A);
    }

    function test_ExecuteUpdate_AtExactDelay_Succeeds() public {
        address newAddr = makeAddr("newAddr");
        uint256 queuedAt = block.timestamp;
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.warp(queuedAt + DELAY);
        par.executeUpdate(KEY_A); // must not revert
        assertEq(par.getAddress(KEY_A), newAddr);
    }

    // =========================================================================
    // cancelUpdate
    // =========================================================================

    function test_CancelUpdate_RemovesPending() public {
        address newAddr = makeAddr("newAddr");
        vm.startPrank(owner);
        par.setAddress(KEY_A, newAddr);
        par.cancelUpdate(KEY_A);
        vm.stopPrank();

        (address pending, uint256 effectiveAt) = par.getPending(KEY_A);
        assertEq(pending, address(0));
        assertEq(effectiveAt, 0);
    }

    function test_CancelUpdate_EmitsAddressUpdateCancelled() public {
        address newAddr = makeAddr("newAddr");
        vm.startPrank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.expectEmit(true, false, false, false);
        emit IProtocolAddressRegistry.AddressUpdateCancelled(KEY_A);
        par.cancelUpdate(KEY_A);
        vm.stopPrank();
    }

    function test_CancelUpdate_Revert_NotOwner() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        vm.prank(alice);
        vm.expectRevert();
        par.cancelUpdate(KEY_A);
    }

    function test_CancelUpdate_Revert_NoPendingUpdate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.NoPendingUpdate.selector, KEY_A));
        par.cancelUpdate(KEY_A);
    }

    function test_CancelUpdate_ThenSetAddressAgain_Succeeds() public {
        address newAddr1 = makeAddr("new1");
        address newAddr2 = makeAddr("new2");

        vm.startPrank(owner);
        par.setAddress(KEY_A, newAddr1);
        par.cancelUpdate(KEY_A);
        par.setAddress(KEY_A, newAddr2); // must not revert UpdateAlreadyPending
        vm.stopPrank();

        (address pending,) = par.getPending(KEY_A);
        assertEq(pending, newAddr2);
    }

    // =========================================================================
    // getAddress
    // =========================================================================

    // =========================================================================
    // setTimelockDelay / executeTimelockDelayUpdate
    // =========================================================================

    // The delay change must itself wait out the CURRENT delay. Otherwise a compromised owner sets
    // it to zero and repoints in the same bundle, and the timelock is advisory.
    function test_SetTimelockDelay_QueuesBehindCurrentDelay() public {
        vm.prank(owner);
        par.setTimelockDelay(6 hours);

        assertEq(par.timelockDelay(), DELAY, "delay must not change before the pending update matures");

        vm.warp(block.timestamp + DELAY);
        par.executeTimelockDelayUpdate();
        assertEq(par.timelockDelay(), 6 hours);
    }

    // With nothing queued, the pending value is zero. An unguarded execute would write that zero
    // into the live delay and disable the timelock — permissionlessly, at any time.
    function test_ExecuteTimelockDelayUpdate_Revert_NoPendingUpdate() public {
        vm.expectRevert();
        par.executeTimelockDelayUpdate();

        assertEq(par.timelockDelay(), DELAY, "an unqueued execute must not touch the delay");
    }

    function test_ExecuteTimelockDelayUpdate_Revert_TimelockNotExpired() public {
        vm.prank(owner);
        par.setTimelockDelay(6 hours);

        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert();
        par.executeTimelockDelayUpdate();
    }

    // Executing twice would re-apply a stale value; the second call has nothing pending.
    function test_ExecuteTimelockDelayUpdate_ClearsPending() public {
        vm.prank(owner);
        par.setTimelockDelay(6 hours);
        vm.warp(block.timestamp + DELAY);
        par.executeTimelockDelayUpdate();

        vm.expectRevert();
        par.executeTimelockDelayUpdate();
        assertEq(par.timelockDelay(), 6 hours);
    }

    function test_SetTimelockDelay_Revert_AboveCeiling() public {
        vm.prank(owner);
        vm.expectRevert(IProtocolAddressRegistry.InvalidTimelockDelay.selector);
        par.setTimelockDelay(8 days);
    }

    function test_SetTimelockDelay_Revert_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        par.setTimelockDelay(6 hours);
    }

    // A queued change is announced by an event that a monitor watches. Silently replacing it would
    // make the alarm report a value that never applies.
    function test_SetTimelockDelay_Revert_UpdateAlreadyPending() public {
        vm.startPrank(owner);
        par.setTimelockDelay(6 hours);
        vm.expectRevert();
        par.setTimelockDelay(1 hours);
        vm.stopPrank();
    }

    // Cancelling an empty queue must be a loud no-op, not a silent one, so an operator who
    // believes a change was queued learns it was not.
    function test_CancelTimelockDelayUpdate_Revert_NoPending() public {
        vm.prank(owner);
        vm.expectRevert(IProtocolAddressRegistry.NoPendingTimelockDelayUpdate.selector);
        par.cancelTimelockDelayUpdate();

        assertEq(par.timelockDelay(), DELAY, "cancel on an empty queue must not touch the delay");
    }

    function test_CancelTimelockDelayUpdate_RemovesPending() public {
        vm.startPrank(owner);
        par.setTimelockDelay(6 hours);
        par.cancelTimelockDelayUpdate();
        vm.stopPrank();

        vm.warp(block.timestamp + DELAY);
        vm.expectRevert();
        par.executeTimelockDelayUpdate();
        assertEq(par.timelockDelay(), DELAY);
    }

    // The genesis path: deploy at zero so wiring applies immediately, then raise the delay, which
    // also applies immediately because the current delay is still zero.
    function test_ZeroDelay_RaiseAppliesImmediately() public {
        ProtocolAddressRegistry fresh = _deployWithDelay(0);

        vm.startPrank(owner);
        fresh.setTimelockDelay(6 hours);
        fresh.executeTimelockDelayUpdate();
        vm.stopPrank();

        assertEq(fresh.timelockDelay(), 6 hours);

        // And from here the six hours binds: a further change cannot apply at once.
        vm.prank(owner);
        fresh.setTimelockDelay(0);
        vm.expectRevert();
        fresh.executeTimelockDelayUpdate();
        assertEq(fresh.timelockDelay(), 6 hours);
    }

    function test_GetAddress_ReturnsActiveAddress() public view {
        assertEq(par.getAddress(KEY_A), addr1);
    }

    function test_GetAddress_ReturnsPreviousAddressDuringPending() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        // Before executeUpdate, old address still active
        assertEq(par.getAddress(KEY_A), addr1);
    }

    function test_GetAddress_Revert_AddressNotSet() public {
        bytes32 unknownKey = keccak256("UNKNOWN");
        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.AddressNotSet.selector, unknownKey));
        par.getAddress(unknownKey);
    }

    // =========================================================================
    // getPending
    // =========================================================================

    function test_GetPending_ReturnsZeroWhenNone() public view {
        (address pending, uint256 effectiveAt) = par.getPending(KEY_A);
        assertEq(pending, address(0));
        assertEq(effectiveAt, 0);
    }

    function test_GetPending_ReturnsValueAndEffectiveAt() public {
        address newAddr = makeAddr("newAddr");
        uint256 queuedAt = block.timestamp;
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);

        (address pending, uint256 effectiveAt) = par.getPending(KEY_A);
        assertEq(pending, newAddr);
        assertEq(effectiveAt, queuedAt + DELAY);
    }

    function test_GetPending_ZeroAfterExecute() public {
        address newAddr = makeAddr("newAddr");
        vm.prank(owner);
        par.setAddress(KEY_A, newAddr);
        vm.warp(block.timestamp + DELAY);
        par.executeUpdate(KEY_A);

        (address pending, uint256 effectiveAt) = par.getPending(KEY_A);
        assertEq(pending, address(0));
        assertEq(effectiveAt, 0);
    }

    function test_GetPending_ZeroAfterCancel() public {
        address newAddr = makeAddr("newAddr");
        vm.startPrank(owner);
        par.setAddress(KEY_A, newAddr);
        par.cancelUpdate(KEY_A);
        vm.stopPrank();

        (address pending, uint256 effectiveAt) = par.getPending(KEY_A);
        assertEq(pending, address(0));
        assertEq(effectiveAt, 0);
    }

    // =========================================================================
    // timelockDelay
    // =========================================================================

    function test_TimelockDelay_ReturnsConstructorValue() public view {
        assertEq(par.timelockDelay(), DELAY);
    }

    // =========================================================================
    // Guardian, two-step ownership, renounce (audit follow-up)
    // =========================================================================

    function test_Guardian_ReturnsConstructorValue() public view {
        assertEq(par.guardian(), guardian);
    }

    function test_Constructor_Revert_ZeroGuardian() public {
        bytes32[] memory keys = new bytes32[](0);
        address[] memory vals = new address[](0);
        vm.expectRevert(IProtocolAddressRegistry.ZeroAddress.selector);
        new ProtocolAddressRegistry(owner, address(0), DELAY, keys, vals);
    }

    function test_CancelUpdate_GuardianCanCancel() public {
        vm.prank(owner);
        par.setAddress(KEY_A, addr2);

        vm.prank(guardian);
        par.cancelUpdate(KEY_A);

        (, uint256 effectiveAt) = par.getPending(KEY_A);
        assertEq(effectiveAt, 0);
    }

    function test_CancelTimelockDelayUpdate_GuardianCanCancel() public {
        vm.prank(owner);
        par.setTimelockDelay(1 days);

        vm.prank(guardian);
        par.cancelTimelockDelayUpdate();

        vm.expectRevert(IProtocolAddressRegistry.NoPendingTimelockDelayUpdate.selector);
        par.executeTimelockDelayUpdate();
    }

    function test_CancelUpdate_Revert_NeitherOwnerNorGuardian() public {
        vm.prank(owner);
        par.setAddress(KEY_A, addr2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.NotOwnerOrGuardian.selector, alice));
        par.cancelUpdate(KEY_A);
    }

    function test_CancelTimelockDelayUpdate_Revert_NeitherOwnerNorGuardian() public {
        vm.prank(owner);
        par.setTimelockDelay(1 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.NotOwnerOrGuardian.selector, alice));
        par.cancelTimelockDelayUpdate();
    }

    /// @dev The guardian is a brake only: it can cancel, never queue.
    function test_Guardian_CannotQueue() public {
        vm.startPrank(guardian);
        vm.expectRevert();
        par.setAddress(KEY_A, addr2);
        vm.expectRevert();
        par.setTimelockDelay(1 days);
        vm.stopPrank();
    }

    function test_RenounceOwnership_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(IProtocolAddressRegistry.RenounceDisabled.selector);
        par.renounceOwnership();
        assertEq(par.owner(), owner, "owner unchanged");
    }

    function test_TransferOwnership_IsTwoStep() public {
        vm.prank(owner);
        par.transferOwnership(alice);
        assertEq(par.owner(), owner, "not transferred until accepted");
        assertEq(par.pendingOwner(), alice);

        vm.prank(alice);
        par.acceptOwnership();
        assertEq(par.owner(), alice);
        assertEq(par.pendingOwner(), address(0));
    }

    function test_AcceptOwnership_Revert_NotPendingOwner() public {
        vm.prank(owner);
        par.transferOwnership(alice);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        par.acceptOwnership();
        assertEq(par.owner(), owner);
    }

    /// @dev The audit scenario. A stolen owner key queues a malicious repoint and then hands
    ///      ownership to itself, so the legitimate team can no longer cancel as owner. The
    ///      guardian is unaffected by who owns the contract, so the queued update never executes.
    function test_Guardian_CancelsAfterAttackerTakesOwnership() public {
        address attacker = makeAddr("attacker");
        address attackerRouter = makeAddr("attackerRouter");

        vm.startPrank(owner); // owner key is compromised
        par.setAddress(KEY_B, attackerRouter);
        par.transferOwnership(attacker);
        vm.stopPrank();
        vm.prank(attacker);
        par.acceptOwnership();
        assertEq(par.owner(), attacker);

        vm.prank(guardian);
        par.cancelUpdate(KEY_B);

        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IProtocolAddressRegistry.NoPendingUpdate.selector, KEY_B));
        par.executeUpdate(KEY_B); // permissionless, but there is nothing left to apply
        assertEq(par.getAddress(KEY_B), addr2, "live address never moved");
    }
}
