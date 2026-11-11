// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {MockAgentRegistry} from "../helpers/MockAgentRegistry.sol";
import {SplitRouter} from "../../src/SplitRouter.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";
import {IProductRegistry} from "../../src/interfaces/IProductRegistry.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";
import {ProtocolConstants} from "../../src/libraries/ProtocolConstants.sol";
import {FailingERC20} from "../helpers/FailingERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SplitRouterTest is MockFixture {
    SplitRouter internal router;

    address internal buyer;
    uint256 internal buyerPk;
    address internal merchantOwner = makeAddr("merchant");
    address internal reviewer = makeAddr("reviewer");
    uint256 internal buyerAgentId;
    uint256 internal merchantId;
    uint256 internal reviewerAgentId;
    uint256 internal reviewId;

    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");
    uint256 internal constant GROSS = 100e6; // 100 USDC

    uint16 internal constant COMMISSION_BPS = 1000; //  10%  → base 10e6
    uint16 internal constant CASHBACK_BPS = 4000; // 40% OF COMMISSION → 4e6 (== old 4% of gross; at 40% cap)
    uint16 internal constant PLATFORM_FEE_BPS = 200; //   2%  →      2e6
    uint16 internal constant COMMISSION_MULTIPLIER_BPS = 7000; // 70% immediate

    uint256 internal constant COMMISSION_AMT = 10e6; // base commission
    uint256 internal constant IMMEDIATE_COMMISSION = 7e6; // 10e6 × 70%
    uint256 internal constant HELD_BACK = 3e6; // 10e6 × 30%
    uint256 internal constant CASHBACK_AMT = 4e6; // 4% of 100e6
    uint256 internal constant REVIEWER_NET = 3e6; // IMMEDIATE_COMMISSION - CASHBACK_AMT = 7e6 - 4e6
    uint256 internal constant PLATFORM_FEE_AMT = 2e6;
    uint256 internal constant MERCHANT_AMT = 88e6; // 100 - 10 - 2 (cashback not deducted from merchant)

    function setUp() public override {
        super.setUp();
        // route() pulls via a signed ERC-3009 authorization, so the buyer needs a key (REF-269).
        // makeAddrAndKey yields the same address makeAddr did for this label.
        (buyer, buyerPk) = makeAddrAndKey("buyer");
        router = new SplitRouter(address(par), admin, address(usdc), PLATFORM_FEE_BPS);
        vm.prank(admin);
        router.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);

        buyerAgentId = agentRegistry.mint(buyer);
        merchantId = agentRegistry.mint(merchantOwner);
        reviewerAgentId = agentRegistry.mint(reviewer);
        merchantRegistry.setActiveRaw(merchantId, true);

        // Commission is read live from ProductRegistry at settle (REF-159).
        setupProduct(merchantId, PRODUCT_ID, COMMISSION_BPS, 0);

        // Seed ReviewRegistry mock with a review for reviewerAgentId.
        reviewId = 1;
        reviewRegistry.setReviewRaw(
            reviewId,
            IReviewRegistry.Review({
                agentId: reviewerAgentId,
                merchantId: merchantId,
                productId: PRODUCT_ID,
                contentHash: bytes32(0),
                proofType: IReviewRegistry.ProofType.AdminApproved,
                timestamp: uint40(block.timestamp),
                editedAt: 0
            })
        );

        usdc.mint(buyer, GROSS);
    }

    function _routeParams() internal view returns (ISplitRouter.RouteParams memory) {
        return ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: GROSS,
            buyer: buyer,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: CASHBACK_BPS
        });
    }

    function _erc3009Params(ISplitRouter.RouteParams memory rp) internal returns (ISplitRouter.ERC3009Params memory) {
        return signRouteAuth(address(router), rp, buyerPk);
    }

    function _route() internal returns (uint256 escrowId) {
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep = _erc3009Params(rp);
        vm.prank(facilitator);
        escrowId = router.route(rp, ep);
    }

    // =========================================================================
    // route — happy path
    // =========================================================================

    function test_Route_SplitsCorrectly() public {
        _route();
        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET);
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK + CASHBACK_AMT);
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT);
        assertEq(usdc.balanceOf(buyer), 0);
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT);
    }

    function test_Route_ImmediateCommissionSentToReviewer() public {
        _route();
        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET);
    }

    // REF-159: a merchant raising commission after authorization so that commission + platformFee
    // exceeds 100% must NOT revert settlement. The router clamps the live commission to
    // BPS_DENOM - platformFee, so the split always executes.
    function test_Route_HighLiveCommission_ClampedNotReverted() public {
        productRegistry.setCommission(merchantId, PRODUCT_ID, 9900); // 9900 + 200 fee = 10100 > 10000
        _route(); // must not revert
        // Clamp caps commission at 10000 - 200 = 9800 → merchant net floored to exactly 0.
        assertEq(usdc.balanceOf(merchantOwner), 0, "merchant net floored to 0 by clamp");
        assertEq(usdc.balanceOf(address(router)), 0, "no funds stranded in router");
        assertEq(
            usdc.balanceOf(reviewer) + usdc.balanceOf(address(escrow)) + usdc.balanceOf(treasury)
                + usdc.balanceOf(merchantOwner),
            GROSS,
            "conservation"
        );
    }

    function test_Route_EscrowReceivesHeldBackPlusCashback() public {
        _route();
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK + CASHBACK_AMT);
    }

    function test_Route_TransfersPlatformFeeToTreasury() public {
        _route();
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT);
    }

    function test_Route_CashbackHeldInEscrow_NotSentToBuyer() public {
        _route();
        assertEq(usdc.balanceOf(buyer), 0);
    }

    function test_Route_TransfersMerchantAmtToMerchantWallet() public {
        _route();
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT);
    }

    function test_Route_CallsEscrowDeposit_WithCorrectArgs() public {
        uint256 escrowId = _route();

        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.reviewerAgentId, reviewerAgentId);
        assertEq(r.buyerAgentId, buyerAgentId);
        assertEq(r.merchantId, merchantId);
        assertEq(r.productId, PRODUCT_ID);
        assertEq(r.heldBackAmt, HELD_BACK);
        assertEq(r.cashbackAmt, CASHBACK_AMT);
        assertEq(r.originalPurchaseAmt, GROSS);
    }

    /// @dev Refactor guard (REF-213 Task 1): route() must produce identical splits after the
    ///      _validate / _settleAndDeposit extraction. Values are the existing fixture's
    ///      pre-refactor outputs for GROSS = 100e6.
    function test_Route_SplitValues_UnchangedByRefactor() public {
        uint256 escrowId = _route();
        ICommissionEscrow.EscrowRecord memory rec = escrow.getEscrow(escrowId);

        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET, "reviewer immediate net"); // 3e6
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT, "treasury fee"); // 2e6
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT, "merchant net"); // 88e6
        assertEq(uint256(rec.heldBackAmt), HELD_BACK, "escrow held-back"); // 3e6
        assertEq(uint256(rec.cashbackAmt), CASHBACK_AMT, "escrow cashback"); // 4e6
        assertEq(usdc.balanceOf(address(router)), 0, "router must retain nothing");
    }

    function test_Route_EmitsPaymentRouted() public {
        vm.expectEmit(true, true, true, true);
        emit ISplitRouter.PaymentRouted(
            1,
            buyerAgentId,
            reviewId,
            buyer,
            merchantId,
            PRODUCT_ID,
            GROSS,
            REVIEWER_NET,
            HELD_BACK,
            PLATFORM_FEE_AMT,
            CASHBACK_AMT,
            MERCHANT_AMT
        );
        _route();
    }

    function test_Route_ReturnsEscrowId() public {
        uint256 escrowId = _route();
        assertEq(escrowId, 1);
    }

    // =========================================================================
    // Agent-less buyer + buyerWallet (REF-161 / C-3)
    // =========================================================================

    function test_Route_StoresBuyerWallet_NormalAgent() public {
        uint256 escrowId = _route();
        assertEq(escrow.getEscrow(escrowId).buyerWallet, buyer);
    }

    function test_Route_Sentinel_SettlesWithoutBuyerNFT() public {
        // No NFT is minted for SENTINEL_BUYER; route() must NOT revert InvalidBuyerAgent.
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.buyerAgentId = router.SENTINEL_BUYER();
        vm.prank(facilitator);
        uint256 escrowId = router.route(rp, _erc3009Params(rp));

        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.buyerAgentId, router.SENTINEL_BUYER());
        // Paying wallet is still recorded on the escrow.
        assertEq(r.buyerWallet, buyer);
    }

    function test_Route_Sentinel_ReviewerCommissionAndHeldBackUnaffected() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.buyerAgentId = router.SENTINEL_BUYER();
        vm.prank(facilitator);
        uint256 escrowId = router.route(rp, _erc3009Params(rp));

        // Reviewer commission split is identical to the normal-agent case.
        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET);
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK + CASHBACK_AMT);
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT);
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT);

        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.heldBackAmt, HELD_BACK);
        assertEq(r.cashbackAmt, CASHBACK_AMT);
    }

    function test_Route_SplitSumsToGross_NoRemainder() public {
        _route();
        assertEq(usdc.balanceOf(address(router)), 0);
        // All GROSS distributed: reviewer + escrow + treasury + merchant = GROSS
        assertEq(
            usdc.balanceOf(reviewer) + usdc.balanceOf(address(escrow)) + usdc.balanceOf(treasury)
                + usdc.balanceOf(merchantOwner),
            GROSS
        );
    }

    function test_Route_ImmediateCommissionPlusHeldBackEqualsBaseCommission() public {
        uint256 escrowId = _route();
        // reviewer gets reviewerImmediateNet = immediateCommission - cashback
        assertEq(usdc.balanceOf(reviewer) + CASHBACK_AMT + escrow.getEscrow(escrowId).heldBackAmt, COMMISSION_AMT);
    }

    function test_Route_ZeroCashback_NoCashbackTransfer() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.lockedCashbackBps = 0;
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));
        assertEq(usdc.balanceOf(buyer), 0);
    }

    function test_Route_ZeroPlatformFee_NoTreasuryTransfer() public {
        vm.prank(admin);
        router.setPlatformFeeBps(0);
        _route();
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_Route_MerchantWallet_FallsBackToNFTOwner_WhenGetAgentWalletReturnsZero() public {
        // No wallet set — getAgentWallet returns 0 → fallback to ownerOf(merchantId)
        _route();
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT);
    }

    function test_Route_MerchantWallet_UsesSetWallet_WhenNonZero() public {
        address paymentWallet = makeAddr("paymentWallet");
        agentRegistry.setWallet(merchantId, paymentWallet);

        _route();
        assertEq(usdc.balanceOf(paymentWallet), MERCHANT_AMT);
        assertEq(usdc.balanceOf(merchantOwner), 0);
    }

    // =========================================================================
    // route — multiplier split cases
    // =========================================================================

    function test_Route_SplitAt4000_Multiplier() public {
        // 40% immediate, 60% held_back — minimum valid multiplier
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.commissionMultiplierBps = 4000;
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));

        // immediate = 10e6 * 40% = 4e6, cashback = 4e6, reviewerNet = 0, held_back = 6e6
        assertEq(usdc.balanceOf(reviewer), 0);
        assertEq(usdc.balanceOf(address(escrow)), 6e6 + CASHBACK_AMT);
    }

    function test_Route_SplitAt10000_Multiplier() public {
        // 100% immediate, 0 held_back — maximum valid multiplier
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.commissionMultiplierBps = 10000;
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));

        // immediate = 10e6, cashback = 4e6, reviewerNet = 6e6, held_back = 0
        assertEq(usdc.balanceOf(reviewer), 6e6);
        assertEq(usdc.balanceOf(address(escrow)), CASHBACK_AMT); // only cashback
    }

    function test_Route_SplitAt7440_WorkedExample() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.commissionMultiplierBps = 7440;
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));

        // base = 10e6, immediate = 10e6 * 7440 / 10000 = 7440000, held = 2560000
        // cashback = 4e6, reviewerNet = 7440000 - 4000000 = 3440000
        assertEq(usdc.balanceOf(reviewer), 3_440_000);
        assertEq(usdc.balanceOf(address(escrow)), 2_560_000 + CASHBACK_AMT);
        // reviewer_net + cashback + held_back == base_commission
        assertEq(usdc.balanceOf(reviewer) + CASHBACK_AMT + 2_560_000, COMMISSION_AMT);
    }

    // =========================================================================
    // route — access control
    // =========================================================================

    function test_Route_Revert_NotFacilitator() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        ISplitRouter.RouteParams memory rp = _routeParams();
        router.route(rp, _erc3009Params(rp));
    }

    // =========================================================================
    // route — input validation
    // =========================================================================

    function test_Route_Revert_ZeroAmount() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.grossAmount = 0;
        vm.prank(facilitator);
        vm.expectRevert(ISplitRouter.ZeroAmount.selector);
        router.route(rp, _erc3009Params(rp));
    }

    function test_Route_Revert_ZeroBuyerAddress() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.buyer = address(0);
        vm.prank(facilitator);
        vm.expectRevert(ISplitRouter.ZeroBuyerAddress.selector);
        router.route(rp, _erc3009Params(rp));
    }

    function test_Route_Revert_InvalidBuyerAgent_WrongOwner() public {
        address wrongBuyer = makeAddr("wrongBuyer");
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.buyer = wrongBuyer;
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.InvalidBuyerAgent.selector, buyerAgentId, wrongBuyer));
        router.route(rp, _erc3009Params(rp));
    }

    /// @dev A delegated wallet can buy under its agent id without the SENTINEL_BUYER + bind detour.
    function test_Route_AgentWalletBuyer_Accepted() public {
        (address delegate, uint256 delegatePk) = makeAddrAndKey("delegate");
        agentRegistry.setWallet(buyerAgentId, delegate);
        usdc.mint(delegate, GROSS);

        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.buyer = delegate;
        ISplitRouter.ERC3009Params memory auth = signRouteAuth(address(router), rp, delegatePk);
        vm.prank(facilitator);
        uint256 escrowId = router.route(rp, auth);

        assertEq(escrow.getEscrow(escrowId).buyerAgentId, buyerAgentId);
        assertEq(escrow.getEscrow(escrowId).buyerWallet, delegate);
    }

    function test_Route_OwnerBuyer_SkipsAgentWalletRead() public {
        vm.expectCall(address(agentRegistry), abi.encodeCall(agentRegistry.getAgentWallet, (buyerAgentId)), 0);
        _route();
    }

    function test_Route_DoesNotReadFullProduct() public {
        vm.expectCall(address(productRegistry), abi.encodeCall(productRegistry.getProduct, (merchantId, PRODUCT_ID)), 0);
        _route();
    }

    function test_Route_Revert_MerchantNotActive() public {
        merchantRegistry.setActiveRaw(merchantId, false);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.MerchantNotActive.selector, merchantId));
        ISplitRouter.RouteParams memory rp = _routeParams();
        router.route(rp, _erc3009Params(rp));
    }

    // REF-160: a deactivated product must be rejected on-chain at settle (the edge flow removes
    // the backend product-active gate).
    function test_Route_Revert_ProductNotActive() public {
        productRegistry.setProductActive(merchantId, PRODUCT_ID, false);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ProductNotActive.selector, merchantId, PRODUCT_ID));
        ISplitRouter.RouteParams memory rp = _routeParams();
        router.route(rp, _erc3009Params(rp));
    }

    // NOTE (REF-159): route() no longer propagates RatesExceedTotal — the router clamps live
    // commission to (10000 - platformFee), so commission + fee can never exceed 100%. The clamp
    // behavior is covered by test_Route_HighLiveCommission_ClampedNotReverted; the SplitMath
    // RatesExceedTotal guard itself is covered directly in SplitMathTest / SplitMathFuzz.

    function test_Route_Revert_MultiplierBelowMinimum() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.commissionMultiplierBps = 3999;
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.MultiplierOutOfRange.selector, uint16(3999)));
        router.route(rp, _erc3009Params(rp));
    }

    function test_Route_Revert_MultiplierAboveMaximum() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.commissionMultiplierBps = 10001;
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.MultiplierOutOfRange.selector, uint16(10001)));
        router.route(rp, _erc3009Params(rp));
    }

    function test_Route_Multiplier_Boundary_4000_Valid() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.commissionMultiplierBps = 4000;
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp)); // must not revert
    }

    function test_Route_Multiplier_Boundary_10000_Valid() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.commissionMultiplierBps = 10000;
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp)); // must not revert
    }

    /// @dev No referral on a commissioned product: settles, commission stays with the merchant.
    function test_Route_NoReferral_CommissionedProduct_SettlesWithZeroCommission() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.reviewId = 0; // product commission is COMMISSION_BPS (1000) from setUp
        vm.prank(facilitator);
        uint256 escrowId = router.route(rp, _erc3009Params(rp));

        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.heldBackAmt, 0);
        assertEq(r.cashbackAmt, 0);
        assertEq(usdc.balanceOf(reviewer), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT);
        assertEq(usdc.balanceOf(merchantOwner), GROSS - PLATFORM_FEE_AMT);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    /// @dev commission=1 bps on 10_000 used to round to immediate=0, heldBack=1; with no
    ///      referral the commission is zeroed before the split, so nothing reaches escrow.
    function test_Route_NoReferral_RoundingEdgeCase_SettlesWithZeroCommission() public {
        productRegistry.setCommission(merchantId, PRODUCT_ID, 1);
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.reviewId = 0;
        rp.grossAmount = 10_000;
        rp.commissionMultiplierBps = 4000;
        usdc.mint(buyer, 10_000);
        vm.prank(facilitator);
        uint256 escrowId = router.route(rp, _erc3009Params(rp));

        uint256 fee = 10_000 * uint256(PLATFORM_FEE_BPS) / 10_000;
        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.heldBackAmt, 0);
        assertEq(r.cashbackAmt, 0);
        assertEq(usdc.balanceOf(reviewer), 0);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(merchantOwner), 10_000 - fee);
    }

    function test_Route_NoReferral_RecordsSentinelReviewer() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.reviewId = 0;
        vm.prank(facilitator);
        uint256 escrowId = router.route(rp, _erc3009Params(rp));

        uint256 recorded = escrow.getEscrow(escrowId).reviewerAgentId;
        assertEq(recorded, ProtocolConstants.SENTINEL_REVIEWER);
        assertTrue(recorded != 0, "agent 0 is a real identity");
    }

    // =========================================================================
    // recoverUSDC
    // =========================================================================

    function test_RecoverUSDC_AdminCanRecover() public {
        usdc.mint(address(router), GROSS);
        address recipient = makeAddr("recipient");
        vm.prank(admin);
        router.recoverUSDC(recipient, GROSS, bytes32(0));
        assertEq(usdc.balanceOf(recipient), GROSS);
    }

    function test_RecoverUSDC_TransfersExactAmount() public {
        usdc.mint(address(router), GROSS);
        address recipient = makeAddr("recipient");
        uint256 amount = 42e6;
        vm.prank(admin);
        router.recoverUSDC(recipient, amount, bytes32(0));
        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(router)), GROSS - amount);
    }

    function test_RecoverUSDC_Revert_NotAdmin() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        router.recoverUSDC(makeAddr("recipient"), GROSS, bytes32(0));
    }

    function test_RecoverUSDC_Revert_ZeroRecipientAddress() public {
        vm.prank(admin);
        vm.expectRevert(ISplitRouter.ZeroRecipientAddress.selector);
        router.recoverUSDC(address(0), GROSS, bytes32(0));
    }

    // Audit MPP-02 (Low, ACCEPTED): recoverUSDC can seize pooled pre-settlement buyer principal
    // on the MPP charge rail. This event is what makes that seizure monitorable off-chain.
    function test_RecoverUSDC_EmitsUSDCRecovered() public {
        usdc.mint(address(router), GROSS);
        address recipient = makeAddr("recipient");
        vm.expectEmit(true, false, false, true);
        emit ISplitRouter.USDCRecovered(recipient, GROSS);
        vm.prank(admin);
        router.recoverUSDC(recipient, GROSS, bytes32(0));
    }

    // =========================================================================
    // setPlatformFeeBps
    // =========================================================================

    function test_SetPlatformFeeBps_UpdatesValue() public {
        vm.prank(admin);
        router.setPlatformFeeBps(300);
        assertEq(router.platformFeeBps(), 300);
    }

    function test_SetPlatformFeeBps_EmitsPlatformFeeUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit ISplitRouter.PlatformFeeUpdated(PLATFORM_FEE_BPS, 300);
        vm.prank(admin);
        router.setPlatformFeeBps(300);
    }

    function test_SetPlatformFeeBps_Revert_NotAdmin() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        router.setPlatformFeeBps(300);
    }

    function test_SetPlatformFeeBps_Revert_FeeTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.FeeTooHigh.selector, uint16(2001)));
        router.setPlatformFeeBps(2001);
    }

    function test_SetPlatformFeeBps_MaxValue_2000_Allowed() public {
        assertEq(router.MAX_PLATFORM_FEE_BPS(), 2000);
        vm.prank(admin);
        router.setPlatformFeeBps(2000);
        assertEq(router.platformFeeBps(), 2000);
    }

    function test_SetPlatformFeeBps_Zero_Allowed() public {
        vm.prank(admin);
        router.setPlatformFeeBps(0);
        assertEq(router.platformFeeBps(), 0);
    }

    // =========================================================================
    // treasury resolution (PAR is the single source of truth)
    // =========================================================================

    // The router holds no treasury of its own: it resolves PAR's TREASURY key on every
    // route(). Replaces the old setTreasury/treasury() tests — setter, getter,
    // TreasuryUpdated and ZeroTreasuryAddress were all removed, and PAR now owns that
    // surface (ProtocolAddressRegistryTest covers Revert_NotOwner / Revert_ZeroAddress).
    // This asserts what those tests could not: a PAR change takes effect live on the very
    // next route, with no redeploy and no per-contract update.
    function test_Route_PaysPlatformFeeToTreasuryResolvedFromPAR() public {
        address newTreasury = makeAddr("rotatedTreasury");
        bytes32 key = par.TREASURY();
        vm.startPrank(admin);
        par.setAddress(key, newTreasury);
        vm.stopPrank();
        par.executeUpdate(key);

        _route();

        assertEq(usdc.balanceOf(newTreasury), PLATFORM_FEE_AMT, "platform fee must follow the PAR update");
        assertEq(usdc.balanceOf(treasury), 0, "the pre-rotation treasury must receive nothing");
    }

    // =========================================================================
    // view functions
    // =========================================================================

    function test_PlatformFeeBps_ReturnsConstructorValue() public view {
        assertEq(router.platformFeeBps(), PLATFORM_FEE_BPS);
    }

    function test_Usdc_ReturnsConfiguredAddress() public view {
        assertEq(router.usdc(), address(usdc));
    }

    // =========================================================================
    // constructor validation
    // =========================================================================

    function test_Constructor_Revert_FeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.FeeTooHigh.selector, uint16(2001)));
        new SplitRouter(address(par), admin, address(usdc), 2001);
    }

    function test_Constructor_EmitsInitialFeeAndCashbackCap() public {
        vm.expectEmit(false, false, false, true);
        emit ISplitRouter.PlatformFeeUpdated(0, 150);
        vm.expectEmit(false, false, false, true);
        emit ISplitRouter.MaxCashbackBpsUpdated(0, SplitMath.MULTIPLIER_MIN);
        new SplitRouter(address(par), admin, address(usdc), 150);
    }

    // =========================================================================
    // M-01: zero-transfer on mainnet USDC (zero platformFee/merchantAmt must not transfer)
    // =========================================================================

    /// @dev With platformFeeBps=0, platformFeeAmt=0; must not call transfer(treasury, 0).
    ///      Mock transfer(treasury, 0) → revert to simulate mainnet USDC behaviour.
    function test_Route_ZeroPlatformFee_NoTransferToTreasury() public {
        SplitRouter zeroFeeRouter = new SplitRouter(address(par), admin, address(usdc), 0);
        vm.prank(admin);
        zeroFeeRouter.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);

        usdc.mint(buyer, GROSS); // extra mint; buyer already has GROSS from setUp

        // Mock: transfer(treasury, 0) reverts.
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), treasury, uint256(0)),
            "ERC20: zero transfer"
        );

        // route must succeed without transferring 0 to treasury.
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep = signRouteAuth(address(zeroFeeRouter), rp, buyerPk);
        vm.prank(facilitator);
        zeroFeeRouter.route(rp, ep);

        // Treasury received nothing (platformFee=0).
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // =========================================================================
    // _safeTransfer failure
    // =========================================================================

    function test_Route_Revert_TransferFailed_WhenUsdcReturnsFalse() public {
        FailingERC20 failingUsdc = new FailingERC20();
        SplitRouter failRouter = new SplitRouter(address(par), admin, address(failingUsdc), PLATFORM_FEE_BPS);
        vm.prank(admin);
        failRouter.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);

        // First transfer is reviewerImmediateNet to reviewer wallet.
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep = signRouteAuth(address(failRouter), rp, buyerPk);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(failingUsdc)));
        failRouter.route(rp, ep);
    }

    // =========================================================================
    // admin cashback cap
    // =========================================================================

    address internal stranger = makeAddr("stranger");

    function _routeWith(uint16 commissionBps, uint16 cashbackBps, uint16 multiplierBps, uint256 gross) internal {
        usdc.mint(buyer, gross);
        productRegistry.setCommission(merchantId, PRODUCT_ID, commissionBps);
        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.lockedCashbackBps = cashbackBps;
        rp.commissionMultiplierBps = multiplierBps;
        rp.grossAmount = gross;
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));
    }

    function _routeParamsWith(uint16 commissionBps, uint16 cashbackBps, uint16 multiplierBps, uint256 gross)
        internal
        returns (ISplitRouter.RouteParams memory rp)
    {
        productRegistry.setCommission(merchantId, PRODUCT_ID, commissionBps);
        rp = _routeParams();
        rp.lockedCashbackBps = cashbackBps;
        rp.commissionMultiplierBps = multiplierBps;
        rp.grossAmount = gross;
    }

    function test_route_paysReviewerImmediateNet_merchantExcludesCashback() public {
        // commission 10% (100), multiplier 100% (immediate 100), cashback 40% OF COMMISSION (40), fee 0, gross 1000.
        vm.prank(admin);
        router.setPlatformFeeBps(0);
        _routeWith(1000, 4000, 10_000, 1000);
        assertEq(usdc.balanceOf(reviewer), 60); // 100 − 40
        assertEq(usdc.balanceOf(merchantOwner), 900); // 1000 − 100 − 0 (no cashback deduction)
        assertEq(usdc.balanceOf(address(escrow)), 40); // heldBack 0 + cashback 40
    }

    function test_route_revertsWhenCashbackExceedsCap() public {
        // default admin cap = 4000 (40% of commission). cashback 4010 bps of commission exceeds it → reverts.
        usdc.mint(buyer, 1000);
        ISplitRouter.RouteParams memory rp = _routeParamsWith(1000, 4010, 4_000, 1000);
        vm.expectRevert(
            abi.encodeWithSelector(
                SplitMath.CashbackExceedsCommissionCap.selector, uint16(4010), uint16(1000), uint16(4_000)
            )
        );
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));
    }

    function test_setMaxCashbackBps_admin_tightensCap() public {
        assertEq(router.maxCashbackBpsOfCommission(), 4_000); // default
        vm.expectRevert(); // non-admin
        vm.prank(stranger);
        router.setMaxCashbackBps(3_000);
        vm.prank(admin);
        router.setMaxCashbackBps(3_000); // 30% of commission
        assertEq(router.maxCashbackBpsOfCommission(), 3_000);
        // cashback 4000 bps of commission (== old 4% of gross at 10% commission) now exceeds the 3000 cap → reverts.
        usdc.mint(buyer, 1000);
        ISplitRouter.RouteParams memory rp = _routeParamsWith(1000, 4000, 10_000, 1000);
        vm.expectRevert(
            abi.encodeWithSelector(
                SplitMath.CashbackExceedsCommissionCap.selector, uint16(4000), uint16(1000), uint16(3_000)
            )
        );
        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));
    }

    function test_setMaxCashbackBps_revertsAboveCeiling() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SplitMath.CapAboveCeiling.selector, uint16(4_001)));
        router.setMaxCashbackBps(4_001);
    }

    /// @dev CommissionEscrow, ReviewRegistry and MerchantRegistry all cache AGENT_REGISTRY as an
    ///      immutable at construction. A router that resolved the same key live would pay the
    ///      reviewer's immediate commission through one registry while the escrow pays the
    ///      held-back remainder for that same agentId through another — one sale, two payees.
    function test_Route_ResolvesAgentRegistryAtConstruction_NotLiveFromPar() public {
        MockAgentRegistry replacement = new MockAgentRegistry();
        address imposterMerchant = makeAddr("imposterMerchant");
        address imposterReviewer = makeAddr("imposterReviewer");

        // Same ids, different owners. Mint order mirrors setUp so buyerAgentId still resolves to
        // `buyer`, keeping _validateEntry's ownerOf check out of the way of what is under test.
        replacement.mint(buyer);
        replacement.mint(imposterMerchant);
        replacement.mint(imposterReviewer);

        // PAR rejects a real re-point (ImmutableKey), so simulate a live read returning the
        // replacement: a router that resolved the key at call time would pick it up.
        vm.mockCall(
            address(par), abi.encodeCall(par.getAddress, (par.AGENT_REGISTRY())), abi.encode(address(replacement))
        );

        ISplitRouter.RouteParams memory p = _routeParams();
        ISplitRouter.ERC3009Params memory auth = signRouteAuth(address(router), p, buyerPk);
        vm.prank(facilitator);
        router.route(p, auth);

        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT, "merchant payout followed the repoint");
        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET, "reviewer payout followed the repoint");
        assertEq(usdc.balanceOf(imposterMerchant), 0, "replacement registry owner was paid");
        assertEq(usdc.balanceOf(imposterReviewer), 0, "replacement registry owner was paid");
    }

    // =========================================================================
    // Attribution scope: review merchant must match; product may differ (#16)
    // =========================================================================

    function _routeWith(ISplitRouter.RouteParams memory rp) internal returns (uint256) {
        ISplitRouter.ERC3009Params memory auth = signRouteAuth(address(router), rp, buyerPk);
        vm.prank(facilitator);
        return router.route(rp, auth);
    }

    function test_Route_Revert_ReviewMerchantMismatch() public {
        uint256 otherMerchant = agentRegistry.mint(makeAddr("otherMerchant"));
        merchantRegistry.setActiveRaw(otherMerchant, true);
        setupProduct(otherMerchant, PRODUCT_ID, COMMISSION_BPS, 0);

        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.merchantId = otherMerchant; // review 1 belongs to `merchantId`
        ISplitRouter.ERC3009Params memory auth = signRouteAuth(address(router), rp, buyerPk);
        vm.prank(facilitator);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitRouter.ReviewMerchantMismatch.selector, reviewId, merchantId, otherMerchant)
        );
        router.route(rp, auth);
    }

    /// @dev Merchant-wide attribution: a review of PRODUCT_ID earns commission on another
    ///      product of the same merchant. Pins that the router does NOT compare product ids.
    function test_Route_CrossProductSameMerchant_PaysReviewer() public {
        bytes32 otherProduct = keccak256("product-beta");
        setupProduct(merchantId, otherProduct, COMMISSION_BPS, 0);

        ISplitRouter.RouteParams memory rp = _routeParams();
        rp.productId = otherProduct;
        uint256 escrowId = _routeWith(rp);

        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET);
        assertEq(escrow.getEscrow(escrowId).reviewerAgentId, reviewerAgentId);
        assertEq(escrow.getEscrow(escrowId).productId, otherProduct);
    }

    function test_Route_EscrowProductType_ComesFromRegistry() public {
        IProductRegistry.Product memory p = productRegistry.getProduct(merchantId, PRODUCT_ID);
        p.productType = IProductRegistry.ProductType.OneOff;
        productRegistry.setProductRaw(merchantId, PRODUCT_ID, p);

        ISplitRouter.RouteParams memory rp = _routeParams();
        uint256 escrowId = _routeWith(rp);

        assertEq(escrow.getEscrow(escrowId).productType, uint8(IProductRegistry.ProductType.OneOff));
    }
}
