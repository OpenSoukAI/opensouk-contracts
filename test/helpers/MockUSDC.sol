// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test USDC. Verifies ERC-3009 authorizations the way real Circle USDC does, against the
///      `ReceiveWithAuthorization` typehash (REF-269).
///
///      Before REF-269 this mock accepted `v, r, s` and verified NOTHING — it called `_transfer`
///      directly. That made the whole Foundry suite signature-blind, which is why every signer in
///      the stack could sign the wrong typehash for months with a green suite. A mock that agrees
///      with its caller instead of with the real dependency is not a test double, it is a mask.
///
///      Only `receiveWithAuthorization` lives here because that is the only ERC-3009 entry point
///      `SplitRouter.route()` calls. `src/MockUSDC.sol` is the deployable testnet token and mirrors
///      Circle FiatTokenV2_2's full surface.
contract MockUSDC is ERC20 {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev What Circle USDC verifies inside `receiveWithAuthorization`. A
    ///      `TransferWithAuthorization` signature has the same fields under a different struct
    ///      name, so it produces a different digest and must be rejected here.
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 private immutable _DOMAIN_SEPARATOR;

    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    error AuthNotYetValid(uint256 validAfter, uint256 current);
    error AuthExpired(uint256 validBefore, uint256 current);
    error AuthNonceAlreadyUsed(address from, bytes32 nonce);
    error CallerMustBePayee(address caller, address to);
    error InvalidSignature();

    constructor() ERC20("USD Coin", "USDC") {
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("USD Coin")), keccak256(bytes("2")), block.chainid, address(this)
            )
        );
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _DOMAIN_SEPARATOR;
    }

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (msg.sender != to) revert CallerMustBePayee(msg.sender, to);
        if (block.timestamp <= validAfter) revert AuthNotYetValid(validAfter, block.timestamp);
        if (block.timestamp >= validBefore) revert AuthExpired(validBefore, block.timestamp);
        if (_authorizationStates[from][nonce]) revert AuthNonceAlreadyUsed(from, nonce);

        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != from) revert InvalidSignature();

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }
}
