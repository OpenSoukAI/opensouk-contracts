// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {CommissionEscrow} from "../../src/CommissionEscrow.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";

contract CommissionEscrowFuzz is MockFixture {
    CommissionEscrow internal escrowReal;

    address internal oracleAddr = makeAddr("oracle");
    address internal reviewRegistryCaller = makeAddr("reviewRegistry");
    address internal splitRouterAddr = makeAddr("splitRouter");
    address internal reviewer = makeAddr("reviewer");
    address internal buyer = makeAddr("buyer");
    address internal merchantOwner = makeAddr("merchantOwner");

    uint256 internal reviewerAgentId;
    uint256 internal buyerAgentId;
    uint256 internal merchantId;
    bytes32 internal constant PRODUCT_ID = keccak256("product-fuzz");

    function setUp() public override {
        super.setUp();
        escrowReal = new CommissionEscrow(address(par), admin, address(usdc));

        vm.startPrank(admin);
        escrowReal.grantRole(keccak256("ORACLE_ROLE"), oracleAddr);
        escrowReal.grantRole(keccak256("ORACLE_ROLE"), reviewRegistryCaller);
        vm.stopPrank();

        vm.prank(admin);
        par.setAddress(keccak256("SPLIT_ROUTER"), splitRouterAddr);
        par.executeUpdate(keccak256("SPLIT_ROUTER"));

        reviewerAgentId = agentRegistry.mint(reviewer);
        buyerAgentId = agentRegistry.mint(buyer);
        merchantId = agentRegistry.mint(merchantOwner);
        merchantRegistry.setActiveRaw(merchantId, true);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _deposit(uint128 heldBackAmt, uint128 cashbackAmt) internal returns (uint256 escrowId) {
        vm.prank(splitRouterAddr);
        escrowId = escrowReal.deposit(
            reviewerAgentId, buyerAgentId, buyer, merchantId, PRODUCT_ID, 0, heldBackAmt, cashbackAmt, 0, 0
        );
    }

    // -------------------------------------------------------------------------
    // Fuzz tests
    // -------------------------------------------------------------------------

    /// @dev settleHeldBack(100): reviewer receives exact heldBackAmt, treasury receives 0.
    function testFuzz_SettleHeldBack_FullToReviewer(uint128 heldBackAmt) public {
        heldBackAmt = uint128(bound(heldBackAmt, 1, type(uint96).max));

        usdc.mint(address(escrowReal), uint256(heldBackAmt));
        uint256 escrowId = _deposit(heldBackAmt, 0);

        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 100);

        assertEq(usdc.balanceOf(reviewer), heldBackAmt);
        assertEq(usdc.balanceOf(address(escrowReal)), 0);
    }

    /// @dev settleHeldBack(0): treasury receives exact heldBackAmt, reviewer receives 0.
    function testFuzz_SettleHeldBack_FullToTreasury(uint128 heldBackAmt) public {
        heldBackAmt = uint128(bound(heldBackAmt, 1, type(uint96).max));

        usdc.mint(address(escrowReal), uint256(heldBackAmt));
        uint256 escrowId = _deposit(heldBackAmt, 0);

        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 0);

        assertEq(usdc.balanceOf(treasury), heldBackAmt);
        assertEq(usdc.balanceOf(address(escrowReal)), 0);
    }

    /// @dev settleHeldBack(pct): reviewer + treasury == heldBackAmt for any pct in [0,100].
    function testFuzz_SettleHeldBack_SumEqualsTotal(uint128 heldBackAmt, uint8 unlockPct) public {
        heldBackAmt = uint128(bound(heldBackAmt, 1, type(uint96).max));
        unlockPct = uint8(bound(unlockPct, 0, 100));

        usdc.mint(address(escrowReal), uint256(heldBackAmt));
        uint256 escrowId = _deposit(heldBackAmt, 0);

        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, unlockPct);

        uint256 reviewerBal = usdc.balanceOf(reviewer);
        uint256 treasuryBal = usdc.balanceOf(treasury);
        assertEq(reviewerBal + treasuryBal, heldBackAmt);
        assertEq(usdc.balanceOf(address(escrowReal)), 0);
    }

    /// @dev releaseCashback: buyer receives exact cashbackAmt.
    function testFuzz_ReleaseCashback_TransfersExact(uint128 cashbackAmt) public {
        cashbackAmt = uint128(bound(cashbackAmt, 1, type(uint96).max));

        usdc.mint(address(escrowReal), uint256(cashbackAmt));
        uint256 escrowId = _deposit(0, cashbackAmt);

        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);

        assertEq(usdc.balanceOf(buyer), cashbackAmt);
        assertEq(usdc.balanceOf(address(escrowReal)), 0);
    }

    /// @dev cashbackToReviewer: reviewer receives exact cashbackAmt after windowEnd.
    function testFuzz_CashbackToReviewer_TransfersExact(uint128 cashbackAmt) public {
        cashbackAmt = uint128(bound(cashbackAmt, 1, type(uint96).max));

        usdc.mint(address(escrowReal), uint256(cashbackAmt));
        uint256 escrowId = _deposit(0, cashbackAmt);

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(r.windowEnd);

        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);

        assertEq(usdc.balanceOf(reviewer), cashbackAmt);
        assertEq(usdc.balanceOf(address(escrowReal)), 0);
    }

    /// @dev triggerSettleFallback: treasury + reviewer == heldBackAmt + cashbackAmt.
    function testFuzz_TriggerSettleFallback_Solvency(uint128 heldBackAmt, uint128 cashbackAmt) public {
        heldBackAmt = uint128(bound(heldBackAmt, 0, type(uint64).max));
        cashbackAmt = uint128(bound(cashbackAmt, 0, type(uint64).max));
        uint256 total = uint256(heldBackAmt) + uint256(cashbackAmt);
        vm.assume(total > 0);

        usdc.mint(address(escrowReal), total);
        uint256 escrowId = _deposit(heldBackAmt, cashbackAmt);

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);

        escrowReal.triggerSettleFallback(escrowId);

        assertEq(usdc.balanceOf(treasury), heldBackAmt);
        assertEq(usdc.balanceOf(reviewer), cashbackAmt);
        assertEq(usdc.balanceOf(address(escrowReal)), 0);
    }

    /// @dev cashbackToReviewer reverts for any timestamp offset < windowEnd.
    function testFuzz_CashbackToReviewer_Revert_BeforeWindowEnd(uint256 offset) public {
        uint256 escrowId = _deposit(0, uint128(1e6));
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        uint256 windowEnd = uint256(r.windowEnd);

        offset = bound(offset, 0, windowEnd - block.timestamp - 1);
        vm.warp(block.timestamp + offset);

        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, windowEnd, block.timestamp)
        );
        escrowReal.cashbackToReviewer(escrowId);
    }

    /// @dev triggerSettleFallback reverts for any timestamp before windowEnd + 10 days.
    function testFuzz_TriggerSettleFallback_Revert_BeforeDelay(uint256 offset) public {
        uint256 escrowId = _deposit(uint128(1e6), 0);
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        uint256 eligibleAt = uint256(r.windowEnd) + 10 days;

        offset = bound(offset, 0, eligibleAt - block.timestamp - 1);
        vm.warp(block.timestamp + offset);

        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, eligibleAt, block.timestamp)
        );
        escrowReal.triggerSettleFallback(escrowId);
    }

    /// @dev unlockPct > 100 always reverts.
    function testFuzz_SettleHeldBack_Revert_UnlockPctOutOfRange(uint8 unlockPct) public {
        unlockPct = uint8(bound(unlockPct, 101, type(uint8).max));
        uint256 escrowId = _deposit(uint128(1e6), 0);

        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.UnlockPctOutOfRange.selector, unlockPct));
        escrowReal.settleHeldBack(escrowId, unlockPct);
    }

    /// @dev releaseCashback is idempotent — calling it a second time must not revert
    ///      and must not double-pay the buyer.
    function testFuzz_ReleaseCashback_Idempotent(uint256 cashbackAmt) public {
        cashbackAmt = bound(cashbackAmt, 1, type(uint96).max);

        usdc.mint(address(escrowReal), cashbackAmt);
        uint256 escrowId = _deposit(0, uint128(cashbackAmt));

        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);

        // Second call must not revert and must not transfer additional funds.
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);

        assertEq(usdc.balanceOf(buyer), cashbackAmt);
    }

    /// @dev After settleHeldBack + releaseCashback the escrow USDC balance is exactly
    ///      zero for any combination of amounts and unlock percentage.
    function testFuzz_Solvency_BalanceNeverNegative(uint256 heldBackAmt, uint256 cashbackAmt, uint8 unlockPct) public {
        heldBackAmt = bound(heldBackAmt, 0, type(uint96).max / 2);
        cashbackAmt = bound(cashbackAmt, 0, type(uint96).max / 2);
        unlockPct = uint8(bound(unlockPct, 0, 100));

        usdc.mint(address(escrowReal), heldBackAmt + cashbackAmt);
        uint256 escrowId = _deposit(uint128(heldBackAmt), uint128(cashbackAmt));

        // Warp past day 70 so all time-gated paths are open.
        vm.warp(block.timestamp + 71 days);

        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, unlockPct);

        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);

        assertEq(usdc.balanceOf(address(escrowReal)), 0);
    }
}
