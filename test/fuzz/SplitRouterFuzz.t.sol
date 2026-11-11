// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {SplitRouter} from "../../src/SplitRouter.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";

contract SplitRouterFuzz is MockFixture {
    SplitRouter internal router;

    address internal buyer;
    uint256 internal buyerPk;
    address internal merchantOwner = makeAddr("merchantOwner");
    address internal reviewer = makeAddr("reviewer");
    uint256 internal buyerAgentId;
    uint256 internal merchantId;
    uint256 internal reviewerAgentId;
    uint256 internal reviewId;

    bytes32 internal constant PRODUCT_ID = keccak256("product-fuzz");

    function setUp() public override {
        super.setUp();
        // route() pulls via a signed ERC-3009 authorization, so the buyer needs a key (REF-269).
        // makeAddrAndKey yields the same address makeAddr did for this label.
        (buyer, buyerPk) = makeAddrAndKey("buyer");
        router = new SplitRouter(address(par), admin, address(usdc), 200);
        vm.prank(admin);
        router.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);

        buyerAgentId = agentRegistry.mint(buyer);
        merchantId = agentRegistry.mint(merchantOwner);
        reviewerAgentId = agentRegistry.mint(reviewer);
        merchantRegistry.setActiveRaw(merchantId, true);

        // Commission is read live from ProductRegistry at settle (REF-159). Register the product;
        // each test sets the fuzzed commission via productRegistry.setCommission before routing.
        setupProduct(merchantId, PRODUCT_ID, 1000, 0);

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
    }

    function _erc3009Params(ISplitRouter.RouteParams memory rp) internal returns (ISplitRouter.ERC3009Params memory) {
        return signRouteAuth(address(router), rp, buyerPk);
    }

    /// @dev Split must always sum to grossAmount — no dust created or lost.
    ///      Precondition: rates are valid (sum ≤ 10000), multiplier in [4000, 10000],
    ///      and grossAmount > 0.
    function testFuzz_SplitSumsToGross(
        uint256 grossAmount,
        uint16 commissionBps,
        uint16 cashbackBps,
        uint16 platformFeeBps,
        uint16 multiplierBps
    ) public {
        platformFeeBps = uint16(bound(platformFeeBps, 0, router.MAX_PLATFORM_FEE_BPS()));
        commissionBps = uint16(bound(commissionBps, 0, 10000 - platformFeeBps));
        cashbackBps = uint16(bound(cashbackBps, 0, 4000)); // of-commission cap (maxCashbackBpsOfCommission default)
        productRegistry.setCommission(merchantId, PRODUCT_ID, commissionBps);
        multiplierBps = uint16(bound(multiplierBps, 4000, 10000));
        grossAmount = bound(grossAmount, 1, type(uint96).max);

        vm.prank(admin);
        router.setPlatformFeeBps(platformFeeBps);
        usdc.mint(buyer, grossAmount);

        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: grossAmount,
            buyer: buyer,
            commissionMultiplierBps: multiplierBps,
            lockedCashbackBps: cashbackBps
        });

        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));

        uint256 distributed = usdc.balanceOf(reviewer) + usdc.balanceOf(address(escrow)) + usdc.balanceOf(treasury)
            + usdc.balanceOf(merchantOwner);
        assertEq(distributed, grossAmount);
    }

    /// @dev immediate_commission + held_back == base_commission for all valid multipliers.
    function testFuzz_ImmediatePlusHeldBackEqualsBase(uint256 grossAmount, uint16 commissionBps, uint16 multiplierBps)
        public
    {
        commissionBps = uint16(bound(commissionBps, 0, 9800)); // leave room for fee+cashback
        multiplierBps = uint16(bound(multiplierBps, 4000, 10000));
        grossAmount = bound(grossAmount, 1, type(uint96).max);

        usdc.mint(buyer, grossAmount);
        productRegistry.setCommission(merchantId, PRODUCT_ID, commissionBps);

        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: grossAmount,
            buyer: buyer,
            commissionMultiplierBps: multiplierBps,
            lockedCashbackBps: 0
        });

        vm.prank(facilitator);
        uint256 escrowId = router.route(rp, _erc3009Params(rp));

        uint256 baseCommission = grossAmount * commissionBps / 10_000;
        uint256 heldBack = escrow.getEscrow(escrowId).heldBackAmt;
        assertEq(usdc.balanceOf(reviewer) + heldBack, baseCommission);
    }

    /// @dev route() must revert RatesExceedTotal iff commissionBps + platformFeeBps > 10000.
    ///      Cashback is no longer part of the RatesExceedTotal check (it has its own cap check).
    /// @dev REF-159: when live commission + platform fee would exceed 100%, route() must NOT
    ///      revert — the router clamps commission to (10000 - fee), so settlement always executes
    ///      and no funds strand. (The RatesExceedTotal guard itself is covered in SplitMathFuzz.)
    function testFuzz_HighCommission_Clamped_NoRevert(uint256 grossAmount, uint16 commissionBps, uint16 platformFeeBps)
        public
    {
        grossAmount = bound(grossAmount, 1, type(uint96).max);
        uint16 maxFee = router.MAX_PLATFORM_FEE_BPS();
        // Force commission + fee > 100% so the clamp engages; with the fee capped this needs
        // commission above 100% - cap.
        commissionBps = uint16(bound(commissionBps, 10000 - uint256(maxFee) + 1, 10000));
        uint16 room = uint16(10000 - commissionBps);
        platformFeeBps = uint16(bound(platformFeeBps, uint256(room) + 1, maxFee));

        vm.prank(admin);
        router.setPlatformFeeBps(platformFeeBps);
        usdc.mint(buyer, grossAmount);
        productRegistry.setCommission(merchantId, PRODUCT_ID, commissionBps);

        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: grossAmount,
            buyer: buyer,
            commissionMultiplierBps: 4000,
            lockedCashbackBps: 0
        });

        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp)); // must NOT revert — clamped

        // Everything distributed (nothing stranded) and value is conserved.
        assertEq(usdc.balanceOf(address(router)), 0, "no funds stranded");
        assertEq(
            usdc.balanceOf(reviewer) + usdc.balanceOf(address(escrow)) + usdc.balanceOf(treasury)
                + usdc.balanceOf(merchantOwner),
            grossAmount,
            "conservation"
        );
    }

    /// @dev route() must revert when commissionMultiplierBps is outside [4000, 10000].
    function testFuzz_MultiplierOutOfRange_Reverts(uint16 multiplierBps) public {
        vm.assume(multiplierBps < 4000 || multiplierBps > 10000);

        usdc.mint(buyer, 100e6);
        productRegistry.setCommission(merchantId, PRODUCT_ID, 1000);

        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: 100e6,
            buyer: buyer,
            commissionMultiplierBps: multiplierBps,
            lockedCashbackBps: 500
        });

        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.MultiplierOutOfRange.selector, multiplierBps));
        router.route(rp, _erc3009Params(rp));
    }

    /// @dev setPlatformFeeBps accepts any value ≤ MAX_PLATFORM_FEE_BPS and reverts above it.
    function testFuzz_SetPlatformFeeBps_BoundaryBehavior(uint16 bps) public {
        if (bps <= router.MAX_PLATFORM_FEE_BPS()) {
            vm.prank(admin);
            router.setPlatformFeeBps(bps);
            assertEq(router.platformFeeBps(), bps);
        } else {
            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(ISplitRouter.FeeTooHigh.selector, bps));
            router.setPlatformFeeBps(bps);
        }
    }

    /// @dev merchantAmt is always ≥ 0 (never underflows) for valid rates.
    function testFuzz_MerchantAmt_NeverUnderflows(
        uint256 grossAmount,
        uint16 commissionBps,
        uint16 cashbackBps,
        uint16 platformFeeBps,
        uint16 multiplierBps
    ) public {
        platformFeeBps = uint16(bound(platformFeeBps, 0, router.MAX_PLATFORM_FEE_BPS()));
        commissionBps = uint16(bound(commissionBps, 0, 10000 - platformFeeBps));
        cashbackBps = uint16(bound(cashbackBps, 0, 4000)); // of-commission cap (maxCashbackBpsOfCommission default)
        productRegistry.setCommission(merchantId, PRODUCT_ID, commissionBps);
        multiplierBps = uint16(bound(multiplierBps, 4000, 10000));
        grossAmount = bound(grossAmount, 1, type(uint96).max);

        vm.prank(admin);
        router.setPlatformFeeBps(platformFeeBps);
        usdc.mint(buyer, grossAmount);

        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: grossAmount,
            buyer: buyer,
            commissionMultiplierBps: multiplierBps,
            lockedCashbackBps: cashbackBps
        });

        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));

        assertLe(usdc.balanceOf(merchantOwner), grossAmount);
    }

    /// @dev Each individual split component never exceeds grossAmount.
    function testFuzz_SplitComponents_NeverExceedGross(
        uint256 grossAmount,
        uint16 commissionBps,
        uint16 cashbackBps,
        uint16 platformFeeBps,
        uint16 multiplierBps
    ) public {
        platformFeeBps = uint16(bound(platformFeeBps, 0, router.MAX_PLATFORM_FEE_BPS()));
        commissionBps = uint16(bound(commissionBps, 0, 10000 - platformFeeBps));
        cashbackBps = uint16(bound(cashbackBps, 0, 4000)); // of-commission cap (maxCashbackBpsOfCommission default)
        productRegistry.setCommission(merchantId, PRODUCT_ID, commissionBps);
        multiplierBps = uint16(bound(multiplierBps, 4000, 10000));
        grossAmount = bound(grossAmount, 1, type(uint96).max);

        vm.prank(admin);
        router.setPlatformFeeBps(platformFeeBps);
        usdc.mint(buyer, grossAmount);

        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: grossAmount,
            buyer: buyer,
            commissionMultiplierBps: multiplierBps,
            lockedCashbackBps: cashbackBps
        });

        vm.prank(facilitator);
        router.route(rp, _erc3009Params(rp));

        assertLe(usdc.balanceOf(reviewer), grossAmount);
        assertLe(usdc.balanceOf(address(escrow)), grossAmount);
        assertLe(usdc.balanceOf(treasury), grossAmount);
        assertLe(usdc.balanceOf(merchantOwner), grossAmount);
    }
}
