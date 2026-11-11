// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {CommissionEscrow} from "../../src/CommissionEscrow.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";
import {ProtocolConstants} from "../../src/libraries/ProtocolConstants.sol";
import {FailingERC20} from "../helpers/FailingERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CommissionEscrowTest is MockFixture {
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

    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");
    uint256 internal constant HELD_BACK_AMT = 10e6;
    uint256 internal constant CASHBACK_AMT = 5e6;
    uint256 internal constant ORIGINAL_PURCHASE_AMT = 100e6;

    address internal pauserOnly = makeAddr("pauserOnly");
    address internal adminNoPauser = makeAddr("adminNoPauser");

    function setUp() public override {
        super.setUp();
        escrowReal = new CommissionEscrow(address(par), admin, address(usdc));

        vm.startPrank(admin);
        escrowReal.grantRole(keccak256("ORACLE_ROLE"), oracleAddr);
        // releaseCashback is oracle-only (REF-165); this caller acts as a second oracle.
        escrowReal.grantRole(keccak256("ORACLE_ROLE"), reviewRegistryCaller);
        // Pausing is its own role (REF-327). Admin holds it here so the existing paused-state
        // tests read unchanged; pauserOnly and adminNoPauser exercise the split itself.
        escrowReal.grantRole(escrowReal.PAUSER_ROLE(), admin);
        escrowReal.grantRole(escrowReal.PAUSER_ROLE(), pauserOnly);
        escrowReal.grantRole(0x00, adminNoPauser);
        vm.stopPrank();

        // Wire SPLIT_ROUTER in PAR (timelock=0, so executeUpdate is immediate)
        vm.prank(admin);
        par.setAddress(keccak256("SPLIT_ROUTER"), splitRouterAddr);
        par.executeUpdate(keccak256("SPLIT_ROUTER"));

        reviewerAgentId = agentRegistry.mint(reviewer);
        buyerAgentId = agentRegistry.mint(buyer);
        merchantId = agentRegistry.mint(merchantOwner);
        merchantRegistry.setActiveRaw(merchantId, true);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _deposit() internal returns (uint256 escrowId) {
        vm.prank(splitRouterAddr);
        escrowId = escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
    }

    function _depositAndFund() internal returns (uint256 escrowId) {
        usdc.mint(address(escrowReal), HELD_BACK_AMT + CASHBACK_AMT);
        return _deposit();
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_Deposit_HappyPath() public {
        uint256 escrowId = _deposit();
        assertEq(escrowId, 1);
    }

    // REF-161 review: every escrow must record a real paying wallet (consumed by C-4 bind). Reject 0.
    function test_Deposit_Revert_ZeroBuyerWallet() public {
        vm.prank(splitRouterAddr);
        vm.expectRevert(ICommissionEscrow.ZeroBuyerWallet.selector);
        escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            address(0),
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
    }

    // REF-161 review: releaseCashback resolves the buyer via _resolveWallet(buyerAgentId). For an
    // un-bound sentinel escrow that reverts (SENTINEL_BUYER is not a minted token). Locks the
    // behavior so oracle tooling knows not to call it before C-4 bind; funds still return to the
    // reviewer at windowEnd via cashbackToReviewer / the day-70 fallback.
    function test_ReleaseCashback_RevertsForUnboundSentinel() public {
        vm.prank(splitRouterAddr);
        uint256 escrowId = escrowReal.deposit(
            reviewerAgentId,
            type(uint256).max, // SENTINEL_BUYER
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
        usdc.mint(address(escrowReal), HELD_BACK_AMT + CASHBACK_AMT);
        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.BuyerNotBound.selector, escrowId));
        escrowReal.releaseCashback(escrowId);
    }

    // =========================================================================
    // bind (agent-less deferred binding, REF-162 / C-4)
    // =========================================================================

    function _depositSentinel() internal returns (uint256 escrowId) {
        vm.prank(splitRouterAddr);
        escrowId = escrowReal.deposit(
            reviewerAgentId,
            type(uint256).max, // SENTINEL_BUYER
            buyer, // buyerWallet = payer
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
    }

    function test_Bind_HappyPath() public {
        uint256 escrowId = _depositSentinel();
        vm.expectEmit(true, true, true, true);
        emit ICommissionEscrow.EscrowBound(escrowId, buyerAgentId, buyer);
        vm.prank(buyer);
        escrowReal.bind(escrowId, buyerAgentId);
        assertEq(escrowReal.getEscrow(escrowId).buyerAgentId, buyerAgentId);
    }

    function test_Bind_OwnerCaller_SkipsAgentWalletRead() public {
        uint256 escrowId = _depositSentinel();
        vm.expectCall(address(agentRegistry), abi.encodeCall(agentRegistry.getAgentWallet, (buyerAgentId)), 0);
        vm.prank(buyer); // NFT owner of buyerAgentId
        escrowReal.bind(escrowId, buyerAgentId);
    }

    function test_Bind_UnlocksCashbackRelease() public {
        uint256 escrowId = _depositSentinel();
        usdc.mint(address(escrowReal), HELD_BACK_AMT + CASHBACK_AMT);
        vm.prank(buyer);
        escrowReal.bind(escrowId, buyerAgentId);
        // No longer BuyerNotBound — releaseCashback pays the buyer's resolved wallet.
        vm.prank(oracleAddr);
        escrowReal.releaseCashback(escrowId);
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT);
    }

    function test_Bind_Revert_NonSentinelEscrow() public {
        uint256 escrowId = _deposit(); // normal escrow, buyerAgentId != SENTINEL_BUYER
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.AlreadyBound.selector, escrowId));
        escrowReal.bind(escrowId, buyerAgentId);
    }

    function test_Bind_Revert_DoubleBind() public {
        uint256 escrowId = _depositSentinel();
        vm.prank(buyer);
        escrowReal.bind(escrowId, buyerAgentId);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.AlreadyBound.selector, escrowId));
        escrowReal.bind(escrowId, buyerAgentId);
    }

    function test_Bind_Revert_NotBuyerWallet() public {
        uint256 escrowId = _depositSentinel();
        vm.prank(reviewer); // not the recorded buyerWallet (buyer)
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.NotBuyerWallet.selector, escrowId, reviewer));
        escrowReal.bind(escrowId, reviewerAgentId);
    }

    function test_Bind_Revert_NotAgentController() public {
        uint256 escrowId = _depositSentinel();
        vm.prank(buyer); // is buyerWallet, but neither owns nor is the agentWallet of reviewerAgentId
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.NotAgentController.selector, reviewerAgentId, buyer));
        escrowReal.bind(escrowId, reviewerAgentId);
    }

    function test_Bind_AcceptsConfiguredAgentWallet() public {
        // Identity whose NFT owner is NOT the payer, but whose configured agentWallet IS
        // (matches ReviewRegistry._isAgentCaller / _resolveWallet's owner-or-agentWallet model).
        address nftOwner = makeAddr("nftOwner");
        uint256 agentId = agentRegistry.mint(nftOwner);
        agentRegistry.setWallet(agentId, buyer); // buyer (the payer) is the agentWallet

        uint256 escrowId = _depositSentinel(); // buyerWallet = buyer
        vm.prank(buyer);
        escrowReal.bind(escrowId, agentId);
        assertEq(escrowReal.getEscrow(escrowId).buyerAgentId, agentId);
    }

    function test_Deposit_SequentialIds() public {
        uint256 id1 = _deposit();
        uint256 id2 = _deposit();
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_Deposit_StoresCorrectRecord() public {
        uint40 ts = uint40(block.timestamp);
        uint256 escrowId = _deposit();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);

        assertEq(r.reviewerAgentId, reviewerAgentId);
        assertEq(r.buyerAgentId, buyerAgentId);
        assertEq(r.buyerWallet, buyer);
        assertEq(r.merchantId, merchantId);
        assertEq(r.productId, PRODUCT_ID);
        assertEq(r.heldBackAmt, uint128(HELD_BACK_AMT));
        assertEq(r.cashbackAmt, uint128(CASHBACK_AMT));
        assertEq(r.originalPurchaseAmt, uint128(ORIGINAL_PURCHASE_AMT));
        assertEq(r.depositTimestamp, ts);
        assertEq(r.windowEnd, ts + uint40(60 days));
        assertEq(r.productType, 0);
        assertEq(uint8(r.state), uint8(ICommissionEscrow.EscrowState.Holding));
        assertFalse(r.cashbackReleased);
    }

    function test_Deposit_EmitsEscrowDeposited() public {
        vm.expectEmit(true, true, true, true);
        emit ICommissionEscrow.EscrowDeposited(
            1,
            reviewerAgentId,
            buyerAgentId,
            buyer,
            0,
            merchantId,
            PRODUCT_ID,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT)
        );
        _deposit();
    }

    function test_Deposit_IncrementsTotalEscrows() public {
        assertEq(escrowReal.totalEscrows(), 0);
        _deposit();
        assertEq(escrowReal.totalEscrows(), 1);
        _deposit();
        assertEq(escrowReal.totalEscrows(), 2);
    }

    function test_Deposit_Revert_CallerNotSplitRouter() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.CallerNotSplitRouter.selector, stranger));
        escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
    }

    function test_Deposit_Revert_WhenPaused() public {
        vm.prank(admin);
        escrowReal.pause();
        vm.prank(splitRouterAddr);
        vm.expectRevert();
        escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
    }

    // =========================================================================
    // settleHeldBack
    // =========================================================================

    function test_SettleHeldBack_FullToReviewer() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 100);
        assertEq(usdc.balanceOf(reviewer), HELD_BACK_AMT);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_SettleHeldBack_FullToTreasury() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 0);
        assertEq(usdc.balanceOf(reviewer), 0);
        assertEq(usdc.balanceOf(treasury), HELD_BACK_AMT);
    }

    function test_SettleHeldBack_PartialSplit() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 50);
        assertEq(usdc.balanceOf(reviewer), HELD_BACK_AMT / 2);
        assertEq(usdc.balanceOf(treasury), HELD_BACK_AMT / 2);
    }

    function test_SettleHeldBack_EmitsHeldBackSettled() public {
        uint256 escrowId = _depositAndFund();
        vm.expectEmit(true, true, true, true);
        emit ICommissionEscrow.HeldBackSettled(escrowId, reviewer, treasury, uint128(HELD_BACK_AMT), uint128(0));
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 100);
    }

    function test_SettleHeldBack_SetsStateSettled() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 100);
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(ICommissionEscrow.EscrowState.Settled));
    }

    function test_SettleHeldBack_ReviewerWallet_FallsBackToNFTOwner() public {
        // getAgentWallet returns 0 by default in MockAgentRegistry → falls back to ownerOf = reviewer
        assertEq(agentRegistry.getAgentWallet(reviewerAgentId), address(0));
        uint256 escrowId = _depositAndFund();
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 100);
        assertEq(usdc.balanceOf(reviewer), HELD_BACK_AMT);
    }

    function test_SettleHeldBack_Revert_AlreadySettled() public {
        uint256 escrowId = _depositAndFund();
        vm.startPrank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 100);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.AlreadySettled.selector, escrowId));
        escrowReal.settleHeldBack(escrowId, 100);
        vm.stopPrank();
    }

    function test_SettleHeldBack_Revert_UnlockPctOutOfRange() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.UnlockPctOutOfRange.selector, uint8(101)));
        escrowReal.settleHeldBack(escrowId, 101);
    }

    function test_SettleHeldBack_Revert_EscrowNotFound() public {
        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.EscrowNotFound.selector, uint256(9999)));
        escrowReal.settleHeldBack(9999, 100);
    }

    function test_SettleHeldBack_Revert_NotOracle() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        escrowReal.settleHeldBack(escrowId, 100);
    }

    function test_SettleHeldBack_Revert_WhenPaused() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(admin);
        escrowReal.pause();
        vm.prank(oracleAddr);
        vm.expectRevert();
        escrowReal.settleHeldBack(escrowId, 100);
    }

    // =========================================================================
    // releaseCashback
    // =========================================================================

    function test_ReleaseCashback_TransfersToBuyerWallet() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT);
    }

    function test_ReleaseCashback_EmitsCashbackReleased() public {
        uint256 escrowId = _depositAndFund();
        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.CashbackReleased(escrowId, buyer, uint128(CASHBACK_AMT));
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);
    }

    function test_ReleaseCashback_SetsCashbackReleasedFlag() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);
        assertTrue(escrowReal.getEscrow(escrowId).cashbackReleased);
    }

    function test_ReleaseCashback_Idempotent_NoOpOnSecondCall() public {
        uint256 escrowId = _depositAndFund();
        vm.startPrank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);
        uint256 buyerBalBefore = usdc.balanceOf(buyer);
        // Second call must not revert and must not transfer again
        escrowReal.releaseCashback(escrowId);
        vm.stopPrank();
        assertEq(usdc.balanceOf(buyer), buyerBalBefore);
    }

    function test_ReleaseCashback_Revert_EscrowNotFound() public {
        vm.prank(reviewRegistryCaller);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.EscrowNotFound.selector, uint256(9999)));
        escrowReal.releaseCashback(9999);
    }

    function test_ReleaseCashback_Revert_NotReviewRegistry() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        escrowReal.releaseCashback(escrowId);
    }

    function test_ReleaseCashback_Revert_WhenPaused() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(admin);
        escrowReal.pause();
        vm.prank(reviewRegistryCaller);
        vm.expectRevert();
        escrowReal.releaseCashback(escrowId);
    }

    // =========================================================================
    // cashbackToReviewer
    // =========================================================================

    function test_CashbackToReviewer_TransfersToReviewer() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(r.windowEnd);
        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);
        assertEq(usdc.balanceOf(reviewer), CASHBACK_AMT);
    }

    function test_CashbackToReviewer_EmitsCashbackReturnedToReviewer() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(r.windowEnd);
        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.CashbackReturnedToReviewer(escrowId, reviewer, uint128(CASHBACK_AMT));
        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);
    }

    function test_CashbackToReviewer_SetsCashbackReleasedFlag() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(r.windowEnd);
        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);
        assertTrue(escrowReal.getEscrow(escrowId).cashbackReleased);
    }

    function test_CashbackToReviewer_Revert_CashbackAlreadyReleased() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);
        vm.startPrank(oracleAddr);
        vm.warp(r.windowEnd);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.CashbackAlreadyReleased.selector, escrowId));
        escrowReal.cashbackToReviewer(escrowId);
        vm.stopPrank();
    }

    function test_CashbackToReviewer_Revert_TooEarly() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        // Any time strictly before windowEnd reverts
        vm.warp(r.windowEnd - 1);
        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, uint256(r.windowEnd), block.timestamp)
        );
        escrowReal.cashbackToReviewer(escrowId);
    }

    function test_CashbackToReviewer_Revert_TooEarlyAtWindowEnd_Minus1() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) - 1);
        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, uint256(r.windowEnd), block.timestamp)
        );
        escrowReal.cashbackToReviewer(escrowId);
    }

    function test_CashbackToReviewer_Revert_NotOracle() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(r.windowEnd);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        escrowReal.cashbackToReviewer(escrowId);
    }

    function test_CashbackToReviewer_Revert_WhenPaused() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(r.windowEnd);
        vm.prank(admin);
        escrowReal.pause();
        vm.prank(oracleAddr);
        vm.expectRevert();
        escrowReal.cashbackToReviewer(escrowId);
    }

    // =========================================================================
    // triggerSettleFallback
    // =========================================================================

    function test_TriggerSettleFallback_AnyoneCanCall() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        vm.prank(makeAddr("anyone"));
        escrowReal.triggerSettleFallback(escrowId); // must not revert
    }

    function test_TriggerSettleFallback_SendsHeldBackToTreasury() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        escrowReal.triggerSettleFallback(escrowId);
        assertEq(usdc.balanceOf(treasury), HELD_BACK_AMT);
    }

    function test_TriggerSettleFallback_SendsCashbackToReviewer_WhenNotReleased() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.FallbackSettled(escrowId, treasury, uint128(HELD_BACK_AMT), uint128(CASHBACK_AMT));
        escrowReal.triggerSettleFallback(escrowId);
        assertEq(usdc.balanceOf(reviewer), CASHBACK_AMT);
    }

    function test_TriggerSettleFallback_NoCashbackSent_WhenAlreadyReleased() public {
        uint256 escrowId = _depositAndFund();
        // Release cashback to buyer first
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);

        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.FallbackSettled(escrowId, treasury, uint128(HELD_BACK_AMT), uint128(0));
        escrowReal.triggerSettleFallback(escrowId);
        // Merchant receives nothing
        assertEq(usdc.balanceOf(merchantOwner), 0);
    }

    function test_TriggerSettleFallback_SetsStateSettled() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        escrowReal.triggerSettleFallback(escrowId);
        assertEq(uint8(escrowReal.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Settled));
    }

    function test_TriggerSettleFallback_EmitsFallbackSettled() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.FallbackSettled(escrowId, treasury, uint128(HELD_BACK_AMT), uint128(CASHBACK_AMT));
        escrowReal.triggerSettleFallback(escrowId);
    }

    function test_TriggerSettleFallback_Revert_AlreadySettled() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        escrowReal.triggerSettleFallback(escrowId);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.AlreadySettled.selector, escrowId));
        escrowReal.triggerSettleFallback(escrowId);
    }

    function test_TriggerSettleFallback_Revert_TooEarly() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        uint256 eligibleAt = uint256(r.windowEnd) + 10 days;
        vm.warp(eligibleAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, eligibleAt, block.timestamp)
        );
        escrowReal.triggerSettleFallback(escrowId);
    }

    function test_TriggerSettleFallback_Revert_WhenPaused() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        vm.prank(admin);
        escrowReal.pause();
        vm.expectRevert();
        escrowReal.triggerSettleFallback(escrowId);
    }

    // =========================================================================
    // treasury resolution (PAR is the single source of truth)
    // =========================================================================

    // The escrow holds no treasury of its own: it resolves PAR's TREASURY key on every
    // settlement. Replaces the old setTreasury/treasury() tests — the setter, the getter,
    // the TreasuryUpdated event and the ZeroTreasuryAddress guard were all removed, and
    // PAR now owns that surface (its own suite covers Revert_NotOwner / Revert_ZeroAddress).
    // This asserts the property those tests could not: a PAR change takes effect live,
    // with no redeploy and no per-contract update.
    function test_SettleHeldBack_PaysTreasuryResolvedFromPAR() public {
        uint256 escrowId = _depositAndFund();

        // Move the protocol treasury in PAR only; the escrow itself is never touched.
        address newTreasury = makeAddr("rotatedTreasury");
        bytes32 key = par.TREASURY();
        vm.startPrank(admin);
        par.setAddress(key, newTreasury);
        vm.stopPrank();
        par.executeUpdate(key);

        // unlockPct 0 sends the entire held-back amount to the treasury.
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 0);

        assertEq(usdc.balanceOf(newTreasury), HELD_BACK_AMT, "held-back must follow the PAR update");
        assertEq(usdc.balanceOf(treasury), 0, "the pre-rotation treasury must receive nothing");
    }

    // =========================================================================
    // setSettlementWindow (REF-161 / C-3)
    // =========================================================================

    function test_SettlementWindow_DefaultIs60Days() public view {
        assertEq(escrowReal.settlementWindow(), uint40(60 days));
    }

    function test_Constructor_EmitsInitialSettlementWindow() public {
        vm.expectEmit(false, false, false, true);
        emit ICommissionEscrow.SettlementWindowUpdated(0, uint40(60 days));
        new CommissionEscrow(address(par), admin, address(usdc));
    }

    function test_SetSettlementWindow_ChangesWindowEndForNewDeposits() public {
        uint40 ts = uint40(block.timestamp);
        uint40 newWindow = uint40(90 days);
        vm.prank(admin);
        escrowReal.setSettlementWindow(newWindow);

        uint256 id = _deposit();
        assertEq(escrowReal.getEscrow(id).windowEnd, ts + newWindow);
    }

    function test_SetSettlementWindow_ExistingEscrowsKeepStampedWindow() public {
        uint40 ts = uint40(block.timestamp);
        uint256 idOld = _deposit();
        assertEq(escrowReal.getEscrow(idOld).windowEnd, ts + uint40(60 days));

        vm.prank(admin);
        escrowReal.setSettlementWindow(uint40(90 days));

        // The already-stamped escrow is untouched.
        assertEq(escrowReal.getEscrow(idOld).windowEnd, ts + uint40(60 days));
        // A new deposit picks up the new window.
        uint256 idNew = _deposit();
        assertEq(escrowReal.getEscrow(idNew).windowEnd, ts + uint40(90 days));
    }

    function test_SetSettlementWindow_EmitsSettlementWindowUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit ICommissionEscrow.SettlementWindowUpdated(uint40(60 days), uint40(90 days));
        vm.prank(admin);
        escrowReal.setSettlementWindow(uint40(90 days));
    }

    function test_SetSettlementWindow_Boundary_1Day_Valid() public {
        vm.prank(admin);
        escrowReal.setSettlementWindow(uint40(1 days)); // must not revert
        assertEq(escrowReal.settlementWindow(), uint40(1 days));
    }

    function test_SetSettlementWindow_Boundary_180Days_Valid() public {
        vm.prank(admin);
        escrowReal.setSettlementWindow(uint40(180 days)); // must not revert
        assertEq(escrowReal.settlementWindow(), uint40(180 days));
    }

    function test_SetSettlementWindow_Revert_BelowMin() public {
        uint40 tooSmall = uint40(1 days) - 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.SettlementWindowOutOfBounds.selector, tooSmall));
        escrowReal.setSettlementWindow(tooSmall);
    }

    function test_SetSettlementWindow_Revert_AboveMax() public {
        uint40 tooBig = uint40(180 days) + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.SettlementWindowOutOfBounds.selector, tooBig));
        escrowReal.setSettlementWindow(tooBig);
    }

    function test_SetSettlementWindow_Revert_NotAdmin() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        escrowReal.setSettlementWindow(uint40(90 days));
    }

    // =========================================================================
    // pause / unpause
    // =========================================================================

    function test_Pause_AdminCanPause() public {
        vm.prank(admin);
        escrowReal.pause();
        assertTrue(escrowReal.paused());
    }

    function test_Unpause_AdminCanUnpause() public {
        vm.startPrank(admin);
        escrowReal.pause();
        escrowReal.unpause();
        vm.stopPrank();
        assertFalse(escrowReal.paused());
    }

    function test_Pause_Revert_NotAdmin() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        escrowReal.pause();
    }

    // Pausing the escrow halts BOTH payment rails, because every path deposits into it. That makes
    // it the emergency lever, and it is why it lives on its own role: admin is a multisig, and the
    // one action you need in minutes must not wait for co-signers.
    function test_Pause_PauserRoleCanPause() public {
        vm.prank(pauserOnly);
        escrowReal.pause();
        assertTrue(escrowReal.paused());
    }

    // The split is only real if holding DEFAULT_ADMIN_ROLE is not itself enough.
    function test_Pause_Revert_AdminWithoutPauserRole() public {
        vm.prank(adminNoPauser);
        vm.expectRevert();
        escrowReal.pause();
        assertFalse(escrowReal.paused());
    }

    // The asymmetry that makes the pauser key safe to keep reachable: it can stop the protocol and
    // cannot restart it, so a compromised pauser is a halt admin reverses, never a route to value.
    function test_Unpause_Revert_PauserRoleCannotUnpause() public {
        vm.prank(pauserOnly);
        escrowReal.pause();

        vm.prank(pauserOnly);
        vm.expectRevert();
        escrowReal.unpause();
        assertTrue(escrowReal.paused(), "only admin lifts a pause");

        vm.prank(admin);
        escrowReal.unpause();
        assertFalse(escrowReal.paused());
    }

    function test_Paused_BlocksDeposit() public {
        vm.prank(admin);
        escrowReal.pause();
        vm.prank(splitRouterAddr);
        vm.expectRevert();
        escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
    }

    function test_Paused_BlocksSettleHeldBack() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(admin);
        escrowReal.pause();
        vm.prank(oracleAddr);
        vm.expectRevert();
        escrowReal.settleHeldBack(escrowId, 100);
    }

    function test_Paused_BlocksReleaseCashback() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(admin);
        escrowReal.pause();
        vm.prank(reviewRegistryCaller);
        vm.expectRevert();
        escrowReal.releaseCashback(escrowId);
    }

    function test_Paused_BlocksCashbackToReviewer() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(r.windowEnd);
        vm.prank(admin);
        escrowReal.pause();
        vm.prank(oracleAddr);
        vm.expectRevert();
        escrowReal.cashbackToReviewer(escrowId);
    }

    function test_Paused_BlocksTriggerSettleFallback() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        vm.prank(admin);
        escrowReal.pause();
        vm.expectRevert();
        escrowReal.triggerSettleFallback(escrowId);
    }

    // =========================================================================
    // read functions
    // =========================================================================

    function test_GetEscrow_ReturnsRecord() public {
        uint40 ts = uint40(block.timestamp);
        uint256 escrowId = _deposit();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        assertEq(r.reviewerAgentId, reviewerAgentId);
        assertEq(r.buyerAgentId, buyerAgentId);
        assertEq(r.buyerWallet, buyer);
        assertEq(r.merchantId, merchantId);
        assertEq(r.productId, PRODUCT_ID);
        assertEq(r.heldBackAmt, uint128(HELD_BACK_AMT));
        assertEq(r.cashbackAmt, uint128(CASHBACK_AMT));
        assertEq(r.originalPurchaseAmt, uint128(ORIGINAL_PURCHASE_AMT));
        assertEq(r.depositTimestamp, ts);
        assertEq(r.windowEnd, ts + uint40(60 days));
        assertEq(uint8(r.state), uint8(ICommissionEscrow.EscrowState.Holding));
        assertFalse(r.cashbackReleased);
    }

    function test_GetEscrow_Revert_EscrowNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.EscrowNotFound.selector, uint256(9999)));
        escrowReal.getEscrow(9999);
    }

    function test_TotalEscrows_Zero_Initially() public view {
        assertEq(escrowReal.totalEscrows(), 0);
    }

    function test_TotalEscrows_IncrementsOnDeposit() public {
        assertEq(escrowReal.totalEscrows(), 0);
        _deposit();
        assertEq(escrowReal.totalEscrows(), 1);
        _deposit();
        assertEq(escrowReal.totalEscrows(), 2);
    }

    function test_Usdc_ReturnsAddress() public view {
        assertEq(escrowReal.usdc(), address(usdc));
    }

    function test_Paused_ReturnsFalse_Initially() public view {
        assertFalse(escrowReal.paused());
    }

    // =========================================================================
    // TransferFailed — FailingERC20
    // =========================================================================

    function test_SettleHeldBack_Revert_TransferFailed() public {
        FailingERC20 failingUsdc = new FailingERC20();
        CommissionEscrow failEscrow = new CommissionEscrow(address(par), admin, address(failingUsdc));
        vm.prank(admin);
        failEscrow.grantRole(keccak256("ORACLE_ROLE"), oracleAddr);

        vm.prank(splitRouterAddr);
        uint256 escrowId = failEscrow.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );

        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(failingUsdc)));
        failEscrow.settleHeldBack(escrowId, 100);
    }

    // =========================================================================
    // M-01: zero-transfer on mainnet USDC (zero cashbackAmt must not call transfer)
    // =========================================================================

    /// @dev releaseCashback with cashbackAmt=0 must not call transfer(buyer, 0).
    ///      Real USDC reverts on zero-amount transfers; mock the call to revert so we catch the bug.
    function test_ReleaseCashback_ZeroCashback_NoTransfer() public {
        // Deposit with cashback = 0.
        vm.prank(splitRouterAddr);
        uint256 escrowId = escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(0),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );

        // Mock: USDC.transfer(buyer, 0) reverts — simulating mainnet behaviour.
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), buyer, uint256(0)),
            "ERC20: zero transfer"
        );

        // releaseCashback must succeed without calling transfer.
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);

        // State is updated despite no transfer.
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        assertTrue(r.cashbackReleased, "cashbackReleased must be true");
    }

    /// @dev triggerSettleFallback with cashbackAmt=0 must not call transfer(reviewer, 0).
    function test_TriggerSettleFallback_ZeroCashback_NoTransfer() public {
        vm.prank(splitRouterAddr);
        uint256 escrowId = escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(0),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
        usdc.mint(address(escrowReal), HELD_BACK_AMT);

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);

        // Mock: USDC.transfer(reviewer, 0) reverts.
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), reviewer, uint256(0)),
            "ERC20: zero transfer"
        );

        // triggerSettleFallback must succeed without calling transfer for zero cashback.
        escrowReal.triggerSettleFallback(escrowId);

        ICommissionEscrow.EscrowRecord memory r2 = escrowReal.getEscrow(escrowId);
        assertEq(uint8(r2.state), uint8(ICommissionEscrow.EscrowState.Settled));
    }

    /// @dev CE-01: triggerSettleFallback must succeed for escrows with heldBackAmt=0.
    ///      Mainnet USDC reverts on transfer(to, 0); the guard must skip the treasury call.
    function test_TriggerSettleFallback_ZeroHeldBack_NoTreasuryTransfer() public {
        // Deposit with held-back = 0 (e.g. commissionBps = 0), cashback > 0.
        vm.prank(splitRouterAddr);
        uint256 escrowId = escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(0),
            uint128(CASHBACK_AMT),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
        usdc.mint(address(escrowReal), CASHBACK_AMT);

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);

        // Mock: USDC.transfer(treasury, 0) reverts — simulating mainnet USDC zero-transfer.
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), treasury, uint256(0)),
            "ERC20: zero transfer"
        );

        // fallback must succeed despite heldBackAmt = 0.
        escrowReal.triggerSettleFallback(escrowId);

        ICommissionEscrow.EscrowRecord memory r2 = escrowReal.getEscrow(escrowId);
        assertEq(uint8(r2.state), uint8(ICommissionEscrow.EscrowState.Settled));
        assertTrue(r2.cashbackReleased, "cashbackReleased must be true after fallback");
        // Cashback went to reviewer (not buyer — fallback path).
        assertEq(usdc.balanceOf(reviewer), CASHBACK_AMT);
    }

    // =========================================================================
    // REF-96 new tests — reviewer-funded cashback
    // =========================================================================

    /// @dev Deposits with a specific cashback amount; mints USDC to cover heldBack + cashback.
    function _depositWithCashback(uint256 reviewerAgent, uint256 buyerAgent, uint128 cashbackAmt)
        internal
        returns (uint256 escrowId)
    {
        usdc.mint(address(escrowReal), uint256(HELD_BACK_AMT) + uint256(cashbackAmt));
        vm.prank(splitRouterAddr);
        escrowId = escrowReal.deposit(
            reviewerAgent,
            buyerAgent,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            cashbackAmt,
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
    }

    function test_cashbackToReviewer_refundsReviewerAfterWindow() public {
        uint256 id = _depositWithCashback(reviewerAgentId, buyerAgentId, 40);
        vm.warp(block.timestamp + 60 days);
        vm.prank(oracleAddr);
        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.CashbackReturnedToReviewer(id, reviewer, 40);
        escrowReal.cashbackToReviewer(id);
        assertEq(usdc.balanceOf(reviewer), 40);
    }

    function test_cashbackSurvivesFullClawback() public {
        uint256 id = _depositWithCashback(reviewerAgentId, buyerAgentId, 40);
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(id, 0); // 100% clawback → treasury gets all held-back
        // cashback reserve untouched: buyer still gets it on review
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(id);
        assertEq(usdc.balanceOf(buyer), 40);
    }

    function test_fallback_routesUnreleasedCashbackToReviewer() public {
        uint256 id = _depositWithCashback(reviewerAgentId, buyerAgentId, 40);
        vm.warp(block.timestamp + 70 days + 1);
        escrowReal.triggerSettleFallback(id);
        assertEq(usdc.balanceOf(reviewer), 40); // was merchant in v2
    }

    /// @dev CE-02: cashbackToReviewer must not call transfer(reviewer, 0) when cashbackAmt=0.
    function test_CashbackToReviewer_ZeroCashback_NoTransfer() public {
        vm.prank(splitRouterAddr);
        uint256 escrowId = escrowReal.deposit(
            reviewerAgentId,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            uint128(HELD_BACK_AMT),
            uint128(0),
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
        usdc.mint(address(escrowReal), HELD_BACK_AMT);

        // Advance past windowEnd so cashbackToReviewer is eligible.
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 1);

        // Mock: USDC.transfer(reviewer, 0) reverts.
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), reviewer, uint256(0)),
            "ERC20: zero transfer"
        );

        // cashbackToReviewer must succeed without calling transfer.
        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);

        ICommissionEscrow.EscrowRecord memory r2 = escrowReal.getEscrow(escrowId);
        assertTrue(r2.cashbackReleased, "cashbackReleased must be true");
        assertEq(usdc.balanceOf(reviewer), 0, "no transfer should have occurred");
    }

    // =========================================================================
    // triggerSettleFallback after settleHeldBack (oracle-failure backstop)
    // =========================================================================

    // settleHeldBack marks the escrow Settled without touching cashbackReleased. If the
    // fallback rejected every Settled escrow, unreleased cashback would be reachable only
    // through the two ORACLE_ROLE paths — exactly the dependency the day-70 fallback exists
    // to remove. internal/settlement/cashback.go names this fallback as its remedy for a
    // cashback action that exhausted its retries.
    function test_TriggerSettleFallback_ReleasesCashback_AfterSettleHeldBack() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 0); // whole held-back to treasury

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);

        // heldBackAmt reports 0: this call settles cashback only.
        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.FallbackSettled(escrowId, treasury, uint128(0), uint128(CASHBACK_AMT));
        escrowReal.triggerSettleFallback(escrowId);

        assertEq(usdc.balanceOf(reviewer), CASHBACK_AMT, "cashback must reach the reviewer");
        assertTrue(escrowReal.getEscrow(escrowId).cashbackReleased, "cashbackReleased must be set");
    }

    // Mutation guard for the state gate on the treasury leg. heldBackAmt is never zeroed on
    // settle, so a cashback-only fallback that re-ran it would pay the held-back amount twice.
    // The escrow is deliberately over-funded: at exact funding a double transfer would revert on
    // balance and this test would pass for the wrong reason, observing nothing.
    function test_TriggerSettleFallback_DoesNotRepayHeldBack_AfterSettleHeldBack() public {
        uint256 escrowId = _depositAndFund();
        usdc.mint(address(escrowReal), HELD_BACK_AMT); // headroom for a double payment to land

        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 0);
        assertEq(usdc.balanceOf(treasury), HELD_BACK_AMT, "precondition: treasury paid once");

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        escrowReal.triggerSettleFallback(escrowId);

        assertEq(usdc.balanceOf(treasury), HELD_BACK_AMT, "held-back must not be paid a second time");
        assertEq(usdc.balanceOf(reviewer), CASHBACK_AMT, "cashback must still reach the reviewer");
    }

    // Both obligations discharged: the fallback has nothing left to do and stays closed.
    function test_TriggerSettleFallback_Revert_AfterSettleHeldBackAndCashbackReleased() public {
        uint256 escrowId = _depositAndFund();
        vm.prank(reviewRegistryCaller);
        escrowReal.releaseCashback(escrowId);
        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 0);

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.AlreadySettled.selector, escrowId));
        escrowReal.triggerSettleFallback(escrowId);
    }

    // The worst case for an un-bound buyer: releaseCashback reverts BuyerNotBound forever, so the
    // fallback is the only path that does not need the oracle. Pins the promise made in
    // CommissionEscrow.releaseCashback's comment ("funds still return to the reviewer at
    // day-60/70 if never bound"), which settleHeldBack would otherwise silently void.
    function test_TriggerSettleFallback_ReleasesCashback_AfterSettleHeldBack_UnboundBuyer() public {
        usdc.mint(address(escrowReal), HELD_BACK_AMT + CASHBACK_AMT);
        uint256 escrowId = _depositSentinel();

        vm.prank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 0);

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + 10 days);
        escrowReal.triggerSettleFallback(escrowId);

        assertEq(usdc.balanceOf(reviewer), CASHBACK_AMT, "unbound cashback must return to the reviewer");
    }

    // =========================================================================
    // No-referral escrow (#23): reviewer is SENTINEL_REVIEWER, amounts are zero
    // =========================================================================

    function _depositNoReferral() internal returns (uint256 escrowId) {
        vm.prank(splitRouterAddr);
        escrowId = escrowReal.deposit(
            ProtocolConstants.SENTINEL_REVIEWER,
            buyerAgentId,
            buyer,
            merchantId,
            PRODUCT_ID,
            0,
            0,
            0,
            uint128(ORIGINAL_PURCHASE_AMT),
            0
        );
    }

    /// @dev Would revert inside ownerOf(type(uint256).max) if the reviewer were resolved eagerly.
    function test_SettleHeldBack_NoReferralEscrow_SucceedsAsNoOp() public {
        uint256 full = _depositNoReferral();
        uint256 none = _depositNoReferral();

        vm.startPrank(oracleAddr);
        vm.expectEmit(true, false, false, true);
        emit ICommissionEscrow.HeldBackSettled(full, address(0), treasury, 0, 0);
        escrowReal.settleHeldBack(full, 100);
        escrowReal.settleHeldBack(none, 0);
        vm.stopPrank();

        assertEq(uint8(escrowReal.getEscrow(full).state), uint8(ICommissionEscrow.EscrowState.Settled));
        assertEq(uint8(escrowReal.getEscrow(none).state), uint8(ICommissionEscrow.EscrowState.Settled));
    }

    // =========================================================================
    // Paused time does not consume escrow deadlines (#12)
    // =========================================================================

    function _pause(uint256 forSeconds) internal {
        vm.prank(admin);
        escrowReal.pause();
        vm.warp(block.timestamp + forSeconds);
        vm.prank(admin);
        escrowReal.unpause();
    }

    /// @dev A pause after the deadline already passed must not re-lock an overdue escrow;
    ///      it may only push the deadline by the time actually spent paused.
    function test_PausedTime_OverdueEscrow_NotRelockedByShortPause() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.warp(uint256(r.windowEnd) + escrowReal.FALLBACK_GRACE_PERIOD() + 5 days);

        _pause(1 hours); // exit was already open; a 1-hour pause must not close it for 10 days

        escrowReal.triggerSettleFallback(escrowId);
        assertEq(uint8(escrowReal.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Settled));
    }

    /// @dev An escrow deposited after the pause ended was never affected by it.
    function test_PausedTime_EscrowDepositedAfterPause_NotExtended() public {
        vm.prank(admin);
        escrowReal.setSettlementWindow(1 days); // window shorter than any fixed grace period
        _pause(1 hours);

        uint256 escrowId = _depositAndFund();
        vm.warp(escrowReal.getEscrow(escrowId).windowEnd);

        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);
        assertTrue(escrowReal.getEscrow(escrowId).cashbackReleased);
    }

    /// @dev Two pauses shift the deadline by their combined length, not by a fresh grace each.
    function test_PausedTime_RepeatedPauses_ShiftByActualPausedTimeOnly() public {
        uint256 escrowId = _depositAndFund();
        uint256 windowEnd = escrowReal.getEscrow(escrowId).windowEnd;
        _pause(1 hours);
        _pause(1 hours);

        vm.warp(windowEnd + 1 hours); // only half the paused time has been made up
        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, windowEnd + 2 hours, block.timestamp)
        );
        escrowReal.cashbackToReviewer(escrowId);

        vm.warp(windowEnd + 2 hours);
        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);
        assertTrue(escrowReal.getEscrow(escrowId).cashbackReleased);
    }

    /// @dev A 40-day pause gives back 40 days, not a fixed 10.
    function test_PausedTime_LongPause_FullyCompensated() public {
        uint256 escrowId = _depositAndFund();
        uint256 windowEnd = escrowReal.getEscrow(escrowId).windowEnd;

        vm.warp(windowEnd - 20 days);
        _pause(40 days);

        vm.warp(windowEnd + 35 days); // still inside the 40 days the pause consumed
        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, windowEnd + 40 days, block.timestamp)
        );
        escrowReal.cashbackToReviewer(escrowId);

        vm.warp(windowEnd + 40 days);
        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);
        assertTrue(escrowReal.getEscrow(escrowId).cashbackReleased);
    }

    function test_PausedTime_NoPause_DeadlinesUnchanged() public {
        uint256 escrowId = _depositAndFund();
        uint256 windowEnd = escrowReal.getEscrow(escrowId).windowEnd;

        vm.warp(windowEnd);
        vm.prank(oracleAddr);
        escrowReal.cashbackToReviewer(escrowId);

        vm.warp(windowEnd + escrowReal.FALLBACK_GRACE_PERIOD());
        escrowReal.triggerSettleFallback(escrowId);
    }

    /// @dev The fallback leg carries the same shift as the windowEnd leg.
    function test_PausedTime_Fallback_ShiftedByPausedTime() public {
        uint256 escrowId = _depositAndFund();
        uint256 windowEnd = escrowReal.getEscrow(escrowId).windowEnd;
        uint256 eligible = windowEnd + escrowReal.FALLBACK_GRACE_PERIOD();
        _pause(2 days);

        vm.warp(eligible + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, eligible + 2 days, block.timestamp)
        );
        escrowReal.triggerSettleFallback(escrowId);

        vm.warp(eligible + 2 days);
        escrowReal.triggerSettleFallback(escrowId);
        assertEq(uint8(escrowReal.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Settled));
    }

    function test_PausedTime_OracleSettlementReopensImmediately() public {
        uint256 escrowId = _depositAndFund();
        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        vm.prank(admin);
        escrowReal.pause();
        vm.warp(uint256(r.windowEnd) + 30 days);
        vm.prank(admin);
        escrowReal.unpause();

        vm.startPrank(oracleAddr);
        escrowReal.settleHeldBack(escrowId, 100);
        escrowReal.releaseCashback(escrowId);
        vm.stopPrank();
        assertTrue(escrowReal.getEscrow(escrowId).cashbackReleased);
    }

    function test_PausedTime_RecordSnapshotsCounterAtDeposit() public {
        assertEq(escrowReal.totalPausedSeconds(), 0);
        uint256 first = _depositAndFund();
        _pause(3 hours);
        uint256 second = _depositAndFund();

        assertEq(escrowReal.totalPausedSeconds(), 3 hours);
        assertEq(escrowReal.getEscrow(first).pausedTotalAtDeposit, 0, "predates the pause");
        assertEq(escrowReal.getEscrow(second).pausedTotalAtDeposit, 3 hours, "carries the banked total");
    }

    function test_PausedTime_BindReopensImmediately() public {
        uint256 escrowId = _depositSentinel();
        _pause(1 hours);
        vm.prank(buyer);
        escrowReal.bind(escrowId, buyerAgentId);
        assertEq(escrowReal.getEscrow(escrowId).buyerAgentId, buyerAgentId);
    }

    // =========================================================================
    // Fallback legs settle independently (#11)
    // =========================================================================

    function _fallbackReady() internal returns (uint256 escrowId) {
        escrowId = _depositAndFund();
        vm.warp(uint256(escrowReal.getEscrow(escrowId).windowEnd) + 10 days);
    }

    /// @dev Circle USDC reverts transfers to a blacklisted address.
    function _blacklistReviewer() internal {
        vm.mockCallRevert(
            address(usdc),
            abi.encodeCall(usdc.transfer, (reviewer, CASHBACK_AMT)),
            "Blacklistable: account is blacklisted"
        );
    }

    function test_Fallback_BlacklistedReviewer_TreasuryStillSettles() public {
        uint256 escrowId = _fallbackReady();
        _blacklistReviewer();

        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.FallbackCashbackFailed(escrowId, reviewer, uint128(CASHBACK_AMT));
        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.FallbackSettled(escrowId, treasury, uint128(HELD_BACK_AMT), 0);
        escrowReal.triggerSettleFallback(escrowId);

        ICommissionEscrow.EscrowRecord memory r = escrowReal.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(ICommissionEscrow.EscrowState.Settled));
        assertFalse(r.cashbackReleased, "cashback leg stays open");
        assertEq(usdc.balanceOf(treasury), HELD_BACK_AMT);
        assertEq(usdc.balanceOf(address(escrowReal)), CASHBACK_AMT);
    }

    function test_Fallback_RetryAfterUnblacklist_PaysReviewerOnly() public {
        uint256 escrowId = _fallbackReady();
        _blacklistReviewer();
        escrowReal.triggerSettleFallback(escrowId);

        vm.clearMockedCalls(); // reviewer no longer blacklisted
        vm.recordLogs();
        escrowReal.triggerSettleFallback(escrowId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ICommissionEscrow.FallbackCashbackFailed.selector, "no failure event");
        }

        assertEq(usdc.balanceOf(reviewer), CASHBACK_AMT);
        assertEq(usdc.balanceOf(treasury), HELD_BACK_AMT, "treasury not paid twice");
        assertTrue(escrowReal.getEscrow(escrowId).cashbackReleased);

        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.AlreadySettled.selector, escrowId));
        escrowReal.triggerSettleFallback(escrowId);
    }

    function test_Fallback_UnresolvableReviewer_TreasuryStillSettles() public {
        uint256 escrowId = _fallbackReady();
        vm.mockCallRevert(
            address(agentRegistry), abi.encodeCall(agentRegistry.ownerOf, (reviewerAgentId)), "nonexistent token"
        );

        vm.expectEmit(true, true, false, true);
        emit ICommissionEscrow.FallbackCashbackFailed(escrowId, address(0), uint128(CASHBACK_AMT));
        escrowReal.triggerSettleFallback(escrowId);

        assertEq(usdc.balanceOf(treasury), HELD_BACK_AMT);
        assertFalse(escrowReal.getEscrow(escrowId).cashbackReleased);
    }
}
