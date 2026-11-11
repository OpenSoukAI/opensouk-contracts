// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";

/// @dev Off-chain ERC-3009 authorization signing for tests.
///
/// ERC-3009 defines two authorization structs with identical fields and different names, so they
/// produce different EIP-712 digests and are NOT interchangeable. `SplitRouter.route()` calls
/// `receiveWithAuthorization`, which real Circle USDC validates against the
/// `ReceiveWithAuthorization` typehash — so `signReceive` is the only variant that can settle.
///
/// `signTransfer` exists solely so tests can prove the wrong typehash is rejected. It is the
/// signature every signer in the stack once produced, and no production path should
/// ever call it.
library ERC3009Signer {
    /// @dev What `SplitRouter.route()` needs. Circle FiatTokenV2_2 `receiveWithAuthorization`.
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @dev The wrong one for this rail. Same fields, different name, different digest.
    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @dev Grouped to keep the digest helpers out of stack-too-deep territory.
    struct Authorization {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    /// @notice EIP-712 domain separator for a Circle-style USDC deployment.
    function domainSeparator(string memory name, string memory version, uint256 chainId, address token)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                token
            )
        );
    }

    /// @notice EIP-712 digest for `auth` under `typehash`, in `domainSep`'s domain.
    function digest(bytes32 typehash, bytes32 domainSep, Authorization memory auth) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(typehash, auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }

    /// @notice Sign `auth` under the `ReceiveWithAuthorization` typehash — the settleable variant.
    function signReceive(Vm vm, uint256 signerPk, bytes32 domainSep, Authorization memory auth)
        internal
        pure
        returns (ISplitRouter.ERC3009Params memory)
    {
        return _sign(vm, signerPk, RECEIVE_WITH_AUTHORIZATION_TYPEHASH, domainSep, auth);
    }

    /// @notice Sign `auth` under the `TransferWithAuthorization` typehash — rejected by the router's
    ///         token call. For negative tests only; see the library docstring.
    function signTransfer(Vm vm, uint256 signerPk, bytes32 domainSep, Authorization memory auth)
        internal
        pure
        returns (ISplitRouter.ERC3009Params memory)
    {
        return _sign(vm, signerPk, TRANSFER_WITH_AUTHORIZATION_TYPEHASH, domainSep, auth);
    }

    function _sign(Vm vm, uint256 signerPk, bytes32 typehash, bytes32 domainSep, Authorization memory auth)
        private
        pure
        returns (ISplitRouter.ERC3009Params memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest(typehash, domainSep, auth));
        return ISplitRouter.ERC3009Params({
            validAfter: auth.validAfter, validBefore: auth.validBefore, nonce: auth.nonce, v: v, r: r, s: s
        });
    }
}
