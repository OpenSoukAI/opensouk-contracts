// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockFixture} from "../helpers/Fixtures.sol";
import {ERC3009Signer} from "../helpers/ERC3009Signer.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {SplitRouter} from "../../src/SplitRouter.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";

/// @dev Pins the ERC-3009 authorization contract of `SplitRouter.route()`.
///
///      The rest of the suite exercises the split arithmetic and settlement, and treats the
///      authorization as a precondition it satisfies. These cases are the opposite: they assert
///      what the token rejects, so the "any signature works" behaviour that hid the
///      Transfer-vs-Receive typehash bug cannot come back unnoticed.
contract SplitRouterERC3009Test is MockFixture {
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
    uint256 internal constant GROSS = 100e6;
    uint16 internal constant COMMISSION_BPS = 1000;
    uint16 internal constant PLATFORM_FEE_BPS = 200;
    uint16 internal constant COMMISSION_MULTIPLIER_BPS = 7000;

    function setUp() public override {
        super.setUp();
        (buyer, buyerPk) = makeAddrAndKey("buyer");

        router = new SplitRouter(address(par), admin, address(usdc), PLATFORM_FEE_BPS);
        vm.prank(admin);
        router.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);

        buyerAgentId = agentRegistry.mint(buyer);
        merchantId = agentRegistry.mint(merchantOwner);
        reviewerAgentId = agentRegistry.mint(reviewer);
        merchantRegistry.setActiveRaw(merchantId, true);
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

        usdc.mint(buyer, GROSS * 4);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _routeParams() internal view returns (ISplitRouter.RouteParams memory) {
        return ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: GROSS,
            buyer: buyer,
            commissionMultiplierBps: COMMISSION_MULTIPLIER_BPS,
            lockedCashbackBps: 0
        });
    }

    /// @dev The authorization `route()` would need to succeed, built explicitly so each case can
    ///      bend exactly one field.
    function _auth(uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (ERC3009Signer.Authorization memory)
    {
        return ERC3009Signer.Authorization({
            from: buyer,
            to: address(router),
            value: value,
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce
        });
    }

    function _validAuth(bytes32 nonce) internal view returns (ERC3009Signer.Authorization memory) {
        return _auth(GROSS, 0, type(uint256).max, nonce);
    }

    // =========================================================================
    // The typehash itself
    // =========================================================================

    /// @dev The two ERC-3009 structs carry identical fields under different names, so they hash
    ///      differently. This is the whole typehash bug in one assertion: any signer that picks the
    ///      wrong one produces a signature the token cannot verify.
    function test_Typehashes_ReceiveAndTransfer_ProduceDifferentDigests() public view {
        ERC3009Signer.Authorization memory auth = _validAuth(bytes32(uint256(1)));
        bytes32 receiveDigest =
            ERC3009Signer.digest(ERC3009Signer.RECEIVE_WITH_AUTHORIZATION_TYPEHASH, usdcDomainSeparator, auth);
        bytes32 transferDigest =
            ERC3009Signer.digest(ERC3009Signer.TRANSFER_WITH_AUTHORIZATION_TYPEHASH, usdcDomainSeparator, auth);
        assertTrue(receiveDigest != transferDigest);
    }

    /// @dev The typehash bug. Every signer in the stack produced this signature, and the
    ///      suite accepted it because the mock verified nothing.
    function test_Route_Revert_SignedWithTransferTypehash() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep =
            ERC3009Signer.signTransfer(vm, buyerPk, usdcDomainSeparator, _validAuth(bytes32(uint256(1))));

        vm.prank(facilitator);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        router.route(rp, ep);
    }

    function test_Route_Succeeds_SignedWithReceiveTypehash() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        bytes32 nonce = bytes32(uint256(1));
        ISplitRouter.ERC3009Params memory ep =
            ERC3009Signer.signReceive(vm, buyerPk, usdcDomainSeparator, _validAuth(nonce));

        vm.prank(facilitator);
        uint256 escrowId = router.route(rp, ep);

        assertEq(escrowId, 1);
        assertTrue(usdc.authorizationState(buyer, nonce));
        // The router keeps nothing: the pull and the whole split are one transaction.
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // =========================================================================
    // Signature binding
    // =========================================================================

    function test_Route_Revert_SignedByWrongKey() public {
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep =
            ERC3009Signer.signReceive(vm, strangerPk, usdcDomainSeparator, _validAuth(bytes32(uint256(1))));

        vm.prank(facilitator);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        router.route(rp, ep);
    }

    /// @dev An authorization for a smaller amount must not fund a larger route. The signed `value`
    ///      is part of the digest, so the facilitator cannot inflate the pull after the fact.
    function test_Route_Revert_ValueDisagreesWithGrossAmount() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep = ERC3009Signer.signReceive(
            vm, buyerPk, usdcDomainSeparator, _auth(GROSS - 1, 0, type(uint256).max, bytes32(uint256(1)))
        );

        vm.prank(facilitator);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        router.route(rp, ep);
    }

    /// @dev The signature is bound to the payee. An authorization made out to another address
    ///      cannot be redirected through this router — this is the front-run guard Option A
    ///      relies on being structural rather than an off-chain invariant.
    function test_Route_Revert_AuthorizationPayableToAnotherAddress() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        ERC3009Signer.Authorization memory auth = _validAuth(bytes32(uint256(1)));
        auth.to = makeAddr("otherRouter");
        ISplitRouter.ERC3009Params memory ep = ERC3009Signer.signReceive(vm, buyerPk, usdcDomainSeparator, auth);

        vm.prank(facilitator);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        router.route(rp, ep);
    }

    // =========================================================================
    // Replay and validity window
    // =========================================================================

    function test_Route_Revert_NonceReplayed() public {
        bytes32 nonce = bytes32(uint256(7));
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep =
            ERC3009Signer.signReceive(vm, buyerPk, usdcDomainSeparator, _validAuth(nonce));

        vm.prank(facilitator);
        router.route(rp, ep);

        // Same authorization, same nonce, buyer still funded — the token must refuse.
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AuthNonceAlreadyUsed.selector, buyer, nonce));
        router.route(rp, ep);
    }

    function test_Route_Revert_AuthorizationExpired() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep = ERC3009Signer.signReceive(
            vm, buyerPk, usdcDomainSeparator, _auth(GROSS, 0, block.timestamp, bytes32(uint256(1)))
        );

        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AuthExpired.selector, block.timestamp, block.timestamp));
        router.route(rp, ep);
    }

    function test_Route_Revert_AuthorizationNotYetValid() public {
        ISplitRouter.RouteParams memory rp = _routeParams();
        ISplitRouter.ERC3009Params memory ep = ERC3009Signer.signReceive(
            vm, buyerPk, usdcDomainSeparator, _auth(GROSS, block.timestamp, type(uint256).max, bytes32(uint256(1)))
        );

        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AuthNotYetValid.selector, block.timestamp, block.timestamp));
        router.route(rp, ep);
    }

    // =========================================================================
    // The caller guard, asserted on the token directly
    // =========================================================================

    /// @dev `receiveWithAuthorization` requires `to == msg.sender`, which is what makes an
    ///      authorization unusable by anyone but its payee. `route()` can never violate it (the
    ///      router passes itself as `to`), so it is asserted against the token.
    function test_MockUSDC_Revert_CallerIsNotThePayee() public {
        address payee = makeAddr("payee");
        ERC3009Signer.Authorization memory auth = _validAuth(bytes32(uint256(1)));
        auth.to = payee;
        ISplitRouter.ERC3009Params memory ep = ERC3009Signer.signReceive(vm, buyerPk, usdcDomainSeparator, auth);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.CallerMustBePayee.selector, stranger, payee));
        usdc.receiveWithAuthorization(buyer, payee, GROSS, ep.validAfter, ep.validBefore, ep.nonce, ep.v, ep.r, ep.s);
    }
}
