// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {EIP712Helpers} from "../helpers/EIP712Helpers.sol";
import {ReviewRegistry} from "../../src/ReviewRegistry.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";
import {IProductRegistry} from "../../src/interfaces/IProductRegistry.sol";

contract ReviewRegistryFuzz is MockFixture {
    using EIP712Helpers for *;

    ReviewRegistry internal reviewReg;

    address internal oracleAddr = makeAddr("oracle");
    uint256 internal agentPk = 0xA11CE;
    address internal agentOwner;
    uint256 internal agentId;
    uint256 internal merchantId;
    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");

    function setUp() public override {
        super.setUp();
        reviewReg = new ReviewRegistry(address(par), admin);
        vm.startPrank(admin);
        reviewReg.grantRole(keccak256("ORACLE_ROLE"), oracleAddr);
        vm.stopPrank();

        agentOwner = vm.addr(agentPk);
        agentId = agentRegistry.mint(agentOwner);
        merchantId = agentRegistry.mint(makeAddr("merchant"));
        merchantRegistry.setActiveRaw(merchantId, true); // ReviewRegistry checks the merchant too
        productRegistry.setProductRaw(
            merchantId,
            PRODUCT_ID,
            IProductRegistry.Product({
                merchantId: merchantId,
                productId: PRODUCT_ID,
                commissionBps: 1000,
                active: true,
                productCardURI: "",
                createdAt: uint40(block.timestamp),
                productType: IProductRegistry.ProductType.Repeat
            })
        );
    }

    /// @dev Nonce reuse always reverts, regardless of nonce value.
    function testFuzz_NonceReuse_AlwaysReverts(uint256 nonce) public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32 contentHash = keccak256("content");

        bytes memory sig = EIP712Helpers.signReviewCommitment(
            vm, agentPk, address(reviewReg), block.chainid, agentId, merchantId, PRODUCT_ID, contentHash, nonce, expiry
        );

        IReviewRegistry.Sig memory eip712Sig = IReviewRegistry.Sig({nonce: nonce, expiry: expiry, agentSignature: sig});

        vm.startPrank(oracleAddr);
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, contentHash, IReviewRegistry.ProofType.AdminApproved, eip712Sig
        );

        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.NonceAlreadyUsed.selector, agentId, nonce));
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, contentHash, IReviewRegistry.ProofType.AdminApproved, eip712Sig
        );
        vm.stopPrank();
    }

    /// @dev Any sig with expiry < block.timestamp reverts SignatureExpired.
    function testFuzz_ExpiredSig_AlwaysReverts(uint256 expiry) public {
        expiry = bound(expiry, 0, block.timestamp - 1);

        uint256 nonce = 0;
        bytes32 contentHash = keccak256("content");

        bytes memory sig = EIP712Helpers.signReviewCommitment(
            vm, agentPk, address(reviewReg), block.chainid, agentId, merchantId, PRODUCT_ID, contentHash, nonce, expiry
        );

        IReviewRegistry.Sig memory eip712Sig = IReviewRegistry.Sig({nonce: nonce, expiry: expiry, agentSignature: sig});

        vm.prank(oracleAddr);
        vm.expectRevert(abi.encodeWithSelector(IReviewRegistry.SignatureExpired.selector, expiry, block.timestamp));
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, contentHash, IReviewRegistry.ProofType.AdminApproved, eip712Sig
        );
    }

    /// @dev Any sig signed by a different private key reverts InvalidAgentSignature.
    function testFuzz_WrongSigner_AlwaysReverts(uint256 wrongPk) public {
        // Constrain to valid secp256k1 private key range, exclude agentPk.
        wrongPk = bound(wrongPk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(wrongPk != agentPk);

        uint256 nonce = 0;
        uint256 expiry = block.timestamp + 1 days;
        bytes32 contentHash = keccak256("content");

        bytes memory sig = EIP712Helpers.signReviewCommitment(
            vm, wrongPk, address(reviewReg), block.chainid, agentId, merchantId, PRODUCT_ID, contentHash, nonce, expiry
        );

        IReviewRegistry.Sig memory eip712Sig = IReviewRegistry.Sig({nonce: nonce, expiry: expiry, agentSignature: sig});

        address recovered = vm.addr(wrongPk);
        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReviewRegistry.InvalidAgentSignature.selector, agentId, recovered, agentOwner, address(0)
            )
        );
        reviewReg.publishReview(
            agentId, merchantId, PRODUCT_ID, contentHash, IReviewRegistry.ProofType.AdminApproved, eip712Sig
        );
    }

    /// @dev totalReviews() always equals the count of successful publishReview calls.
    function testFuzz_TotalReviews_MatchesPublishCount(uint8 count) public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32 contentHash = keccak256("content");

        vm.startPrank(oracleAddr);
        for (uint256 i = 0; i < count; i++) {
            bytes memory sig = EIP712Helpers.signReviewCommitment(
                vm, agentPk, address(reviewReg), block.chainid, agentId, merchantId, PRODUCT_ID, contentHash, i, expiry
            );
            IReviewRegistry.Sig memory eip712Sig = IReviewRegistry.Sig({nonce: i, expiry: expiry, agentSignature: sig});
            reviewReg.publishReview(
                agentId, merchantId, PRODUCT_ID, contentHash, IReviewRegistry.ProofType.AdminApproved, eip712Sig
            );
        }
        vm.stopPrank();

        assertEq(reviewReg.totalReviews(), count);
    }

    /// @dev Signature bound to one agentId cannot be replayed for a different agentId.
    function testFuzz_Sig_NotReplayableAcrossAgents(uint256 targetAgentId) public {
        // Derive a target owner from fuzz input; must differ from agentOwner so
        // the recovered address (garbage from the mismatched digest) can't accidentally match.
        address targetOwner = address(uint160(bound(targetAgentId, 1, type(uint160).max)));
        vm.assume(targetOwner != agentOwner);

        uint256 freshId = agentRegistry.mint(targetOwner); // freshId != agentId

        uint256 expiry = block.timestamp + 1 days;
        bytes32 contentHash = keccak256("content");

        // Sig is bound to agentId — digest includes agentId in the typehash.
        bytes memory sig = EIP712Helpers.signReviewCommitment(
            vm, agentPk, address(reviewReg), block.chainid, agentId, merchantId, PRODUCT_ID, contentHash, 0, expiry
        );
        IReviewRegistry.Sig memory eip712Sig = IReviewRegistry.Sig({nonce: 0, expiry: expiry, agentSignature: sig});

        // Compute the digest the contract will use when verifying for freshId.
        // ecrecover over the wrong digest yields a deterministic but garbage address.
        bytes32 wrongDigest = EIP712Helpers.buildDigest(
            address(reviewReg), block.chainid, freshId, merchantId, PRODUCT_ID, contentHash, 0, expiry
        );
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        address recovered = ecrecover(wrongDigest, v, r, s);

        vm.prank(oracleAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReviewRegistry.InvalidAgentSignature.selector, freshId, recovered, targetOwner, address(0)
            )
        );
        reviewReg.publishReview(
            freshId, merchantId, PRODUCT_ID, contentHash, IReviewRegistry.ProofType.AdminApproved, eip712Sig
        );
    }

    /// @dev reviewId always starts at 1 and increments by 1 per publish.
    function testFuzz_ReviewId_StrictlyIncreasing(uint8 count) public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32 contentHash = keccak256("content");

        vm.startPrank(oracleAddr);
        for (uint256 i = 0; i < count; i++) {
            bytes memory sig = EIP712Helpers.signReviewCommitment(
                vm, agentPk, address(reviewReg), block.chainid, agentId, merchantId, PRODUCT_ID, contentHash, i, expiry
            );
            IReviewRegistry.Sig memory eip712Sig = IReviewRegistry.Sig({nonce: i, expiry: expiry, agentSignature: sig});
            uint256 reviewId = reviewReg.publishReview(
                agentId, merchantId, PRODUCT_ID, contentHash, IReviewRegistry.ProofType.AdminApproved, eip712Sig
            );
            assertEq(reviewId, i + 1);
        }
        vm.stopPrank();
    }
}
