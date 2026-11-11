// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC3009Signer} from "../helpers/ERC3009Signer.sol";

/// @dev Cross-language ERC-3009 digest vector.
///
///      The same fixed authorization is hashed in three places that must agree exactly, or a
///      signature produced by one is rejected by another:
///
///      - Solidity — this file
///      - Go — backend/internal/signing/erc3009_vector_test.go
///      - TypeScript — frontend/app/buy/erc3009Vector.test.ts
///
///      All three assert WANT_RECEIVE_DIGEST below. This is the check that was missing while
///      three independent implementations quietly disagreed with the token they all sign for.
///
///      Regenerating the expected value is not a fix. If a change makes these disagree, one of
///      the three is wrong — find which with test/fork/SplitRouterUSDCFork.t.sol, which asserts
///      against real Circle USDC rather than against us.
contract ERC3009VectorTest is Test {
    // Address of VECTOR_SIGNER_KEY — part of the hashed struct, so it is fixed too.
    address internal constant VECTOR_FROM = 0x2c7536E3605D9C16a7a3D7b1898e529396a65c23;
    address internal constant VECTOR_TO = 0x2222222222222222222222222222222222222222;
    uint256 internal constant VECTOR_VALUE = 1_000_000; // 1 USDC, 6 decimals
    uint256 internal constant VECTOR_VALID_AFTER = 0;
    uint256 internal constant VECTOR_VALID_BEFORE = 1_893_456_000; // 2030-01-01T00:00:00Z
    bytes32 internal constant VECTOR_NONCE = bytes32(uint256(0xff));

    // Base mainnet: Circle USDC, name "USD Coin", version "2".
    uint256 internal constant VECTOR_CHAIN_ID = 8453;
    address internal constant VECTOR_TOKEN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev go-ethereum's canonical test key, so the recovered address is a constant too.
    uint256 internal constant VECTOR_SIGNER_KEY = 0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318;

    bytes32 internal constant WANT_RECEIVE_DIGEST = 0x6c522c286cd69c50477f7362c599451191365984c518ebba8eb0bdadc3a3f96a;

    function _vectorAuth() internal pure returns (ERC3009Signer.Authorization memory) {
        return ERC3009Signer.Authorization({
            from: VECTOR_FROM,
            to: VECTOR_TO,
            value: VECTOR_VALUE,
            validAfter: VECTOR_VALID_AFTER,
            validBefore: VECTOR_VALID_BEFORE,
            nonce: VECTOR_NONCE
        });
    }

    function _vectorDomain() internal pure returns (bytes32) {
        return ERC3009Signer.domainSeparator("USD Coin", "2", VECTOR_CHAIN_ID, VECTOR_TOKEN);
    }

    function test_ReceiveDigest_MatchesCrossLanguageVector() public pure {
        bytes32 digest =
            ERC3009Signer.digest(ERC3009Signer.RECEIVE_WITH_AUTHORIZATION_TYPEHASH, _vectorDomain(), _vectorAuth());
        assertEq(digest, WANT_RECEIVE_DIGEST, "Solidity disagrees with the Go and TypeScript vector");
    }

    /// @dev Closes the loop: a signature over the pinned digest must ecrecover to the vector's
    ///      `from`. Without this the digest could be right while signing verified something else.
    function test_ReceiveDigest_RecoversTheVectorSigner() public pure {
        assertEq(vm.addr(VECTOR_SIGNER_KEY), VECTOR_FROM, "VECTOR_FROM is not VECTOR_SIGNER_KEY's address");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VECTOR_SIGNER_KEY, WANT_RECEIVE_DIGEST);
        assertEq(ecrecover(WANT_RECEIVE_DIGEST, v, r, s), VECTOR_FROM);
    }

    /// @dev The property the whole ticket rests on: identical fields, different struct name,
    ///      different digest.
    function test_TransferDigest_DiffersFromReceive() public pure {
        bytes32 transferDigest =
            ERC3009Signer.digest(ERC3009Signer.TRANSFER_WITH_AUTHORIZATION_TYPEHASH, _vectorDomain(), _vectorAuth());
        assertTrue(transferDigest != WANT_RECEIVE_DIGEST, "the two ERC-3009 typehashes are not distinct");
    }
}
