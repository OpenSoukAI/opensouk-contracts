// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IntegrationFixture} from "../helpers/Fixtures.sol";
import {EIP712Helpers} from "../helpers/EIP712Helpers.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev The charge rail (`splitCharge`) was previously only
///      exercised against `MockCommissionEscrow` with PAR's SPLIT_ROUTER slot at a placeholder
///      address (see SplitRouterChargeTest.t.sol / MockFixture). That never proves the real
///      `CommissionEscrow.deposit` msg.sender gate accepts `splitCharge`'s caller (this router) —
///      which is the entire architectural reason splitCharge lives on SplitRouter instead of a
///      second router. This file uses IntegrationFixture (real CommissionEscrow, real PAR wiring
///      including SPLIT_ROUTER) to close that gap.
contract SplitRouterChargeIntegrationTest is IntegrationFixture {
    using EIP712Helpers for *;

    address internal oracleSigner;
    uint256 internal oraclePk;

    address internal buyer = makeAddr("buyer");
    address internal merchantOwner = makeAddr("merchantOwner");
    uint256 internal reviewerPk = 0xBEEF5;
    address internal reviewerOwner;

    uint256 internal buyerAgentId;
    uint256 internal merchantId;
    uint256 internal reviewerAgentId;
    uint256 internal reviewId;

    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");
    bytes32 internal constant PAYMENT_REF = keccak256("charge-tx-integration-1");
    uint256 internal constant GROSS = 100e6;

    uint16 internal constant COMMISSION_BPS = 1000; // 10%
    uint16 internal constant CASHBACK_BPS = 4000; // 40% OF COMMISSION
    uint16 internal constant COMMISSION_MULTIPLIER_BPS = 7000; // 70% immediate

    uint256 internal constant HELD_BACK = 3e6;
    uint256 internal constant CASHBACK_AMT = 4e6;
    uint256 internal constant REVIEWER_NET = 3e6;
    uint256 internal constant PLATFORM_FEE_AMT = 2e6; // PLATFORM_FEE_BPS = 200 (from IntegrationFixture)
    uint256 internal constant MERCHANT_AMT = 88e6;

    function setUp() public override {
        super.setUp();
        (oracleSigner, oraclePk) = makeAddrAndKey("chargeOracleSigner");

        // Grant the attestation signer role so the router accepts what this test signs with.
        bytes32 signerRole = splitRouter.ORACLE_SIGNER_ROLE();
        vm.prank(admin);
        splitRouter.grantRole(signerRole, oracleSigner);

        reviewerOwner = vm.addr(reviewerPk);
        buyerAgentId = mintAgent(buyer);
        merchantId = mintMerchant(merchantOwner);
        reviewerAgentId = mintAgent(reviewerOwner);
        addProduct(merchantId, merchantOwner, PRODUCT_ID, COMMISSION_BPS, CASHBACK_BPS);

        bytes32 contentHash = keccak256("review content");
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 days;
        bytes memory sig = EIP712Helpers.signReviewCommitment(
            vm,
            reviewerPk,
            address(reviewRegistry),
            block.chainid,
            reviewerAgentId,
            merchantId,
            PRODUCT_ID,
            contentHash,
            nonce,
            expiry
        );
        vm.prank(oracle);
        reviewId = reviewRegistry.publishReview(
            reviewerAgentId,
            merchantId,
            PRODUCT_ID,
            contentHash,
            IReviewRegistry.ProofType.AdminApproved,
            IReviewRegistry.Sig({nonce: nonce, expiry: expiry, agentSignature: sig})
        );
    }

    // -------------------------------------------------------------------------
    // ChargeAttestation signing (matches SplitRouter._verifyChargeAttestation,
    // domain EIP712("SplitRouter", "1"))
    // -------------------------------------------------------------------------

    function _attr() internal view returns (ISplitRouter.Attribution memory) {
        return ISplitRouter.Attribution({
            reviewId: reviewId,
            buyerAgentId: buyerAgentId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: CASHBACK_BPS
        });
    }

    function _chargeDigest(bytes32 paymentRef, uint256 amount, address payer, ISplitRouter.Attribution memory a)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ChargeAttestation(bytes32 paymentRef,uint256 amount,address payer,uint256 reviewId,uint256 buyerAgentId,uint256 merchantId,bytes32 productId,uint16 commissionMultiplierBps,uint16 lockedCashbackBps)"
                ),
                paymentRef,
                amount,
                payer,
                a.reviewId,
                a.buyerAgentId,
                a.merchantId,
                a.productId,
                a.commissionMultiplierBps,
                a.lockedCashbackBps
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SplitRouter"),
                keccak256("1"),
                block.chainid,
                address(splitRouter)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fundCharge(uint256 amount) internal {
        usdc.mint(address(splitRouter), amount);
    }

    function _splitCharge(bytes32 paymentRef, uint256 amount, address payer) internal returns (uint256) {
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(paymentRef, amount, payer, a));
        return splitRouter.splitCharge(paymentRef, amount, payer, a, sig);
    }

    // =========================================================================
    // Real CommissionEscrow — splitCharge must be accepted by the msg.sender gate
    // =========================================================================

    function test_Integration_SplitCharge_RealEscrow_SplitsAndDeposits() public {
        _fundCharge(GROSS);
        uint256 escrowId = _splitCharge(PAYMENT_REF, GROSS, buyer);

        // The real CommissionEscrow.deposit() gates msg.sender against PAR's SPLIT_ROUTER key
        // (src/CommissionEscrow.sol:61-63, CallerNotSplitRouter). Reaching here at all proves
        // splitCharge's caller identity (this SplitRouter) satisfies that gate — the entire
        // reason splitCharge was merged into SplitRouter instead of a second router.
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET, "reviewer net");
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT, "platform fee");
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT, "merchant net");
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK + CASHBACK_AMT, "escrow held-back + cashback");
        assertEq(usdc.balanceOf(address(splitRouter)), 0, "router drained");

        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.reviewerAgentId, reviewerAgentId);
        assertEq(r.buyerAgentId, buyerAgentId);
        assertEq(r.merchantId, merchantId);
        assertEq(r.productId, PRODUCT_ID);
        assertEq(r.heldBackAmt, HELD_BACK);
        assertEq(r.cashbackAmt, CASHBACK_AMT);
        assertEq(r.originalPurchaseAmt, GROSS);
        assertEq(r.buyerWallet, buyer);
        assertEq(uint8(r.state), uint8(ICommissionEscrow.EscrowState.Holding));
    }

    function test_Integration_SplitCharge_RealEscrow_FullLifecycle_SettleAndReleaseCashback() public {
        _fundCharge(GROSS);
        uint256 escrowId = _splitCharge(PAYMENT_REF, GROSS, buyer);

        vm.prank(oracle);
        escrow.settleHeldBack(escrowId, 100);
        assertEq(usdc.balanceOf(reviewerOwner), REVIEWER_NET + HELD_BACK);

        vm.prank(oracle);
        escrow.releaseCashback(escrowId);
        assertEq(usdc.balanceOf(buyer), CASHBACK_AMT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // =========================================================================
    // Paused escrow — splitCharge must revert, not half-settle
    // =========================================================================

    function test_Integration_PausedEscrow_BlocksSplitCharge() public {
        _fundCharge(GROSS);

        vm.prank(admin);
        escrow.pause();

        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));

        vm.expectRevert(Pausable.EnforcedPause.selector);
        splitRouter.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);

        // Nothing moved: the whole call reverted rather than paying reviewer/treasury/merchant
        // before the deposit() call hit the pause gate.
        assertEq(usdc.balanceOf(reviewerOwner), 0, "no half-settle: reviewer");
        assertEq(usdc.balanceOf(treasury), 0, "no half-settle: treasury");
        assertEq(usdc.balanceOf(merchantOwner), 0, "no half-settle: merchant");
        assertEq(usdc.balanceOf(address(escrow)), 0, "no half-settle: escrow");
        assertEq(usdc.balanceOf(address(splitRouter)), GROSS, "router still holds the pooled charge funds");
    }

    function test_Integration_UnpausedEscrow_SplitChargeResumesNormally() public {
        _fundCharge(GROSS);

        vm.prank(admin);
        escrow.pause();
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        splitRouter.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);

        vm.prank(admin);
        escrow.unpause();

        uint256 escrowId = _splitCharge(PAYMENT_REF, GROSS, buyer);
        assertEq(uint8(escrow.getEscrow(escrowId).state), uint8(ICommissionEscrow.EscrowState.Holding));
    }
}
