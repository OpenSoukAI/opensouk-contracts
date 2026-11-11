// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IntegrationFixture} from "../helpers/Fixtures.sol";
import {EIP712Helpers} from "../helpers/EIP712Helpers.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";

/// @title ReviewerFundedCashbackTest
/// @notice Dedicated end-to-end tests for the reviewer-funded cashback v3 model,
///         over the x402 `SplitRouter` on Base:
///           1. route → settleHeldBack(0) (full clawback) → releaseCashback still pays buyer
///           2. route → warp past windowEnd → cashbackToReviewer refunds reviewer
///           3. Value accounting: reviewer got immediate−cashback, merchant got gross−commission−fee,
///              treasury got fee.
///
/// @dev    The former "Part 2" of this file covered the same three flows over the
///         MPP session `closeAndSplit` path, which was removed when the session rail was
///         retired. Cashback semantics
///         live in `CommissionEscrow`, which is router-agnostic, so this file remains the
///         authoritative coverage for the model itself.

contract ReviewerFundedCashbackX402Test is IntegrationFixture {
    using EIP712Helpers for *;

    uint256 internal reviewerPk = 0xC4514B;
    address internal reviewerOwner;
    uint256 internal reviewerAgentId;

    address internal buyer;
    uint256 internal buyerPk;
    uint256 internal buyerAgentId;

    address internal merchantOwner = makeAddr("merchantOwner");
    uint256 internal merchantId;

    bytes32 internal constant PRODUCT_ID = keccak256("product-cashback-x402");

    // Rates: 10% commission, cashback 40% OF COMMISSION (== old 4% of gross), 2% platform fee, 70% multiplier.
    uint16 internal constant COMMISSION_BPS = 1000;
    uint16 internal constant CASHBACK_BPS = 4000;
    uint16 internal constant COMMISSION_MULTIPLIER_BPS = 7000;

    // Derived amounts for GROSS = 100e6:
    //   base_commission      = 10e6
    //   immediate_commission = 7e6  (10e6 × 70%)
    //   held_back            = 3e6
    //   cashback             = 4e6  (reviewer-funded, carved from immediate)
    //   reviewer_net         = 3e6  (7e6 − 4e6)
    //   platform_fee         = 2e6
    //   merchant_net         = 88e6 (100 − 10 − 2, cashback not deducted)
    uint256 internal constant GROSS = 100e6;
    uint256 internal constant IMMEDIATE_COMMISSION = 7e6;
    uint256 internal constant HELD_BACK_AMT = 3e6;
    uint256 internal constant CASHBACK_AMT = 4e6;
    uint256 internal constant REVIEWER_NET = 3e6;
    uint256 internal constant PLATFORM_FEE_AMT = 2e6;
    uint256 internal constant MERCHANT_AMT = 88e6;

    function setUp() public override {
        super.setUp();
        // route() pulls via a signed ERC-3009 authorization, so the buyer needs a key.
        // makeAddrAndKey yields the same address makeAddr did for this label.
        (buyer, buyerPk) = makeAddrAndKey("buyer");
        reviewerOwner = vm.addr(reviewerPk);
        reviewerAgentId = mintAgent(reviewerOwner);
        buyerAgentId = mintAgent(buyer);
        merchantId = mintMerchant(merchantOwner);
        addProduct(merchantId, merchantOwner, PRODUCT_ID, COMMISSION_BPS, CASHBACK_BPS);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _oracleReview(uint256 nonce) internal returns (uint256 reviewId) {
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = EIP712Helpers.signReviewCommitment(
            vm,
            reviewerPk,
            address(reviewRegistry),
            block.chainid,
            reviewerAgentId,
            merchantId,
            PRODUCT_ID,
            keccak256("cashback-review-content"),
            nonce,
            expiry
        );
        IReviewRegistry.Sig memory reviewSig = IReviewRegistry.Sig({nonce: nonce, expiry: expiry, agentSignature: sig});
        vm.prank(oracle);
        reviewId = reviewRegistry.publishReview(
            reviewerAgentId,
            merchantId,
            PRODUCT_ID,
            keccak256("cashback-review-content"),
            IReviewRegistry.ProofType.AdminApproved,
            reviewSig
        );
    }

    function _route(uint256 reviewId) internal returns (uint256 escrowId) {
        usdc.mint(buyer, GROSS);
        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: GROSS,
            buyer: buyer,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: CASHBACK_BPS
        });
        ISplitRouter.ERC3009Params memory ep = signRouteAuth(rp, buyerPk);
        vm.prank(facilitator);
        escrowId = splitRouter.route(rp, ep);
    }

    // =========================================================================
    // 1. Clawback-survival: settleHeldBack(0) then releaseCashback still pays buyer
    // =========================================================================

    /// @dev settleHeldBack(0) = oracle slashes the reviewer (heldBack goes entirely to treasury).
    ///      The cashback held in escrow is independent of the heldBack decision.
    ///      After a full slash, releaseCashback must still deliver the cashback to the buyer.
    function test_ClawbackSurvival_BuyerStillGetsCashback() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);

        // Post-route: verify initial state.
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET, "reviewer net at route");
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT, "treasury fee at route");
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT, "merchant at route");
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK_AMT + CASHBACK_AMT, "escrow holds held+cashback");
        assertFalse(escrow.getEscrow(escrowId).cashbackReleased, "cashback not yet released");

        // Oracle slashes heldBack 100% to treasury (unlockPct = 0).
        vm.prank(oracle);
        escrow.settleHeldBack(escrowId, 0);

        assertEq(
            uint8(escrow.getEscrow(escrowId).state),
            uint8(ICommissionEscrow.EscrowState.Settled),
            "state Settled after slash"
        );
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT + HELD_BACK_AMT, "treasury got slashed held-back");
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET, "reviewer unchanged after slash");
        // Cashback still in escrow.
        assertEq(usdc.balanceOf(address(escrow)), CASHBACK_AMT, "cashback still in escrow post-slash");

        // releaseCashback still works (state == Settled does not block cashback release).
        vm.prank(oracle);
        escrow.releaseCashback(escrowId);

        assertTrue(escrow.getEscrow(escrowId).cashbackReleased, "cashback released");
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT, "buyer got cashback despite full clawback");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow empty");
    }

    // =========================================================================
    // 2. No-review path: warp past windowEnd → cashbackToReviewer refunds reviewer
    // =========================================================================

    /// @dev If the buyer never posts a review, the reviewer gets the cashback back after windowEnd.
    function test_NoReviewPath_CashbackToReviewer_AfterWindowEnd() public {
        uint256 reviewId = _oracleReview(2);
        uint256 escrowId = _route(reviewId);

        uint256 reviewerBalBeforeRefund = usdc.balanceOf(reviewerOwner);
        ICommissionEscrow.EscrowRecord memory rec = escrow.getEscrow(escrowId);

        // Before windowEnd: cashbackToReviewer must revert.
        vm.prank(oracle);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, rec.windowEnd, block.timestamp)
        );
        escrow.cashbackToReviewer(escrowId);

        // Warp to exactly windowEnd.
        vm.warp(rec.windowEnd);
        vm.prank(oracle);
        escrow.cashbackToReviewer(escrowId);

        assertTrue(escrow.getEscrow(escrowId).cashbackReleased, "cashback marked released");
        assertEq(usdc.balanceOf(reviewerOwner), reviewerBalBeforeRefund + CASHBACK_AMT, "reviewer got cashback refund");
        assertEq(usdc.balanceOf(buyer), 0, "buyer got nothing (no review)");
    }

    // =========================================================================
    // 3. Full happy path: route → settleHeldBack(100) → releaseCashback
    //    with exact per-party accounting assertions
    // =========================================================================

    function test_FullHappyPath_ExactValueAccounting() public {
        uint256 reviewId = _oracleReview(3);
        uint256 escrowId = _route(reviewId);

        // Reviewer gets immediate − cashback at route time.
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET, "reviewer net");
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT, "merchant net");
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT, "platform fee");
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK_AMT + CASHBACK_AMT, "escrow");

        // Oracle settles (full unlock to reviewer).
        vm.prank(oracle);
        escrow.settleHeldBack(escrowId, 100);

        // Reviewer total = REVIEWER_NET + HELD_BACK_AMT = 3e6 + 3e6 = 6e6.
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET + HELD_BACK_AMT, "reviewer after settle");

        // Oracle releases cashback to buyer.
        vm.prank(oracle);
        escrow.releaseCashback(escrowId);

        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT, "buyer cashback");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow empty");

        // Value conservation: sum of all outflows == GROSS.
        uint256 total = usdc.balanceOf(reviewerOwner) + usdc.balanceOf(buyer) + usdc.balanceOf(merchantOwner)
            + usdc.balanceOf(treasury);
        assertEq(total, GROSS, "value conservation");
    }

    // =========================================================================
    // 4. releaseCashback idempotent (double-call is a no-op, not a double-pay)
    // =========================================================================

    function test_ReleaseCashback_Idempotent_NoBuyerDoublePayment() public {
        uint256 reviewId = _oracleReview(4);
        uint256 escrowId = _route(reviewId);

        vm.prank(oracle);
        escrow.releaseCashback(escrowId);
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT);

        // Second call is a no-op (not a revert, not a second transfer).
        vm.prank(oracle);
        escrow.releaseCashback(escrowId); // idempotent

        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT, "buyer balance unchanged on double-call");
    }

    // =========================================================================
    // 5. cashbackToReviewer blocked if already released via releaseCashback
    // =========================================================================

    function test_CashbackToReviewer_RevertsIfAlreadyReleased() public {
        uint256 reviewId = _oracleReview(5);
        uint256 escrowId = _route(reviewId);

        // Release cashback to buyer first.
        vm.prank(oracle);
        escrow.releaseCashback(escrowId);

        ICommissionEscrow.EscrowRecord memory rec = escrow.getEscrow(escrowId);
        vm.warp(rec.windowEnd);

        // cashbackToReviewer must revert: already released.
        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(ICommissionEscrow.CashbackAlreadyReleased.selector, escrowId));
        escrow.cashbackToReviewer(escrowId);
    }
}
