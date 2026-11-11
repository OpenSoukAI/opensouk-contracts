// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @dev Off-chain EIP-712 signing helpers for ReviewRegistry tests.
library EIP712Helpers {
    bytes32 internal constant REVIEW_COMMITMENT_TYPEHASH = keccak256(
        "ReviewCommitment(uint256 agentId,uint256 merchantId,bytes32 productId,bytes32 contentHash,uint256 nonce,uint256 expiry)"
    );

    function domainSeparator(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ReviewRegistry"),
                keccak256("1"),
                chainId,
                verifyingContract
            )
        );
    }

    function hashCommitment(
        uint256 agentId,
        uint256 merchantId,
        bytes32 productId,
        bytes32 contentHash,
        uint256 nonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(REVIEW_COMMITMENT_TYPEHASH, agentId, merchantId, productId, contentHash, nonce, expiry)
        );
    }

    function buildDigest(
        address verifyingContract,
        uint256 chainId,
        uint256 agentId,
        uint256 merchantId,
        bytes32 productId,
        bytes32 contentHash,
        uint256 nonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator(verifyingContract, chainId),
                hashCommitment(agentId, merchantId, productId, contentHash, nonce, expiry)
            )
        );
    }

    function signReviewCommitment(
        Vm vm,
        uint256 signerPk,
        address verifyingContract,
        uint256 chainId,
        uint256 agentId,
        uint256 merchantId,
        bytes32 productId,
        bytes32 contentHash,
        uint256 nonce,
        uint256 expiry
    ) internal pure returns (bytes memory sig) {
        bytes32 digest = buildDigest(
            verifyingContract, chainId, agentId, merchantId, productId, contentHash, nonce, expiry
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
