// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IntegrationFixture} from "../helpers/Fixtures.sol";
import {EIP712Helpers} from "../helpers/EIP712Helpers.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";
import {ProtocolConstants} from "../../src/libraries/ProtocolConstants.sol";
import {CommissionEscrow} from "../../src/CommissionEscrow.sol";
import {ProtocolAddressRegistry} from "../../src/ProtocolAddressRegistry.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";
import {IProtocolAddressRegistry} from "../../src/interfaces/IProtocolAddressRegistry.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract ProtocolIntegration is IntegrationFixture {
    using EIP712Helpers for *;

    uint256 internal reviewerPk = 0xA11CE;
    address internal reviewerOwner;
    uint256 internal reviewerAgentId;

    address internal buyer;
    uint256 internal buyerPk;
    uint256 internal buyerAgentId;

    address internal merchantOwner = makeAddr("merchantOwner");
    uint256 internal merchantId;

    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");
    bytes32 internal constant CONTENT_HASH = keccak256("review content");
    uint256 internal constant GROSS = 100e6;

    uint16 internal constant COMMISSION_BPS = 1000; // 10%
    uint16 internal constant CASHBACK_BPS = 4000; // 40% OF COMMISSION → 4e6 (== old 4% of gross; at 40% cap)
    uint16 internal constant COMMISSION_MULTIPLIER_BPS = 5000; // 50% immediate

    // Computed amounts: GROSS=100e6, COMMISSION_BPS=1000, CASHBACK_BPS=4000 (of commission),
    //                   PLATFORM_FEE_BPS=200, COMMISSION_MULTIPLIER_BPS=5000
    // base_commission      = 10e6
    // immediate_commission = 5e6  (10e6 × 50%)
    // held_back            = 5e6
    // cashback             = 4e6  (reviewer-funded)
    // reviewer_net         = 1e6  (5e6 − 4e6)
    // platform_fee         = 2e6
    // merchant_net         = 88e6 (100 − 10 − 2, cashback not deducted)
    uint256 internal constant COMMISSION_AMT = 10e6;
    uint256 internal constant IMMEDIATE_COMMISSION_AMT = 5e6;
    uint256 internal constant HELD_BACK_AMT = 5e6;
    uint256 internal constant CASHBACK_AMT = 4e6;
    uint256 internal constant REVIEWER_NET_AMT = 1e6; // IMMEDIATE_COMMISSION_AMT - CASHBACK_AMT

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

    // =========================================================================
    // Helpers
    // =========================================================================

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
            CONTENT_HASH,
            nonce,
            expiry
        );
        IReviewRegistry.Sig memory reviewSig = IReviewRegistry.Sig({nonce: nonce, expiry: expiry, agentSignature: sig});
        vm.prank(oracle);
        reviewId = reviewRegistry.publishReview(
            reviewerAgentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, reviewSig
        );
    }

    function _route(uint256 reviewId) internal returns (uint256 escrowId) {
        return _routeAs(buyerAgentId, buyer, reviewId);
    }

    function _routeAs(uint256 agentId, address buyerAddr, uint256 routeReviewId) internal returns (uint256 escrowId) {
        usdc.mint(buyerAddr, GROSS);
        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: agentId,
            reviewId: routeReviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: GROSS,
            buyer: buyerAddr,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: CASHBACK_BPS
        });
        ISplitRouter.ERC3009Params memory ep = signRouteAuth(rp, buyerPk);
        vm.prank(facilitator);
        escrowId = splitRouter.route(rp, ep);
    }

    function _erc3009Params(ISplitRouter.RouteParams memory rp) internal returns (ISplitRouter.ERC3009Params memory) {
        return signRouteAuth(rp, buyerPk);
    }

    function _routeParams(uint256 routeReviewId) internal view returns (ISplitRouter.RouteParams memory) {
        return ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: routeReviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: GROSS,
            buyer: buyer,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: CASHBACK_BPS
        });
    }

    function _settleHeldBack(uint256 escrowId) internal {
        vm.prank(oracle);
        escrow.settleHeldBack(escrowId, 100);
    }

    function _releaseCashback(uint256 escrowId) internal {
        vm.prank(oracle);
        escrow.releaseCashback(escrowId);
    }

    // =========================================================================
    // 1. Full happy path — oracle settles held-back to reviewer + cashback to buyer
    // =========================================================================

    function test_Integration_FullHappyPath_OracleReview() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);

        // Post-route: reviewer got reviewer_net (immediate − cashback); escrow holds held_back + cashback.
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET_AMT);
        assertEq(usdc.balanceOf(treasury), 2e6); // platform fee
        assertEq(usdc.balanceOf(merchantOwner), 88e6);
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK_AMT + CASHBACK_AMT);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Holding));

        // Oracle settles held-back to reviewer (unlockPct=100).
        _settleHeldBack(escrowId);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Settled));
        // Reviewer total = reviewer_net(1e6) + held_back(5e6) = 6e6.
        assertEq(usdc.balanceOf(reviewerOwner), 6e6);

        // Oracle releases cashback to buyer.
        _releaseCashback(escrowId);
        assertTrue(escrow.getEscrow(escrowId).cashbackReleased);
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // =========================================================================
    // 2. Full happy path — agent-direct review with escrow proof
    // =========================================================================

    function test_Integration_FullHappyPath_EscrowProofReview() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);

        vm.prank(buyer);
        uint256 proofReviewId = reviewRegistry.publishReviewWithEscrowProof(buyerAgentId, CONTENT_HASH, escrowId);

        IReviewRegistry.Review memory r = reviewRegistry.getReview(proofReviewId);
        assertEq(uint256(r.proofType), uint256(IReviewRegistry.ProofType.InSystemPurchase));
        assertEq(r.agentId, buyerAgentId);

        _settleHeldBack(escrowId);
        _releaseCashback(escrowId);

        // reviewer_net(1e6) + held_back(5e6) = 6e6
        assertEq(usdc.balanceOf(reviewerOwner), 6e6);
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// @dev publishReviewWithEscrowProof records the review but must NOT release
    ///      cashback. Release is oracle-only (gated on votes off-chain); the buyer
    ///      is paid only when the oracle explicitly calls releaseCashback.
    function test_Integration_EscrowProof_DoesNotAutoReleaseCashback() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);

        vm.prank(buyer);
        reviewRegistry.publishReviewWithEscrowProof(buyerAgentId, CONTENT_HASH, escrowId);

        // Publishing does not touch the escrow's cashback.
        assertFalse(escrow.getEscrow(escrowId).cashbackReleased);
        assertEq(usdc.balanceOf(buyer), 0);

        // Only the oracle release pays the buyer.
        _releaseCashback(escrowId);
        assertTrue(escrow.getEscrow(escrowId).cashbackReleased);
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT);
    }

    // =========================================================================
    // 2b. Agent-less lifecycle: sentinel purchase → bind → claim
    // =========================================================================

    function test_Integration_AgentLess_BindThenClaim() public {
        uint256 reviewId = _oracleReview(1);
        // Buyer pays with the sentinel (no identity up front); buyerWallet = buyer.
        uint256 escrowId = _routeAs(splitRouter.SENTINEL_BUYER(), buyer, reviewId);
        assertEq(escrow.getEscrow(escrowId).buyerAgentId, splitRouter.SENTINEL_BUYER());
        assertEq(escrow.getEscrow(escrowId).buyerWallet, buyer);

        // Before bind, the escrow-proof review is rejected (escrow.buyerAgentId is the sentinel).
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.EscrowMismatch.selector, escrowId));
        reviewRegistry.publishReviewWithEscrowProof(buyerAgentId, CONTENT_HASH, escrowId);

        // Buyer registered buyerAgentId (owns it) and binds the prior purchase to it.
        vm.prank(buyer);
        escrow.bind(escrowId, buyerAgentId);
        assertEq(escrow.getEscrow(escrowId).buyerAgentId, buyerAgentId);

        // Now the escrow-proof review succeeds and the cashback is claimed.
        vm.prank(buyer);
        reviewRegistry.publishReviewWithEscrowProof(buyerAgentId, CONTENT_HASH, escrowId);
        _releaseCashback(escrowId);
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT);
    }

    // =========================================================================
    // 3. Oracle settles held-back to treasury (unlockPct=0)
    // =========================================================================

    function test_Integration_SettleHeldBack_FullToTreasury() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        vm.prank(oracle);
        escrow.settleHeldBack(escrowId, 0);

        // held_back goes to treasury; reviewer keeps only the reviewer_net already received.
        assertEq(usdc.balanceOf(treasury), treasuryBalBefore + HELD_BACK_AMT);
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET_AMT);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Settled));
    }

    // =========================================================================
    // 4. Oracle returns cashback to reviewer after windowEnd
    // =========================================================================

    function test_Integration_CashbackToReviewer_AfterWindowEnd() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);
        ICommissionEscrow.EscrowRecord memory rec = escrow.getEscrow(escrowId);
        uint256 reviewerBalBefore = usdc.balanceOf(reviewerOwner);

        vm.warp(rec.windowEnd);
        vm.prank(oracle);
        escrow.cashbackToReviewer(escrowId);

        assertTrue(escrow.getEscrow(escrowId).cashbackReleased);
        assertEq(usdc.balanceOf(reviewerOwner), reviewerBalBefore + CASHBACK_AMT);
    }

    // =========================================================================
    // 5. Public fallback — triggerSettleFallback after windowEnd + 10 days
    // =========================================================================

    function test_Integration_TriggerSettleFallback_AfterDay70() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);
        ICommissionEscrow.EscrowRecord memory rec = escrow.getEscrow(escrowId);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);
        uint256 reviewerBalBefore = usdc.balanceOf(reviewerOwner);

        uint256 eligibleAt = uint256(rec.windowEnd) + 10 days;
        vm.warp(eligibleAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionEscrow.TooEarly.selector, escrowId, eligibleAt, block.timestamp)
        );
        escrow.triggerSettleFallback(escrowId);

        vm.warp(eligibleAt);
        vm.prank(makeAddr("anyone"));
        escrow.triggerSettleFallback(escrowId);

        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Settled));
        // Fallback sends held_back to treasury and cashback to reviewer.
        assertEq(usdc.balanceOf(treasury), treasuryBalBefore + HELD_BACK_AMT);
        assertEq(usdc.balanceOf(reviewerOwner), reviewerBalBefore + CASHBACK_AMT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // =========================================================================
    // 6. Rate change takes effect for new purchases (commission read LIVE from ProductRegistry)
    // =========================================================================

    function test_Integration_RateChange_AffectsNewPurchases() public {
        // Route 1: commission 10%, cashback 4%, fee 2%, multiplier 50%.
        uint256 reviewId1 = _oracleReview(1);
        _route(reviewId1);
        assertEq(usdc.balanceOf(merchantOwner), 88e6);

        // Merchant raises the product commission to 20% in ProductRegistry (read live at settle).
        vm.prank(merchantOwner);
        productRegistry.setCommission(merchantId, PRODUCT_ID, 2000);

        // Route 2: commission 20% (from ProductRegistry), cashback 0%.
        uint256 reviewId2 = _oracleReview(2);
        usdc.mint(buyer, GROSS);
        ISplitRouter.RouteParams memory rp2 = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId2,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: GROSS,
            buyer: buyer,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: 0
        });
        ISplitRouter.ERC3009Params memory ep2 = _erc3009Params(rp2);
        vm.prank(facilitator);
        splitRouter.route(rp2, ep2);

        // merchant gets 78e6 (100 - 20 - 0 - 2) on second purchase.
        assertEq(usdc.balanceOf(merchantOwner), 88e6 + 78e6);
        assertEq(usdc.balanceOf(buyer), 0); // no cashback on route2
        assertEq(escrow.totalEscrows(), 2);
        // held_back for route2: 20e6 × 50% = 10e6
        assertEq(escrow.getEscrow(2).heldBackAmt, 10e6);
    }

    // =========================================================================
    // 7. PAR timelock — update ESCROW address
    // =========================================================================

    function test_Integration_PAR_Timelock_UpdateEscrowAddress() public {
        CommissionEscrow escrow2 = new CommissionEscrow(address(par), admin, address(usdc));
        bytes32 escrowKey = par.ESCROW();

        vm.startPrank(admin);
        par.setAddress(escrowKey, address(escrow2));
        vm.stopPrank();
        par.executeUpdate(escrowKey);

        assertEq(par.getAddress(escrowKey), address(escrow2));

        uint256 reviewId = _oracleReview(1);
        _route(reviewId);

        assertEq(escrow2.totalEscrows(), 1);
        assertEq(escrow.totalEscrows(), 0);
    }

    function test_Integration_PAR_Timelock_Revert_BeforeDelay() public {
        CommissionEscrow escrow2 = new CommissionEscrow(address(par), admin, address(usdc));

        bytes32[] memory keys = new bytes32[](0);
        address[] memory vals = new address[](0);
        ProtocolAddressRegistry par2 = new ProtocolAddressRegistry(admin, guardian, 2 days, keys, vals);
        bytes32 escrowKey = par2.ESCROW();

        vm.startPrank(admin);
        par2.setAddress(escrowKey, address(escrow2));
        vm.stopPrank();

        (, uint256 effectiveAt) = par2.getPending(escrowKey);
        vm.expectRevert(
            abi.encodeWithSelector(IProtocolAddressRegistry.TimelockNotExpired.selector, effectiveAt, block.timestamp)
        );
        par2.executeUpdate(escrowKey);

        vm.warp(block.timestamp + 2 days);
        par2.executeUpdate(escrowKey);
        assertEq(par2.getAddress(escrowKey), address(escrow2));
    }

    // =========================================================================
    // 8. Suspended merchant blocks purchase
    // =========================================================================

    function test_Integration_SuspendedMerchant_BlocksRoute() public {
        uint256 reviewId = _oracleReview(1);

        vm.prank(admin);
        merchantRegistry.suspend(merchantId, "fraud");

        ISplitRouter.RouteParams memory rp = _routeParams(reviewId);
        ISplitRouter.ERC3009Params memory ep = _erc3009Params(rp);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.MerchantNotActive.selector, merchantId));
        vm.prank(facilitator);
        splitRouter.route(rp, ep);
    }

    function test_Integration_UnsuspendedMerchant_AllowsRoute() public {
        uint256 reviewId = _oracleReview(1);

        vm.prank(admin);
        merchantRegistry.suspend(merchantId, "fraud");

        usdc.mint(buyer, GROSS);
        ISplitRouter.RouteParams memory rp = _routeParams(reviewId);
        ISplitRouter.ERC3009Params memory ep = _erc3009Params(rp);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.MerchantNotActive.selector, merchantId));
        vm.prank(facilitator);
        splitRouter.route(rp, ep);

        vm.prank(admin);
        merchantRegistry.unsuspend(merchantId);

        uint256 escrowId = _route(reviewId);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Holding));
    }

    // =========================================================================
    // 9. Used escrowId blocks second review
    // =========================================================================

    function test_Integration_UsedEscrowId_BlocksSecondReview() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);

        vm.prank(buyer);
        reviewRegistry.publishReviewWithEscrowProof(buyerAgentId, CONTENT_HASH, escrowId);

        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.EscrowMismatch.selector, escrowId));
        vm.prank(buyer);
        reviewRegistry.publishReviewWithEscrowProof(buyerAgentId, CONTENT_HASH, escrowId);
    }

    // =========================================================================
    // 10. EscrowProof access control — wrong agent blocked
    // =========================================================================

    function test_Integration_EscrowProof_WrongAgentId_Reverts() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);

        address thirdParty = makeAddr("thirdParty");
        uint256 thirdPartyAgentId = mintAgent(thirdParty);

        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.EscrowMismatch.selector, escrowId));
        vm.prank(thirdParty);
        reviewRegistry.publishReviewWithEscrowProof(thirdPartyAgentId, CONTENT_HASH, escrowId);
    }

    function test_Integration_EscrowProof_Impersonation_Reverts() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);

        address thirdParty = makeAddr("thirdParty");

        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.CallerNotAgentOwner.selector, buyerAgentId, thirdParty));
        vm.prank(thirdParty);
        reviewRegistry.publishReviewWithEscrowProof(buyerAgentId, CONTENT_HASH, escrowId);
    }

    // =========================================================================
    // 11. Multi-agent, multi-merchant isolation
    // =========================================================================

    function test_Integration_MultiAgent_CommissionsIsolated() public {
        // Reviewer1 + buyer1 (shared fixtures).
        uint256 reviewId1 = _oracleReview(1);
        uint256 escrowId1 = _route(reviewId1);

        // Reviewer2 + buyer2 (local actors).
        uint256 reviewer2Pk = 0xB22CE;
        address reviewer2Owner = vm.addr(reviewer2Pk);
        uint256 reviewer2AgentId = mintAgent(reviewer2Owner);
        (address buyer2, uint256 buyer2Pk) = makeAddrAndKey("buyer2");
        uint256 buyer2AgentId = mintAgent(buyer2);

        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig2 = EIP712Helpers.signReviewCommitment(
            vm,
            reviewer2Pk,
            address(reviewRegistry),
            block.chainid,
            reviewer2AgentId,
            merchantId,
            PRODUCT_ID,
            CONTENT_HASH,
            1,
            expiry
        );
        vm.prank(oracle);
        uint256 reviewId2 = reviewRegistry.publishReview(
            reviewer2AgentId,
            merchantId,
            PRODUCT_ID,
            CONTENT_HASH,
            IReviewRegistry.ProofType.AdminApproved,
            IReviewRegistry.Sig({nonce: 1, expiry: expiry, agentSignature: sig2})
        );

        usdc.mint(buyer2, GROSS);
        ISplitRouter.RouteParams memory rp2 = ISplitRouter.RouteParams({
            buyerAgentId: buyer2AgentId,
            reviewId: reviewId2,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: GROSS,
            buyer: buyer2,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: CASHBACK_BPS
        });
        ISplitRouter.ERC3009Params memory ep2 = signRouteAuth(rp2, buyer2Pk);
        vm.prank(facilitator);
        uint256 escrowId2 = splitRouter.route(rp2, ep2);

        // Settle escrow1 only.
        _settleHeldBack(escrowId1);

        // reviewer1 total = reviewer_net(1e6) + held_back(5e6) = 6e6
        assertEq(usdc.balanceOf(reviewerOwner), 6e6);
        // reviewer2 got reviewer_net at route2 time but escrow2 not yet settled
        assertEq(usdc.balanceOf(reviewer2Owner), REVIEWER_NET_AMT);
        assertEq(uint8(escrow.getEscrow(escrowId2).state), uint8(ICommissionEscrow.EscrowState.Holding));
        assertEq(escrow.getEscrow(escrowId2).heldBackAmt, uint128(HELD_BACK_AMT));
    }

    function test_Integration_MultiMerchant_PaymentsIsolated() public {
        // Merchant2 with commission=5%, cashback=0%.
        address merchantOwner2 = makeAddr("merchantOwner2");
        uint256 merchantId2 = mintMerchant(merchantOwner2);
        bytes32 productId2 = keccak256("product-beta");
        addProduct(merchantId2, merchantOwner2, productId2, 500, 0);

        // Review + route for merchant1.
        uint256 reviewId1 = _oracleReview(1);
        _route(reviewId1);

        // Review for merchant2's product (same reviewer, nonce=2).
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig2 = EIP712Helpers.signReviewCommitment(
            vm,
            reviewerPk,
            address(reviewRegistry),
            block.chainid,
            reviewerAgentId,
            merchantId2,
            productId2,
            CONTENT_HASH,
            2,
            expiry
        );
        vm.prank(oracle);
        uint256 reviewId2 = reviewRegistry.publishReview(
            reviewerAgentId,
            merchantId2,
            productId2,
            CONTENT_HASH,
            IReviewRegistry.ProofType.AdminApproved,
            IReviewRegistry.Sig({nonce: 2, expiry: expiry, agentSignature: sig2})
        );
        usdc.mint(buyer, GROSS);
        ISplitRouter.RouteParams memory rp2 = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId2,
            merchantId: merchantId2,
            productId: productId2,
            grossAmount: GROSS,
            buyer: buyer,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: 0
        });
        ISplitRouter.ERC3009Params memory ep2 = _erc3009Params(rp2);
        vm.prank(facilitator);
        splitRouter.route(rp2, ep2);

        // merchant1: 88e6 (10% commission, 4% cashback (not deducted), 2% fee).
        // merchant2: 93e6 (5% commission, 0% cashback, 2% fee).
        assertEq(usdc.balanceOf(merchantOwner), 88e6);
        assertEq(usdc.balanceOf(merchantOwner2), 93e6);
        assertEq(escrow.totalEscrows(), 2);
        // heldBack = base × (1 − multiplier) = base × 50%
        // escrow1: 10e6 × 50% = 5e6
        // escrow2:  5e6 × 50% = 2.5e6
        assertEq(escrow.getEscrow(1).heldBackAmt, uint128(HELD_BACK_AMT));
        assertEq(escrow.getEscrow(2).heldBackAmt, uint128(2_500_000));
    }

    // =========================================================================
    // 12. Merchant wallet fallback — pays NFT owner when wallet not set
    // =========================================================================

    function test_Integration_MerchantWalletFallback_PaysNFTOwner() public {
        assertEq(agentRegistry.getAgentWallet(merchantId), address(0));

        uint256 reviewId1 = _oracleReview(1);
        _route(reviewId1);
        assertEq(usdc.balanceOf(merchantOwner), 88e6);

        address merchantWallet = makeAddr("merchantWallet");
        agentRegistry.setWallet(merchantId, merchantWallet);

        uint256 reviewId2 = _oracleReview(2);
        _route(reviewId2);

        assertEq(usdc.balanceOf(merchantWallet), 88e6);
        assertEq(usdc.balanceOf(merchantOwner), 88e6); // unchanged (still got first route)
    }

    // =========================================================================
    // 13. Reviewer wallet fallback — reviewer gets funds at route + settle time
    // =========================================================================

    function test_Integration_ReviewerWalletFallback_PaysNFTOwner() public {
        assertEq(agentRegistry.getAgentWallet(reviewerAgentId), address(0));

        uint256 reviewId1 = _oracleReview(1);
        uint256 escrowId1 = _route(reviewId1);
        // reviewer_net goes to reviewerOwner (ownerOf fallback).
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET_AMT);
        _settleHeldBack(escrowId1);
        // held_back also goes to reviewerOwner → total = reviewer_net + held_back = 6e6.
        assertEq(usdc.balanceOf(reviewerOwner), 6e6);

        // Set explicit reviewer wallet; subsequent route + settle routes to it instead.
        address reviewerWallet = makeAddr("reviewerWallet");
        agentRegistry.setWallet(reviewerAgentId, reviewerWallet);

        uint256 reviewId2 = _oracleReview(2);
        uint256 escrowId2 = _route(reviewId2);
        _settleHeldBack(escrowId2);

        assertEq(usdc.balanceOf(reviewerWallet), 6e6);
        assertEq(usdc.balanceOf(reviewerOwner), 6e6); // unchanged
    }

    // =========================================================================
    // 14. Paused escrow — blocks deposit, oracle ops
    // =========================================================================

    function test_Integration_PausedEscrow_BlocksDeposit() public {
        uint256 reviewId = _oracleReview(1);

        vm.prank(admin);
        escrow.pause();

        usdc.mint(buyer, GROSS);
        ISplitRouter.RouteParams memory rp = _routeParams(reviewId);
        ISplitRouter.ERC3009Params memory ep = _erc3009Params(rp);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(facilitator);
        splitRouter.route(rp, ep);
    }

    function test_Integration_PausedEscrow_BlocksOracleOps() public {
        uint256 reviewId = _oracleReview(1);
        uint256 escrowId = _route(reviewId);

        vm.prank(admin);
        escrow.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(oracle);
        escrow.settleHeldBack(escrowId, 100);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(oracle);
        escrow.releaseCashback(escrowId);

        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Holding));
        assertFalse(escrow.getEscrow(escrowId).cashbackReleased);
    }

    function test_Integration_UnpausedEscrow_ResumesNormally() public {
        uint256 reviewId = _oracleReview(1);

        vm.prank(admin);
        escrow.pause();

        usdc.mint(buyer, GROSS);
        ISplitRouter.RouteParams memory rp = _routeParams(reviewId);
        ISplitRouter.ERC3009Params memory ep = _erc3009Params(rp);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(facilitator);
        splitRouter.route(rp, ep);

        vm.prank(admin);
        escrow.unpause();

        uint256 escrowId = _route(reviewId);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Holding));
    }

    // =========================================================================
    // 15. Platform fee = 0 — zero treasury transfer
    // =========================================================================

    function test_Integration_ZeroPlatformFee_NoTreasuryAmount() public {
        vm.prank(admin);
        splitRouter.setPlatformFeeBps(0);

        uint256 reviewId = _oracleReview(1);
        _route(reviewId);

        assertEq(usdc.balanceOf(treasury), 0);
        // base_commission = 10e6, heldBack = 5e6, cashback = 4e6
        // merchant = 100 - 10 - 0 = 90e6 (cashback not deducted from merchant)
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK_AMT + CASHBACK_AMT);
        assertEq(usdc.balanceOf(merchantOwner), 90e6);
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET_AMT);
    }

    // =========================================================================
    // No-referral purchase end to end (#23)
    // =========================================================================

    function test_Integration_NoReferral_RoutesAndSettles() public {
        uint256 escrowId = _route(0);
        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.reviewerAgentId, ProtocolConstants.SENTINEL_REVIEWER);
        assertEq(r.heldBackAmt, 0);
        assertEq(r.cashbackAmt, 0);

        vm.prank(oracle);
        escrow.settleHeldBack(escrowId, 100); // must not resolve the sentinel reviewer
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Settled));
    }
}
