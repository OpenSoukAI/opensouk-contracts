// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";

/// @dev Configurable stub. setReviewRaw() inserts a review record directly.
///      setExistsRaw() controls whether a reviewId is considered to exist.
contract MockReviewRegistry is IReviewRegistry {
    mapping(uint256 => Review) private _reviews;
    mapping(uint256 => bool) private _exists;
    uint256 private _nextId = 1;

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setReviewRaw(uint256 reviewId, Review calldata review) external {
        _reviews[reviewId] = review;
        _exists[reviewId] = true;
    }

    function setExistsRaw(uint256 reviewId, bool exists_) external {
        _exists[reviewId] = exists_;
    }

    // -------------------------------------------------------------------------
    // IReviewRegistry
    // -------------------------------------------------------------------------

    function publishReview(
        uint256 agentId,
        uint256 merchantId,
        bytes32 productId,
        bytes32 contentHash,
        ProofType proofType,
        Sig memory eip712sig
    ) external returns (uint256 reviewId) {
        reviewId = _nextId++;
        _reviews[reviewId] = Review({
            agentId: agentId,
            merchantId: merchantId,
            productId: productId,
            contentHash: contentHash,
            proofType: proofType,
            timestamp: uint40(block.timestamp),
            editedAt: 0
        });
        _exists[reviewId] = true;
    }

    function publishReviewWithEscrowProof(uint256 agentId, bytes32 contentHash, uint256)
        external
        returns (uint256 reviewId)
    {
        reviewId = _nextId++;
        _reviews[reviewId] = Review({
            agentId: agentId,
            merchantId: 0,
            productId: bytes32(0),
            contentHash: contentHash,
            proofType: ProofType.InSystemPurchase,
            timestamp: uint40(block.timestamp),
            editedAt: 0
        });
        _exists[reviewId] = true;
    }

    function updateReviewContent(uint256 reviewId, bytes32 newContentHash) external {
        _reviews[reviewId].contentHash = newContentHash;
        _reviews[reviewId].editedAt = uint40(block.timestamp);
    }

    function getReview(uint256 reviewId) external view returns (Review memory) {
        return _reviews[reviewId];
    }

    function exists(uint256 reviewId) external view returns (bool) {
        return _exists[reviewId];
    }

    function totalReviews() external view returns (uint256) {
        return _nextId - 1;
    }

    function isNonceUsed(uint256, uint256) external pure returns (bool) {
        return false;
    }
}
