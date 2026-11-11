// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {EIP712Helpers} from "../helpers/EIP712Helpers.sol";
import {ReviewRegistry} from "../../src/ReviewRegistry.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";
import {IProductRegistry} from "../../src/interfaces/IProductRegistry.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";

contract ReviewRegistryTest is MockFixture {
    ReviewRegistry internal reviewReg;

    address internal oracleAddr = makeAddr("oracle");
    uint256 internal agentPk = 0xA11CE;
    uint256 internal agentWalletPk = 0xA11CE2;
    address internal agentOwner;
    address internal agentWalletAddr;
    uint256 internal agentId;
    uint256 internal merchantId;
    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");
    bytes32 internal constant CONTENT_HASH = keccak256("review content");

    function setUp() public override {
        super.setUp();
        reviewReg = new ReviewRegistry(address(par), admin);
        vm.startPrank(admin);
        reviewReg.grantRole(keccak256("ORACLE_ROLE"), oracleAddr);
        vm.stopPrank();

        agentOwner = vm.addr(agentPk);
        agentWalletAddr = vm.addr(agentWalletPk);
        agentId = agentRegistry.mint(agentOwner);
        merchantId = agentRegistry.mint(makeAddr("merchant"));
        merchantRegistry.setActiveRaw(merchantId, true); // ReviewRegistry checks the merchant too

        productRegistry.setProductRaw(
            merchantId,
            PRODUCT_ID,
            IProductRegistry.Product({
                merchantId: merchantId,
                productId: PRODUCT_ID,
                commissionBps: 500,
                active: true,
                productCardURI: "",
                createdAt: uint40(block.timestamp),
                productType: IProductRegistry.ProductType.Repeat
            })
        );
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _sign(uint256 nonce, uint256 expiry) internal view returns (IReviewRegistry.Sig memory) {
        bytes memory sig = EIP712Helpers.signReviewCommitment(
            vm, agentPk, address(reviewReg), block.chainid, agentId, merchantId, PRODUCT_ID, CONTENT_HASH, nonce, expiry
        );
        return IReviewRegistry.Sig({nonce: nonce, expiry: expiry, agentSignature: sig});
    }

    function _signFor(
        uint256 pk,
        uint256 _agentId,
        uint256 _merchantId,
        bytes32 _productId,
        bytes32 _contentHash,
        uint256 nonce,
        uint256 expiry
    ) internal view returns (IReviewRegistry.Sig memory) {
        bytes memory sig = EIP712Helpers.signReviewCommitment(
            vm, pk, address(reviewReg), block.chainid, _agentId, _merchantId, _productId, _contentHash, nonce, expiry
        );
        return IReviewRegistry.Sig({nonce: nonce, expiry: expiry, agentSignature: sig});
    }

    function _publishOne() internal returns (uint256 reviewId) {
        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        vm.prank(oracleAddr);
        reviewId = reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function _setupEscrow(uint256 escrowId, uint256 _agentId, uint256 _merchantId, bytes32 _productId) internal {
        uint40 ts = uint40(block.timestamp);
        escrow.setEscrowRaw(
            escrowId,
            ICommissionEscrow.EscrowRecord({
                reviewerAgentId: 0,
                buyerAgentId: _agentId,
                buyerWallet: address(0),
                pausedTotalAtDeposit: 0,
                merchantId: _merchantId,
                productId: _productId,
                heldBackAmt: 100e6,
                cashbackAmt: 0,
                originalPurchaseAmt: 100e6,
                depositTimestamp: ts,
                windowEnd: ts + uint40(60 days),
                productType: 0,
                state: ICommissionEscrow.EscrowState.Holding,
                cashbackReleased: false
            })
        );
    }

    function _setupEscrow(uint256 escrowId) internal {
        _setupEscrow(escrowId, agentId, merchantId, PRODUCT_ID);
    }

    // =========================================================================
    // publishReview — oracle path
    // =========================================================================

    function test_PublishReview_OracleHappyPath() public {
        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        vm.prank(oracleAddr);
        uint256 reviewId = reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
        assertEq(reviewId, 1);
    }

    function test_PublishReview_EmitsReviewPublished() public {
        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        uint40 expectedTs = uint40(block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit IReviewRegistry.ReviewPublished(
            1, agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, expectedTs
        );
        vm.prank(oracleAddr);
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReview_ReturnsIncrementingReviewId() public {
        uint256 expiry = block.timestamp + 1 hours;
        IReviewRegistry.Sig memory sig1 = _sign(1, expiry);
        IReviewRegistry.Sig memory sig2 = _sign(2, expiry);

        vm.startPrank(oracleAddr);
        uint256 id1 = reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig1
        );
        uint256 id2 = reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig2
        );
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_PublishReview_StoresCorrectFields() public {
        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        uint40 expectedTs = uint40(block.timestamp);

        vm.prank(oracleAddr);
        uint256 reviewId = reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );

        IReviewRegistry.Review memory r = reviewReg.getReview(reviewId);
        assertEq(r.agentId, agentId);
        assertEq(r.merchantId, merchantId);
        assertEq(r.productId, PRODUCT_ID);
        assertEq(r.contentHash, CONTENT_HASH);
        assertEq(uint8(r.proofType), uint8(IReviewRegistry.ProofType.AdminApproved));
        assertEq(r.timestamp, expectedTs);
        assertEq(r.editedAt, 0);
    }

    function test_PublishReview_MarksNonceUsed() public {
        uint256 nonce = 42;
        IReviewRegistry.Sig memory sig = _sign(nonce, block.timestamp + 1 hours);

        assertFalse(reviewReg.isNonceUsed(agentId, nonce));
        vm.prank(oracleAddr);
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
        assertTrue(reviewReg.isNonceUsed(agentId, nonce));
    }

    function test_PublishReview_DifferentAgents_CanReuseSameNonce() public {
        uint256 agent2Pk = 0xB0B;
        address agentOwner2 = vm.addr(agent2Pk);
        uint256 agentId2 = agentRegistry.mint(agentOwner2);

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        IReviewRegistry.Sig memory sig1 = _sign(nonce, expiry);
        IReviewRegistry.Sig memory sig2 =
            _signFor(agent2Pk, agentId2, merchantId, PRODUCT_ID, CONTENT_HASH, nonce, expiry);

        vm.startPrank(oracleAddr);
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig1
        );
        reviewReg.publishReview(
            agentId2, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig2
        );
        vm.stopPrank();

        assertTrue(reviewReg.isNonceUsed(agentId, nonce));
        assertTrue(reviewReg.isNonceUsed(agentId2, nonce));
    }

    function test_PublishReview_Revert_NotOracle() public {
        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReview_Revert_InvalidProofTypeInSystemPurchase() public {
        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReviewRegistry.InvalidProofTypeForPath.selector, IReviewRegistry.ProofType.InSystemPurchase
            )
        );
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.InSystemPurchase, sig
        );
    }

    function test_PublishReview_Revert_SignatureExpired() public {
        uint256 expiry = block.timestamp - 1;
        IReviewRegistry.Sig memory sig = _sign(1, expiry);
        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.SignatureExpired.selector, expiry, block.timestamp));
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReview_Revert_NonceAlreadyUsed() public {
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        vm.startPrank(oracleAddr);
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, _sign(nonce, expiry)
        );

        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.NonceAlreadyUsed.selector, agentId, nonce));
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, _sign(nonce, expiry)
        );
        vm.stopPrank();
    }

    function test_PublishReview_Revert_InvalidAgentSignature_WrongSigner() public {
        uint256 wrongPk = 0xBAD;
        address wrongAddr = vm.addr(wrongPk);
        IReviewRegistry.Sig memory sig =
            _signFor(wrongPk, agentId, merchantId, PRODUCT_ID, CONTENT_HASH, 1, block.timestamp + 1 hours);

        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReviewRegistry.InvalidAgentSignature.selector, agentId, wrongAddr, agentOwner, address(0)
            )
        );
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReview_Revert_InvalidAgentSignature_WrongAgentId() public {
        // Sig committed to agentId+999 — when contract hashes the real agentId, recovery gives wrong address.
        IReviewRegistry.Sig memory sig =
            _signFor(agentPk, agentId + 999, merchantId, PRODUCT_ID, CONTENT_HASH, 1, block.timestamp + 1 hours);

        vm.prank(oracleAddr);
        vm.expectRevert(); // InvalidAgentSignature — recovered address not predictable
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReview_Revert_MerchantNotActive() public {
        merchantRegistry.setActiveRaw(merchantId, false);

        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.MerchantNotActive.selector, merchantId));
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReview_Revert_ProductNotActive() public {
        productRegistry.setActiveRaw(merchantId, PRODUCT_ID, false);

        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.ProductNotActive.selector, merchantId, PRODUCT_ID));
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReview_Revert_AgentNotRegistered() public {
        uint256 unknownAgentId = 9999;
        IReviewRegistry.Sig memory fakeSig;
        fakeSig.nonce = 1;
        fakeSig.expiry = block.timestamp + 1 hours;
        fakeSig.agentSignature = new bytes(0);

        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.AgentNotRegistered.selector, unknownAgentId));
        reviewReg.publishReview(
            unknownAgentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, fakeSig
        );
    }

    function test_PublishReview_AtExactExpiry_Succeeds() public {
        uint256 expiry = block.timestamp;
        IReviewRegistry.Sig memory sig = _sign(1, expiry);
        vm.prank(oracleAddr);
        uint256 reviewId = reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
        assertGt(reviewId, 0);
    }

    function test_PublishReview_OneSecondAfterExpiry_Reverts() public {
        uint256 expiry = block.timestamp;
        IReviewRegistry.Sig memory sig = _sign(1, expiry);

        vm.warp(block.timestamp + 1);

        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.SignatureExpired.selector, expiry, block.timestamp));
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    // =========================================================================
    // publishReviewWithEscrowProof — agent-direct path
    // =========================================================================

    function test_PublishReviewWithEscrowProof_HappyPath() public {
        _setupEscrow(1);
        vm.prank(agentOwner);
        uint256 reviewId = reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
        assertEq(reviewId, 1);
    }

    function test_PublishReviewWithEscrowProof_EmitsReviewPublished_InSystemPurchaseProofType() public {
        _setupEscrow(1);
        uint40 expectedTs = uint40(block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit IReviewRegistry.ReviewPublished(
            1, agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.InSystemPurchase, expectedTs
        );
        vm.prank(agentOwner);
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
    }

    function test_PublishReviewWithEscrowProof_MarksEscrowIdUsed() public {
        _setupEscrow(1);
        vm.startPrank(agentOwner);
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);

        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.EscrowMismatch.selector, uint256(1)));
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
        vm.stopPrank();
    }

    function test_PublishReviewWithEscrowProof_Revert_CallerNotAgentOwner() public {
        _setupEscrow(1);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.CallerNotAgentOwner.selector, agentId, stranger));
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
    }

    function test_PublishReviewWithEscrowProof_Revert_AgentIdMismatch() public {
        _setupEscrow(1, agentId + 1, merchantId, PRODUCT_ID);

        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.EscrowMismatch.selector, uint256(1)));
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
    }

    function test_PublishReviewWithEscrowProof_Revert_EscrowIdAlreadyUsed() public {
        _setupEscrow(1);
        vm.startPrank(agentOwner);
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);

        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.EscrowMismatch.selector, uint256(1)));
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
        vm.stopPrank();
    }

    /// @dev The escrow proves the purchase happened while the product was active (SplitRouter
    ///      gates deposit on it), so deactivating it afterwards must not bury the buyer's review.
    function test_PublishReviewWithEscrowProof_InactiveProduct_StillPublishes() public {
        _setupEscrow(1);
        productRegistry.setActiveRaw(merchantId, PRODUCT_ID, false);

        vm.prank(agentOwner);
        uint256 reviewId = reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
        assertEq(reviewReg.getReview(reviewId).agentId, agentId);
        assertTrue(reviewReg.getReview(reviewId).proofType == IReviewRegistry.ProofType.InSystemPurchase);
    }

    /// @dev A merchant suspending itself must not silence buyers who already paid it.
    function test_PublishReviewWithEscrowProof_InactiveMerchant_StillPublishes() public {
        _setupEscrow(1);
        merchantRegistry.setActiveRaw(merchantId, false);

        vm.prank(agentOwner);
        uint256 reviewId = reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
        assertEq(reviewReg.getReview(reviewId).merchantId, merchantId);
    }

    /// @dev The suppression path the check used to open: deactivate mid-window, block the review,
    ///      let the cashback fall back to the reviewer, reactivate afterwards.
    function test_PublishReviewWithEscrowProof_MerchantCannotSuppressThenReactivate() public {
        _setupEscrow(1);
        productRegistry.setActiveRaw(merchantId, PRODUCT_ID, false);
        merchantRegistry.setActiveRaw(merchantId, false);

        vm.prank(agentOwner);
        uint256 reviewId = reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);

        productRegistry.setActiveRaw(merchantId, PRODUCT_ID, true);
        merchantRegistry.setActiveRaw(merchantId, true);
        assertTrue(reviewReg.exists(reviewId), "review survives the merchant's round trip");
    }

    /// @dev The oracle path keeps the check: it has no escrow to prove the purchase.
    function test_PublishReview_OraclePath_StillRequiresActiveProduct() public {
        productRegistry.setActiveRaw(merchantId, PRODUCT_ID, false);

        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours);
        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.ProductNotActive.selector, merchantId, PRODUCT_ID));
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReviewWithEscrowProof_Revert_AgentNotRegistered() public {
        uint256 unknownAgentId = 9999;

        vm.prank(makeAddr("anyone"));
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.AgentNotRegistered.selector, unknownAgentId));
        reviewReg.publishReviewWithEscrowProof(unknownAgentId, CONTENT_HASH, 1);
    }

    // =========================================================================
    // read functions
    // =========================================================================

    function test_GetReview_ReturnsCorrectStruct() public {
        uint40 ts = uint40(block.timestamp);
        uint256 reviewId = _publishOne();
        IReviewRegistry.Review memory r = reviewReg.getReview(reviewId);
        assertEq(r.agentId, agentId);
        assertEq(r.merchantId, merchantId);
        assertEq(r.productId, PRODUCT_ID);
        assertEq(r.contentHash, CONTENT_HASH);
        assertEq(uint8(r.proofType), uint8(IReviewRegistry.ProofType.AdminApproved));
        assertEq(r.timestamp, ts);
        assertEq(r.editedAt, 0);
    }

    function test_GetReview_Revert_ReviewNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.ReviewNotFound.selector, uint256(1)));
        reviewReg.getReview(1);
    }

    function test_Exists_TrueForMinted() public {
        uint256 reviewId = _publishOne();
        assertTrue(reviewReg.exists(reviewId));
    }

    function test_Exists_FalseForZero() public view {
        assertFalse(reviewReg.exists(0));
    }

    function test_Exists_FalseForUnminted() public view {
        assertFalse(reviewReg.exists(999));
    }

    function test_TotalReviews_ZeroInitially() public view {
        assertEq(reviewReg.totalReviews(), 0);
    }

    function test_TotalReviews_IncrementsCorrectly() public {
        assertEq(reviewReg.totalReviews(), 0);
        _publishOne();
        assertEq(reviewReg.totalReviews(), 1);
        IReviewRegistry.Sig memory sig2 = _sign(2, block.timestamp + 1 hours);
        vm.prank(oracleAddr);
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig2
        );
        assertEq(reviewReg.totalReviews(), 2);
    }

    function test_IsNonceUsed_FalseBeforePublish() public view {
        assertFalse(reviewReg.isNonceUsed(agentId, 1));
    }

    function test_IsNonceUsed_TrueAfterPublish() public {
        _publishOne(); // uses nonce 1
        assertTrue(reviewReg.isNonceUsed(agentId, 1));
    }

    // =========================================================================
    // updateReviewContent
    // =========================================================================

    function _publishBuyerReview() internal returns (uint256 reviewId) {
        _setupEscrow(1);
        vm.prank(agentOwner);
        reviewId = reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
    }

    function test_UpdateReviewContent_HappyPath() public {
        uint256 reviewId = _publishBuyerReview();
        bytes32 newHash = keccak256("updated content");

        vm.prank(agentOwner);
        reviewReg.updateReviewContent(reviewId, newHash);

        IReviewRegistry.Review memory r = reviewReg.getReview(reviewId);
        assertEq(r.contentHash, newHash);
        assertEq(r.editedAt, uint40(block.timestamp));
    }

    function test_UpdateReviewContent_EmitsReviewContentUpdated() public {
        uint256 reviewId = _publishBuyerReview();
        bytes32 newHash = keccak256("updated content");
        uint40 expectedTs = uint40(block.timestamp);

        vm.expectEmit(true, false, false, true);
        emit IReviewRegistry.ReviewContentUpdated(reviewId, newHash, expectedTs);

        vm.prank(agentOwner);
        reviewReg.updateReviewContent(reviewId, newHash);
    }

    function test_UpdateReviewContent_OriginalTimestampUnchanged() public {
        uint40 publishedAt = uint40(block.timestamp);
        uint256 reviewId = _publishBuyerReview();

        vm.warp(block.timestamp + 1 days);
        bytes32 newHash = keccak256("updated content");
        vm.prank(agentOwner);
        reviewReg.updateReviewContent(reviewId, newHash);

        IReviewRegistry.Review memory r = reviewReg.getReview(reviewId);
        assertEq(r.timestamp, publishedAt);
    }

    function test_UpdateReviewContent_AtWindowBoundary_Succeeds() public {
        uint256 reviewId = _publishBuyerReview();
        vm.warp(block.timestamp + 7 days);

        bytes32 newHash = keccak256("boundary edit");
        vm.prank(agentOwner);
        reviewReg.updateReviewContent(reviewId, newHash);

        assertEq(reviewReg.getReview(reviewId).contentHash, newHash);
    }

    function test_UpdateReviewContent_Revert_EditWindowClosed() public {
        uint256 reviewId = _publishBuyerReview();
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.EditWindowClosed.selector, reviewId));
        reviewReg.updateReviewContent(reviewId, keccak256("late edit"));
    }

    function test_UpdateReviewContent_Revert_NotInSystemPurchase() public {
        uint256 reviewId = _publishOne(); // oracle path, AdminApproved
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.NotEditablePath.selector, reviewId));
        reviewReg.updateReviewContent(reviewId, keccak256("edit attempt"));
    }

    function test_UpdateReviewContent_Revert_CallerNotAgentOwner() public {
        uint256 reviewId = _publishBuyerReview();
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.CallerNotAgentOwner.selector, agentId, stranger));
        reviewReg.updateReviewContent(reviewId, keccak256("stranger edit"));
    }

    function test_UpdateReviewContent_Revert_ReviewNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.ReviewNotFound.selector, uint256(999)));
        reviewReg.updateReviewContent(999, keccak256("ghost edit"));
    }

    function test_UpdateReviewContent_MultipleEditsWithinWindow() public {
        uint256 reviewId = _publishBuyerReview();
        bytes32 hash1 = keccak256("edit one");
        bytes32 hash2 = keccak256("edit two");

        vm.prank(agentOwner);
        reviewReg.updateReviewContent(reviewId, hash1);
        assertEq(reviewReg.getReview(reviewId).contentHash, hash1);

        vm.warp(block.timestamp + 1 days);
        vm.prank(agentOwner);
        reviewReg.updateReviewContent(reviewId, hash2);
        assertEq(reviewReg.getReview(reviewId).contentHash, hash2);
    }

    // =========================================================================
    // agentWallet authorization — publishReviewWithEscrowProof
    // =========================================================================

    function test_PublishReviewWithEscrowProof_AgentWallet_Succeeds() public {
        address agentWallet = makeAddr("agentWallet");
        agentRegistry.setWallet(agentId, agentWallet);
        _setupEscrow(1);

        vm.prank(agentWallet);
        uint256 reviewId = reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
        assertEq(reviewId, 1);
    }

    function test_PublishReviewWithEscrowProof_AgentWallet_ProofTypeIsInSystemPurchase() public {
        address agentWallet = makeAddr("agentWallet");
        agentRegistry.setWallet(agentId, agentWallet);
        _setupEscrow(1);

        vm.prank(agentWallet);
        uint256 reviewId = reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
        assertEq(uint8(reviewReg.getReview(reviewId).proofType), uint8(IReviewRegistry.ProofType.InSystemPurchase));
    }

    function test_PublishReviewWithEscrowProof_OwnerStillAuthorizedWhenWalletSet() public {
        agentRegistry.setWallet(agentId, makeAddr("agentWallet"));
        _setupEscrow(1);

        // NFT owner can still call even after agentWallet is configured
        vm.prank(agentOwner);
        uint256 reviewId = reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
        assertEq(reviewId, 1);
    }

    function test_PublishReviewWithEscrowProof_ZeroWalletNotAuthorized() public {
        // agentWallet not set (zero); a third address must still be rejected
        _setupEscrow(1);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.CallerNotAgentOwner.selector, agentId, stranger));
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
    }

    function test_PublishReviewWithEscrowProof_WrongWalletNotAuthorized() public {
        agentRegistry.setWallet(agentId, makeAddr("correctWallet"));
        _setupEscrow(1);
        address wrongWallet = makeAddr("wrongWallet");

        vm.prank(wrongWallet);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.CallerNotAgentOwner.selector, agentId, wrongWallet));
        reviewReg.publishReviewWithEscrowProof(agentId, CONTENT_HASH, 1);
    }

    // =========================================================================
    // agentWallet authorization — updateReviewContent
    // =========================================================================

    function test_UpdateReviewContent_AgentWallet_Succeeds() public {
        address agentWallet = makeAddr("agentWallet");
        agentRegistry.setWallet(agentId, agentWallet);
        uint256 reviewId = _publishBuyerReview();
        bytes32 newHash = keccak256("wallet updated content");

        vm.prank(agentWallet);
        reviewReg.updateReviewContent(reviewId, newHash);

        assertEq(reviewReg.getReview(reviewId).contentHash, newHash);
    }

    function test_UpdateReviewContent_AgentWallet_SetsEditedAt() public {
        address agentWallet = makeAddr("agentWallet");
        agentRegistry.setWallet(agentId, agentWallet);
        uint256 reviewId = _publishBuyerReview();

        vm.warp(block.timestamp + 1 hours);
        uint40 editTs = uint40(block.timestamp);

        vm.prank(agentWallet);
        reviewReg.updateReviewContent(reviewId, keccak256("wallet edit"));

        assertEq(reviewReg.getReview(reviewId).editedAt, editTs);
    }

    function test_UpdateReviewContent_ZeroWalletNotAuthorized() public {
        // agentWallet not set; stranger must be rejected
        uint256 reviewId = _publishBuyerReview();
        address stranger = makeAddr("stranger2");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.CallerNotAgentOwner.selector, agentId, stranger));
        reviewReg.updateReviewContent(reviewId, keccak256("stranger edit"));
    }

    function test_UpdateReviewContent_WrongWalletNotAuthorized() public {
        agentRegistry.setWallet(agentId, makeAddr("correctWallet"));
        uint256 reviewId = _publishBuyerReview();
        address wrongWallet = makeAddr("wrongWallet");

        vm.prank(wrongWallet);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.CallerNotAgentOwner.selector, agentId, wrongWallet));
        reviewReg.updateReviewContent(reviewId, keccak256("wrong wallet edit"));
    }

    // =========================================================================
    // agentWallet authorization — publishReview oracle path (EIP-712 sig check)
    // =========================================================================

    function test_PublishReview_AgentWalletSig_Succeeds() public {
        agentRegistry.setWallet(agentId, agentWalletAddr);
        IReviewRegistry.Sig memory sig =
            _signFor(agentWalletPk, agentId, merchantId, PRODUCT_ID, CONTENT_HASH, 1, block.timestamp + 1 hours);

        vm.prank(oracleAddr);
        uint256 reviewId = reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
        assertEq(reviewId, 1);
    }

    function test_PublishReview_OwnerSigStillWorksWhenWalletSet() public {
        agentRegistry.setWallet(agentId, agentWalletAddr);
        IReviewRegistry.Sig memory sig = _sign(1, block.timestamp + 1 hours); // signed by agentPk (owner)

        vm.prank(oracleAddr);
        uint256 reviewId = reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
        assertEq(reviewId, 1);
    }

    function test_PublishReview_AgentWalletSig_WalletNotSet_Reverts() public {
        // agentWallet not configured; signing with wallet key must be rejected
        IReviewRegistry.Sig memory sig =
            _signFor(agentWalletPk, agentId, merchantId, PRODUCT_ID, CONTENT_HASH, 1, block.timestamp + 1 hours);

        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReviewRegistry.InvalidAgentSignature.selector, agentId, agentWalletAddr, agentOwner, address(0)
            )
        );
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }

    function test_PublishReview_AgentWalletSig_WrongKey_Reverts() public {
        agentRegistry.setWallet(agentId, agentWalletAddr);
        uint256 thirdPk = 0xDEAD;
        address thirdAddr = vm.addr(thirdPk);
        IReviewRegistry.Sig memory sig =
            _signFor(thirdPk, agentId, merchantId, PRODUCT_ID, CONTENT_HASH, 1, block.timestamp + 1 hours);

        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReviewRegistry.InvalidAgentSignature.selector, agentId, thirdAddr, agentOwner, agentWalletAddr
            )
        );
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, CONTENT_HASH, IReviewRegistry.ProofType.AdminApproved, sig
        );
    }
}
