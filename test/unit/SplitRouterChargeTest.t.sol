// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {MaliciousReentrantEscrow} from "../helpers/MaliciousReentrantEscrow.sol";
import {SplitRouter} from "../../src/SplitRouter.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";
import {IProductRegistry} from "../../src/interfaces/IProductRegistry.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev Ported from the retired SplitRouterMPP unit suite (splitCharge section).
///      Only the contract under test (SplitRouter instead of
///      SplitRouterMPP), the attribution type (ISplitRouter.Attribution instead of
///      ISplitRouterMPP.AttributionSnapshot), and the EIP-712 domain ("SplitRouter" / "1" instead
///      of "SplitRouterMPP" / "2") differ from the archived cases.
contract SplitRouterChargeTest is MockFixture {
    SplitRouter internal router;

    address internal buyer;
    uint256 internal buyerPk;
    address internal merchantOwner = makeAddr("merchant");
    address internal reviewer = makeAddr("reviewer");
    address internal oracleSigner;
    uint256 internal oraclePk;

    uint256 internal buyerAgentId;
    uint256 internal merchantId;
    uint256 internal reviewerAgentId;
    uint256 internal reviewId;

    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");
    uint256 internal constant GROSS = 100e6; // 100 USDC

    uint16 internal constant COMMISSION_BPS = 1000; // 10%
    uint16 internal constant CASHBACK_BPS = 4000; // 40% OF COMMISSION → 4e6 (== old 4% of gross; at 40% cap)
    uint16 internal constant PLATFORM_FEE_BPS = 200; // 2%
    uint16 internal constant COMMISSION_MULTIPLIER_BPS = 7000; // 70% immediate

    uint256 internal constant COMMISSION_AMT = 10e6;
    uint256 internal constant IMMEDIATE_COMMISSION = 7e6;
    uint256 internal constant HELD_BACK = 3e6;
    uint256 internal constant CASHBACK_AMT = 4e6; // 4% of 100e6
    uint256 internal constant REVIEWER_NET = 3e6; // IMMEDIATE_COMMISSION - CASHBACK_AMT
    uint256 internal constant PLATFORM_FEE_AMT = 2e6;
    uint256 internal constant MERCHANT_AMT = 88e6; // 100 - 10 - 2 (cashback not deducted)

    bytes32 internal constant PAYMENT_REF = keccak256("charge-tx-1");
    address internal stranger = makeAddr("stranger");
    address internal payer;
    uint256 internal constant CHARGE_AMT = GROSS;

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

    function setUp() public override {
        super.setUp();
        // route() pulls via a signed ERC-3009 authorization, so the buyer needs a key.
        // makeAddrAndKey yields the same address makeAddr did for this label.
        (buyer, buyerPk) = makeAddrAndKey("buyer");
        (oracleSigner, oraclePk) = makeAddrAndKey("oracleSigner");
        payer = buyer;

        router = new SplitRouter(address(par), admin, address(usdc), PLATFORM_FEE_BPS);
        vm.prank(admin);
        router.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);

        // The attestation signer is a router role, not a registry entry: a compromised signer is
        // revoked in one transaction instead of waiting out the registry timelock.
        // Hoisted: vm.prank applies to the NEXT call, and reading the constant is itself a call.
        bytes32 signerRole = router.ORACLE_SIGNER_ROLE();
        vm.prank(admin);
        router.grantRole(signerRole, oracleSigner);

        buyerAgentId = agentRegistry.mint(buyer);
        merchantId = agentRegistry.mint(merchantOwner);
        reviewerAgentId = agentRegistry.mint(reviewer);
        merchantRegistry.setActiveRaw(merchantId, true);

        // Commission is read live from ProductRegistry at settle.
        setupProduct(merchantId, PRODUCT_ID, COMMISSION_BPS, 0);

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

    // -------------------------------------------------------------------------
    // Oracle attestation signing (matches SplitRouter._verifyChargeAttestation)
    // -------------------------------------------------------------------------

    function _chargeDigest(bytes32 paymentRef, uint256 amount, address payer_, ISplitRouter.Attribution memory a)
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
                payer_,
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
                address(router)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        return _signWith(oraclePk, digest);
    }

    function _signWith(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // Simulate the buyer's charge transfer landing: mint `amount` to the router.
    function _fundCharge(uint256 amount) internal {
        usdc.mint(address(router), amount);
    }

    function _splitCharge(bytes32 paymentRef, uint256 amount, address payer_) internal returns (uint256) {
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(paymentRef, amount, payer_, a));
        return router.splitCharge(paymentRef, amount, payer_, a, sig);
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
    // splitCharge (MPP one-off charge)
    // =========================================================================

    function test_SplitCharge_SplitsCorrectly() public {
        _fundCharge(GROSS);
        _splitCharge(PAYMENT_REF, GROSS, buyer);
        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET);
        assertEq(usdc.balanceOf(address(escrow)), HELD_BACK + CASHBACK_AMT);
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT);
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // A merchant raising commission after the charge was delivered must NOT strand the
    // already-transferred funds. The router clamps live commission to BPS_DENOM - platformFee so
    // splitCharge always settles (this is the sharp case — funds arrive before the call).
    function test_SplitCharge_HighLiveCommission_ClampedNotStranded() public {
        _fundCharge(GROSS); // buyer's USDC already sits in the router
        productRegistry.setCommission(merchantId, PRODUCT_ID, 9900); // 9900 + 200 fee = 10100 > 10000
        _splitCharge(PAYMENT_REF, GROSS, buyer); // must not revert
        assertEq(usdc.balanceOf(merchantOwner), 0, "merchant net floored to 0 by clamp");
        assertEq(usdc.balanceOf(address(router)), 0, "no funds stranded in router");
        assertEq(
            usdc.balanceOf(reviewer) + usdc.balanceOf(address(escrow)) + usdc.balanceOf(treasury)
                + usdc.balanceOf(merchantOwner),
            GROSS,
            "conservation"
        );
    }

    function test_SplitCharge_EmitsChargeSettled() public {
        _fundCharge(GROSS);
        vm.expectEmit(true, true, true, true);
        emit ISplitRouter.ChargeSettled(
            PAYMENT_REF,
            1,
            buyerAgentId,
            buyer,
            GROSS,
            REVIEWER_NET,
            HELD_BACK,
            PLATFORM_FEE_AMT,
            CASHBACK_AMT,
            MERCHANT_AMT
        );
        _splitCharge(PAYMENT_REF, GROSS, buyer);
    }

    function test_SplitCharge_EscrowDeposit_CorrectArgs() public {
        _fundCharge(GROSS);
        uint256 escrowId = _splitCharge(PAYMENT_REF, GROSS, buyer);
        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.reviewerAgentId, reviewerAgentId);
        assertEq(r.heldBackAmt, HELD_BACK);
        assertEq(r.cashbackAmt, CASHBACK_AMT);
        assertEq(r.originalPurchaseAmt, GROSS);
    }

    function test_SplitCharge_StoresBuyerWallet_NormalAgent() public {
        _fundCharge(GROSS);
        uint256 escrowId = _splitCharge(PAYMENT_REF, GROSS, buyer);
        assertEq(escrow.getEscrow(escrowId).buyerWallet, buyer);
    }

    function test_SplitCharge_Sentinel_SettlesWithoutBuyerNFT() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr();
        a.buyerAgentId = router.SENTINEL_BUYER();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        uint256 escrowId = router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);

        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.buyerAgentId, router.SENTINEL_BUYER());
        assertEq(r.buyerWallet, buyer); // payer recorded despite no buyer NFT
        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET);
        assertEq(r.heldBackAmt, HELD_BACK);
    }

    // MPP had no zero-payer guard. Sentinel skips ownerOf, which used to reject
    // payer==0 as a side effect — so a zero payer must be rejected explicitly (else buyerWallet
    // would persist as 0 and the escrow could never be bound/claimed).
    function test_SplitCharge_Revert_ZeroPayer() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr();
        a.buyerAgentId = router.SENTINEL_BUYER();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, address(0), a));
        vm.expectRevert(ISplitRouter.ZeroBuyerAddress.selector);
        router.splitCharge(PAYMENT_REF, GROSS, address(0), a, sig);
    }

    // Internal audit #3 MPP-03 (VALID-OPEN against SplitRouterMPP): "route rejects ZeroAmount and
    // closeAndSplit has NothingReceived, but splitCharge has neither." SplitRouter's splitCharge
    // was written with the guard from day one (src/SplitRouter.sol:275), but review comment M-1
    // flagged it as untested — an untested guard is a weak way to close a tracked audit finding.
    function test_SplitCharge_Revert_ZeroAmount() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, 0, buyer, a));
        vm.expectRevert(ISplitRouter.ZeroAmount.selector);
        router.splitCharge(PAYMENT_REF, 0, buyer, a, sig);
    }

    function test_SplitCharge_Revert_DoubleSettle() public {
        _fundCharge(GROSS);
        _splitCharge(PAYMENT_REF, GROSS, buyer);
        _fundCharge(GROSS); // even with funds, same paymentRef is single-use
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ChargeAlreadySettled.selector, PAYMENT_REF));
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    function test_SplitCharge_PerChargeIsolation() public {
        // Two charges (200 pooled) with distinct paymentRefs split independently.
        _fundCharge(2 * GROSS);
        _splitCharge(keccak256("tx-A"), GROSS, buyer);
        _splitCharge(keccak256("tx-B"), GROSS, buyer);
        // Each charge paid the reviewer once → 2× reviewer net; router fully drained.
        assertEq(usdc.balanceOf(reviewer), 2 * REVIEWER_NET);
        assertEq(usdc.balanceOf(merchantOwner), 2 * MERCHANT_AMT);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_SplitCharge_Revert_InsufficientBalance() public {
        _fundCharge(GROSS - 1); // less than attested amount
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        vm.expectRevert(ISplitRouter.InsufficientChargeBalance.selector);
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    function test_SplitCharge_Revert_TamperedAmount() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        // Submit a different amount than was signed → attestation mismatch.
        vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
        router.splitCharge(PAYMENT_REF, GROSS - 1, buyer, a, sig);
    }

    // Previously only `amount` was tamper-tested. If any of
    // the 7 signed Attribution fields (or paymentRef/payer) were ever dropped from the
    // abi.encode in _verifyChargeAttestation, this suite would stay green while a caller could
    // rewrite the split (e.g. set commissionMultiplierBps=10000 and lockedCashbackBps=0 to hand
    // the whole commission to the reviewer, or repoint merchantId/productId at a different rate).
    function test_SplitCharge_Revert_EveryAttrFieldIsBound() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory signed = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, signed));

        for (uint256 i = 0; i < 6; i++) {
            ISplitRouter.Attribution memory t = _attr();
            if (i == 0) t.reviewId += 1;
            else if (i == 1) t.buyerAgentId += 1;
            else if (i == 2) t.merchantId += 1;
            else if (i == 3) t.productId = keccak256("other-product");
            else if (i == 4) t.commissionMultiplierBps = 10_000;
            else t.lockedCashbackBps = 0;
            vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
            router.splitCharge(PAYMENT_REF, GROSS, buyer, t, sig);
        }

        // paymentRef and payer are bound too.
        vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
        router.splitCharge(keccak256("other-ref"), GROSS, buyer, signed, sig);
        vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
        router.splitCharge(PAYMENT_REF, GROSS, stranger, signed, sig);
    }

    // The domain's verifyingContract is bound too — a signature valid for
    // one SplitRouter must not verify against a different deployment.
    function test_SplitCharge_Revert_WrongVerifyingContract() public {
        _fundCharge(GROSS);
        SplitRouter otherRouter = new SplitRouter(address(par), admin, address(usdc), PLATFORM_FEE_BPS);
        ISplitRouter.Attribution memory a = _attr();

        // Sign a digest bound to `router`'s domain (verifyingContract = address(router)), then
        // submit it to a different SplitRouter deployment.
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        usdc.mint(address(otherRouter), GROSS);
        vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
        otherRouter.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    function test_SplitCharge_Revert_NonOracleSigner() public {
        _fundCharge(GROSS);
        (, uint256 strangerPk) = makeAddrAndKey("stranger-signer");
        ISplitRouter.Attribution memory a = _attr();
        bytes32 digest = _chargeDigest(PAYMENT_REF, GROSS, buyer, a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strangerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    // This INVERTS the old test_SplitCharge_Revert_BuyerOwnerMismatch. The settlement
    // path no longer re-checks ownerOf, because on the charge rail the sale is already complete —
    // the buyer paid and the merchant served the resource — and the buyer's funds are already in
    // the router. A buyer legitimately transferring their own agent NFT afterwards must not brick a
    // finished sale by stranding those funds until admin recovery. The check protected escrow-record
    // bindability rather than gating the sale, and SENTINEL_BUYER bypassed it entirely, so it was
    // never load-bearing. The payer wallet is still recorded on the escrow either way, and the
    // oracle now checks ownerOf at attestation time, which is the moment it can be checked
    // correctly. route() keeps its check — see test_Route_Revert_BuyerOwnerMismatch.
    function test_SplitCharge_SettlesAfterBuyerAgentTransferred() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));

        // The buyer transfers their agent NFT away AFTER paying and being served.
        address newOwner = makeAddr("newAgentOwner");
        vm.prank(buyer);
        agentRegistry.transferFrom(buyer, newOwner, buyerAgentId);
        assertEq(agentRegistry.ownerOf(buyerAgentId), newOwner, "precondition: NFT moved");

        uint256 escrowId = router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);

        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.buyerWallet, buyer, "payer wallet must still be recorded on the escrow");
        assertEq(r.buyerAgentId, buyerAgentId, "attested buyer agent id is preserved");
        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET, "split must complete normally");
    }

    // =========================================================================
    // attestation signer as a role
    // =========================================================================

    // The point of holding the signer as a role rather than a registry entry: a compromised key is
    // invalidated in one transaction, instead of waiting out the registry's timelock. Every
    // signature that key can ever produce dies with the grant, including ones already signed.
    function test_SplitCharge_Revert_AfterSignerRoleRevoked() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));

        bytes32 signerRole = router.ORACLE_SIGNER_ROLE();
        vm.prank(admin);
        router.revokeRole(signerRole, oracleSigner);

        vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    // The second reason it is a role: it is a set, so a key rotation overlaps instead of cutting
    // over. Both signers verify while the backend switches; revoking the outgoing one is covered by
    // test_SplitCharge_Revert_AfterSignerRoleRevoked.
    function test_SplitCharge_BothSignersValidDuringRotation() public {
        (address nextSigner, uint256 nextPk) = makeAddrAndKey("nextOracleSigner");
        bytes32 signerRole = router.ORACLE_SIGNER_ROLE();
        vm.prank(admin);
        router.grantRole(signerRole, nextSigner);

        ISplitRouter.Attribution memory a = _attr();

        // Outgoing key still settles.
        _fundCharge(GROSS);
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a)));

        // Incoming key settles too, on a different charge.
        bytes32 ref2 = keccak256("rotation-charge-2");
        _fundCharge(GROSS);
        router.splitCharge(ref2, GROSS, buyer, a, _signWith(nextPk, _chargeDigest(ref2, GROSS, buyer, a)));
    }

    // A signature from a key that was never granted must not settle — the check is membership, not
    // merely "recovers to some address".
    function test_SplitCharge_Revert_UngrantedSigner() public {
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr();

        vm.expectRevert(ISplitRouter.OracleAttestationInvalid.selector);
        router.splitCharge(
            PAYMENT_REF, GROSS, buyer, a, _signWith(strangerPk, _chargeDigest(PAYMENT_REF, GROSS, buyer, a))
        );
    }

    // Retained deliberately as defence-in-depth: the oracle gates this upstream at attestation time,
    // so the oracle should never sign for a suspended merchant. This check is the backstop against a
    // COMPROMISED OR BUGGY ORACLE — the oracle key is the highest-risk key in the system, and
    // merchant/product active state is the one condition where an on-chain re-check has real value.
    // Do not delete this as redundant.
    function test_SplitCharge_Revert_MerchantNotActive() public {
        _fundCharge(GROSS);
        merchantRegistry.setActiveRaw(merchantId, false);
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.MerchantNotActive.selector, merchantId));
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    // A deactivated product must be rejected on-chain at settle. Retained as defence-in-depth against a compromised/buggy oracle — see the note on
    // test_SplitCharge_Revert_MerchantNotActive. Gated upstream at attestation time.
    function test_SplitCharge_Revert_ProductNotActive() public {
        _fundCharge(GROSS);
        productRegistry.setProductActive(merchantId, PRODUCT_ID, false);
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ProductNotActive.selector, merchantId, PRODUCT_ID));
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    // An admin lowering the cashback cap AFTER the oracle attested must not brick a sale
    // whose funds are already sitting in the router. Clamp to the current cap and settle instead of
    // reverting. route() keeps reverting with CashbackExceedsCommissionCap, because its revert
    // precedes the ERC-3009 pull — nothing is stranded there.
    function test_SplitCharge_ClampsCashbackWhenCapLowered() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr(); // attested at CASHBACK_BPS = 4000 (40% of commission)
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));

        // Admin halves the cap after attestation.
        uint16 loweredCap = CASHBACK_BPS / 2; // 2000 => 20% of commission
        vm.prank(admin);
        router.setMaxCashbackBps(loweredCap);

        uint256 escrowId = router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);

        // Cashback is a fraction OF COMMISSION, so clamping it moves the difference to the
        // reviewer's immediate share; held-back, platform fee and merchant amounts are untouched.
        uint256 clampedCashback = COMMISSION_AMT * loweredCap / 10_000; // 2e6
        uint256 clampedReviewerNet = IMMEDIATE_COMMISSION - clampedCashback; // 5e6

        ICommissionEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.cashbackAmt, clampedCashback, "cashback must be clamped to the current cap");
        assertEq(usdc.balanceOf(reviewer), clampedReviewerNet, "reviewer receives the clamped remainder");
        assertEq(r.heldBackAmt, HELD_BACK, "held-back unchanged by the clamp");
        assertEq(usdc.balanceOf(treasury), PLATFORM_FEE_AMT, "platform fee unchanged by the clamp");
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT, "merchant amount unchanged by the clamp");
    }

    // Pins the contract's actual EIP-712 domain. Without this, every test in this
    // file is only self-consistent (the _chargeDigest helper hard-codes "SplitRouter"/"1" and
    // signs against it) — nothing ties that literal to what the constructor actually passed to
    // EIP712(...). If both had been copy-pasted from the archive as "SplitRouterMPP"/"2", all
    // other tests would still pass, and a later task pinning the backend to this contract's
    // domain would be pinned to the wrong value.
    function test_SplitCharge_DomainIsSplitRouterV1() public view {
        (, string memory name, string memory version,,,,) = router.eip712Domain();
        assertEq(name, "SplitRouter", "EIP-712 domain name");
        assertEq(version, "1", "EIP-712 domain version");
    }

    function test_SplitCharge_PermissionlessCaller() public {
        _fundCharge(GROSS);
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        vm.prank(makeAddr("randomCaller"));
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
        assertEq(usdc.balanceOf(reviewer), REVIEWER_NET);
        assertEq(usdc.balanceOf(merchantOwner), MERCHANT_AMT);
    }

    /// @dev route() must leave no residual balance that a later splitCharge could consume.
    ///      Guards against the two rails cross-funding each other in the shared router.
    function test_SplitCharge_Revert_CannotConsumeRouteResidue() public {
        _route(); // atomic pull + split; router balance must return to 0
        assertEq(usdc.balanceOf(address(router)), 0, "route left residue");

        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, CHARGE_AMT, payer, a));
        vm.expectRevert(ISplitRouter.InsufficientChargeBalance.selector);
        router.splitCharge(PAYMENT_REF, CHARGE_AMT, payer, a, sig);
    }

    // Deferred finding M-6: splitCharge's nonReentrant guard (src/SplitRouter.sol, ~line 278) was
    // never exercised by the suite. The only reachable reentry point is _settleAndDeposit's call
    // into ICommissionEscrow.deposit() at whatever address PAR's ESCROW key resolves to, so this
    // installs a malicious escrow there and has deposit() call back into splitCharge.
    //
    // The reentrant call deliberately uses a DIFFERENT paymentRef (with its own valid oracle
    // signature) than the outer call. _chargeSettled[PAYMENT_REF] is already true by the time
    // deposit() runs (set before _settleAndDeposit, effects-before-interactions), so a reentrant
    // call reusing the outer ref would revert ChargeAlreadySettled and this test would pass even
    // if nonReentrant did not exist. With a distinct ref, only nonReentrant can block it.
    function test_SplitCharge_Revert_Reentrancy() public {
        MaliciousReentrantEscrow malEscrow = new MaliciousReentrantEscrow();
        vm.startPrank(admin);
        par.setAddress(keccak256("ESCROW"), address(malEscrow));
        par.executeUpdate(keccak256("ESCROW")); // timelock is 0 in MockFixture
        vm.stopPrank();

        _fundCharge(GROSS); // outer charge's pre-delivered funds sitting in the router

        bytes32 innerRef = keccak256("charge-tx-reentrant");
        ISplitRouter.Attribution memory innerAttr = _attr();
        bytes memory innerSig = _sign(_chargeDigest(innerRef, GROSS, buyer, innerAttr));
        malEscrow.setReentryCall(address(router), innerRef, GROSS, buyer, innerAttr, innerSig);

        uint256 routerBalBefore = usdc.balanceOf(address(router));

        ISplitRouter.Attribution memory outerAttr = _attr();
        bytes memory outerSig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, outerAttr));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.splitCharge(PAYMENT_REF, GROSS, buyer, outerAttr, outerSig);

        // Whole outer transaction unwound: no funds moved, and the malicious escrow's own
        // deposit-call counter (incremented before the reentrant call) rolls back to 0 too.
        assertEq(usdc.balanceOf(address(router)), routerBalBefore, "router balance must be unchanged");
        assertEq(usdc.balanceOf(address(malEscrow)), 0, "no funds reached the escrow");
        assertEq(malEscrow.depositCallCount(), 0, "deposit()'s own state change was rolled back too");
    }

    // =========================================================================
    // recoverUSDC refund invalidates the paymentRef (#15)
    // =========================================================================

    /// @dev The audit scenario: A's charge parks, is refunded, the product comes back, B pays.
    ///      A's public attestation must not settle against B's pooled funds.
    function test_RecoverUSDC_RefundedChargeCannotSettleLater() public {
        bytes32 refB = keccak256("charge-tx-2");
        ISplitRouter.Attribution memory a = _attr();
        bytes memory sigA = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));

        _fundCharge(GROSS); // buyer A pays
        productRegistry.setProductActive(merchantId, PRODUCT_ID, false);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ProductNotActive.selector, merchantId, PRODUCT_ID));
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sigA);

        vm.prank(admin);
        router.recoverUSDC(buyer, GROSS, PAYMENT_REF); // refund A
        productRegistry.setProductActive(merchantId, PRODUCT_ID, true);
        _fundCharge(GROSS); // buyer B pays

        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ChargeAlreadySettled.selector, PAYMENT_REF));
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sigA);

        _splitCharge(refB, GROSS, buyer); // B still settles from its own funds
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_RecoverUSDC_Revert_RefundAlreadySettledCharge() public {
        _fundCharge(GROSS);
        _splitCharge(PAYMENT_REF, GROSS, buyer);
        usdc.mint(address(router), GROSS);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ChargeAlreadySettled.selector, PAYMENT_REF));
        router.recoverUSDC(buyer, GROSS, PAYMENT_REF);
    }

    function test_RecoverUSDC_Revert_DoubleRefund() public {
        _fundCharge(2 * GROSS);
        vm.startPrank(admin);
        router.recoverUSDC(buyer, GROSS, PAYMENT_REF);
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ChargeAlreadySettled.selector, PAYMENT_REF));
        router.recoverUSDC(buyer, GROSS, PAYMENT_REF);
        vm.stopPrank();
    }

    function test_RecoverUSDC_ZeroAmountWithRef_OnlyInvalidates() public {
        _fundCharge(GROSS);
        vm.prank(admin);
        router.recoverUSDC(buyer, 0, PAYMENT_REF);
        assertEq(usdc.balanceOf(address(router)), GROSS, "no USDC moved");

        ISplitRouter.Attribution memory a = _attr();
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        vm.expectRevert(abi.encodeWithSelector(ISplitRouter.ChargeAlreadySettled.selector, PAYMENT_REF));
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    function test_RecoverUSDC_ZeroRef_LeavesChargeSettleable() public {
        _fundCharge(2 * GROSS);
        vm.prank(admin);
        router.recoverUSDC(makeAddr("stray"), GROSS, bytes32(0));
        _splitCharge(PAYMENT_REF, GROSS, buyer); // the zero ref marked nothing
    }

    function test_RecoverUSDC_WithRef_EmitsBothEvents() public {
        _fundCharge(GROSS);
        vm.expectEmit(true, true, false, true);
        emit ISplitRouter.ChargeRefunded(PAYMENT_REF, buyer, GROSS);
        vm.expectEmit(true, false, false, true);
        emit ISplitRouter.USDCRecovered(buyer, GROSS);
        vm.prank(admin);
        router.recoverUSDC(buyer, GROSS, PAYMENT_REF);
    }

    // =========================================================================
    // Attribution scope on the charge rail (#16)
    // =========================================================================

    function test_SplitCharge_Revert_ReviewMerchantMismatch() public {
        uint256 otherMerchant = agentRegistry.mint(makeAddr("otherMerchant"));
        merchantRegistry.setActiveRaw(otherMerchant, true);
        setupProduct(otherMerchant, PRODUCT_ID, COMMISSION_BPS, 0);
        _fundCharge(GROSS);

        ISplitRouter.Attribution memory a = _attr();
        a.merchantId = otherMerchant; // review belongs to `merchantId`
        bytes memory sig = _sign(_chargeDigest(PAYMENT_REF, GROSS, buyer, a));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitRouter.ReviewMerchantMismatch.selector, reviewId, merchantId, otherMerchant)
        );
        router.splitCharge(PAYMENT_REF, GROSS, buyer, a, sig);
    }

    function test_SplitCharge_EscrowProductType_ComesFromRegistry() public {
        IProductRegistry.Product memory p = productRegistry.getProduct(merchantId, PRODUCT_ID);
        p.productType = IProductRegistry.ProductType.OneOff;
        productRegistry.setProductRaw(merchantId, PRODUCT_ID, p);
        _fundCharge(GROSS);

        uint256 escrowId = _splitCharge(PAYMENT_REF, GROSS, buyer);
        assertEq(escrow.getEscrow(escrowId).productType, uint8(IProductRegistry.ProductType.OneOff));
    }
}
