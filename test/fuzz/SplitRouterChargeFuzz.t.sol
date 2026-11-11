// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockFixture} from "../helpers/Fixtures.sol";
import {SplitRouter} from "../../src/SplitRouter.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";

/// @dev Ported from the retired SplitRouterMPP fuzz suite (the splitCharge section only).
///      Only the contract under test (SplitRouter instead of
///      SplitRouterMPP), the attribution type (ISplitRouter.Attribution instead of
///      ISplitRouterMPP.AttributionSnapshot), and the EIP-712 domain ("SplitRouter" / "1" instead
///      of "SplitRouterMPP" / "2") differ from the archived cases. closeAndSplit's fuzz cases are
///      not ported — that entry point does not exist on SplitRouter.
contract SplitRouterChargeFuzz is MockFixture {
    SplitRouter internal router;

    address internal buyer = makeAddr("buyer");
    address internal merchantOwner = makeAddr("merchantOwner");
    address internal reviewer = makeAddr("reviewer");
    address internal oracleSigner;
    uint256 internal oraclePk;

    uint256 internal buyerAgentId;
    uint256 internal merchantId;
    uint256 internal reviewerAgentId;
    uint256 internal constant REVIEW_ID = 1;

    bytes32 internal constant PRODUCT_ID = keccak256("product-charge-fuzz");
    uint16 internal constant INITIAL_PLATFORM_FEE_BPS = 200;

    bytes32 private constant CHARGE_ATTESTATION_TYPEHASH = keccak256(
        "ChargeAttestation(bytes32 paymentRef,uint256 amount,address payer,uint256 reviewId,uint256 buyerAgentId,uint256 merchantId,bytes32 productId,uint16 commissionMultiplierBps,uint16 lockedCashbackBps)"
    );

    function setUp() public override {
        super.setUp();
        (oracleSigner, oraclePk) = makeAddrAndKey("oracleSigner");

        router = new SplitRouter(address(par), admin, address(usdc), INITIAL_PLATFORM_FEE_BPS);

        bytes32 signerRole = router.ORACLE_SIGNER_ROLE();
        vm.prank(admin);
        router.grantRole(signerRole, oracleSigner);

        buyerAgentId = agentRegistry.mint(buyer);
        merchantId = agentRegistry.mint(merchantOwner);
        reviewerAgentId = agentRegistry.mint(reviewer);
        merchantRegistry.setActiveRaw(merchantId, true);
        reviewRegistry.setReviewRaw(
            REVIEW_ID,
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

        // Commission is read live from ProductRegistry at settle. Register the product;
        // each test sets the fuzzed commission via productRegistry.setCommission before settling.
        setupProduct(merchantId, PRODUCT_ID, 1000, 0);
    }

    // =========================================================================
    // splitCharge — conservation
    // =========================================================================

    /// @dev For any valid rate combination: reviewer + escrow + treasury + merchant == amount.
    ///      No dust can be created or lost by integer-division truncation in SplitMath —
    ///      merchantAmt is the residual, so every truncation lands on the merchant and never in
    ///      the router.
    function testFuzz_SplitCharge_Conservation(
        uint256 amount,
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
        amount = bound(amount, 1, type(uint96).max);

        vm.prank(admin);
        router.setPlatformFeeBps(platformFeeBps);

        usdc.mint(address(router), amount);

        ISplitRouter.Attribution memory attr = ISplitRouter.Attribution({
            reviewId: REVIEW_ID,
            buyerAgentId: buyerAgentId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            commissionMultiplierBps: multiplierBps,
            lockedCashbackBps: cashbackBps
        });

        bytes32 paymentRef = keccak256("charge-conservation");
        bytes memory sig = _signChargeAttestation(paymentRef, amount, buyer, attr);

        router.splitCharge(paymentRef, amount, buyer, attr, sig);

        uint256 distributed = usdc.balanceOf(reviewer) + usdc.balanceOf(address(escrow)) + usdc.balanceOf(treasury)
            + usdc.balanceOf(merchantOwner);
        assertEq(distributed, amount, "conservation violated");
        assertEq(usdc.balanceOf(address(router)), 0, "wei stranded in router");
    }

    // =========================================================================
    // splitCharge — double-settle prevention
    // =========================================================================

    /// @dev Second call with the same paymentRef must always revert ChargeAlreadySettled.
    function testFuzz_SplitCharge_NoDoubleSettle(bytes32 paymentRef) public {
        uint256 amount = 100e6;
        ISplitRouter.Attribution memory attr = _defaultAttr();
        bytes memory sig = _signChargeAttestation(paymentRef, amount, buyer, attr);

        // Pre-fund enough for two hypothetical settlements to avoid InsufficientChargeBalance
        // triggering before the double-settle guard (second call should fail on the guard, not balance).
        usdc.mint(address(router), amount * 2);

        router.splitCharge(paymentRef, amount, buyer, attr, sig);

        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ChargeAlreadySettled.selector, paymentRef));
        router.splitCharge(paymentRef, amount, buyer, attr, sig);
    }

    // =========================================================================
    // splitCharge — invalid oracle sig
    // =========================================================================

    /// @dev A sig from any key other than the registered oracle must revert OracleAttestationInvalid.
    function testFuzz_SplitCharge_InvalidSig_Reverts(uint256 badPk) public {
        // secp256k1 valid range: [1, n-1]; exclude oraclePk so the recovered signer differs.
        badPk = bound(badPk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(badPk != oraclePk);

        uint256 amount = 100e6;
        bytes32 paymentRef = keccak256("charge-badsig");
        ISplitRouter.Attribution memory attr = _defaultAttr();

        bytes32 digest = _chargeDigest(paymentRef, amount, buyer, attr);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badPk, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        usdc.mint(address(router), amount);

        vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
        router.splitCharge(paymentRef, amount, buyer, attr, badSig);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _defaultAttr() internal view returns (ISplitRouter.Attribution memory) {
        return ISplitRouter.Attribution({
            reviewId: REVIEW_ID,
            buyerAgentId: buyerAgentId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            commissionMultiplierBps: 7000,
            lockedCashbackBps: 400 // 4% of commission (well within 40% cap)
        });
    }

    function _domainSep() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SplitRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
    }

    function _chargeDigest(bytes32 paymentRef, uint256 amount, address payer, ISplitRouter.Attribution memory attr)
        private
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                CHARGE_ATTESTATION_TYPEHASH,
                paymentRef,
                amount,
                payer,
                attr.reviewId,
                attr.buyerAgentId,
                attr.merchantId,
                attr.productId,
                attr.commissionMultiplierBps,
                attr.lockedCashbackBps
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSep(), structHash));
    }

    function _signChargeAttestation(
        bytes32 paymentRef,
        uint256 amount,
        address payer,
        ISplitRouter.Attribution memory attr
    ) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePk, _chargeDigest(paymentRef, amount, payer, attr));
        return abi.encodePacked(r, s, v);
    }
}
