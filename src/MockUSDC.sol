// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet-only USDC mock with ERC-3009 support, mirroring Circle FiatTokenV2_2.
///
/// @dev Exposes BOTH ERC-3009 entry points, each verifying its own typehash:
///
///      - `transferWithAuthorization` — `TransferWithAuthorization`, callable by anyone.
///      - `receiveWithAuthorization` — `ReceiveWithAuthorization`, requires `to == msg.sender`.
///
///      The two structs carry identical fields under different names, so they produce different
///      EIP-712 digests and are not interchangeable. `SplitRouter.route()` calls
///      `receiveWithAuthorization`, so only a Receive-typehash signature can settle the x402 rail.
///
///      This contract previously verified the **Transfer** typehash inside
///      `receiveWithAuthorization`, with a comment explaining that it "matches x402 library and
///      frontend: they sign TransferWithAuthorization". That made it agree with our own signers
///      instead of with the token it stands in for, and it is why the wrong typehash shipped
///      everywhere unnoticed (REF-269). A mock's job is to mirror the real dependency; where the
///      caller disagrees with the dependency, the caller is what changes.
///
///      Divergences from FiatTokenV2_2, both deliberate: custom errors instead of require strings
///      (better traces in tests), and an unrestricted `mint`. The blacklist is a QUERY only —
///      `isBlacklisted` answers, and `setBlacklisted` lets a harness stage a frozen address, but
///      transfers here never enforce it. Real USDC packs that bit into the balance slot and does
///      enforce it. Behaviour against the genuine token is covered by
///      `test/fork/SplitRouterUSDCFork.t.sol`, not by this contract.
contract MockUSDC is ERC20 {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Verified by `transferWithAuthorization`. Not usable on the x402 rail.
    bytes32 private constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @dev Verified by `receiveWithAuthorization` — what `SplitRouter.route()` needs.
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 private constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    bytes32 private immutable _DOMAIN_SEPARATOR;

    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    /// @dev Frozen addresses, for `isBlacklisted` only. Never consulted by a transfer here.
    mapping(address => bool) private _blacklisted;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

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

    /// @notice Mirrors Circle's `isBlacklisted` so a caller can pre-flight a frozen payout
    ///         recipient (REF-274).
    /// @dev The backend reads this before settling an MPP charge: on real USDC a frozen recipient
    ///      reverts the whole `splitCharge`, stranding funds already pooled in the router. Without
    ///      the function present the read would revert, which is indistinguishable from an
    ///      unhealthy node.
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    /// @notice Test-only: stage a frozen address so the pre-flight's BLOCK path is observable.
    /// @dev Unrestricted, like `mint` — this is a testnet token. Real USDC gates this behind a
    ///      blacklister role. Setting it does NOT make transfers here fail; see the contract doc.
    function setBlacklisted(address account, bool frozen) external {
        _blacklisted[account] = frozen;
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

    /// @notice ERC-3009 transfer authorization. Any caller may submit it, which is exactly why
    ///         `SplitRouter` does not use it: an authorization in the mempool could be redirected
    ///         by a front-runner. Present because real USDC has it.
    function transferWithAuthorization(
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
        _authorize(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, v, r, s);
    }

    /// @notice ERC-3009 receive authorization. `to` must be the caller, which is what makes an
    ///         authorization usable only by its named payee. `SplitRouter.route()` calls this.
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
        _authorize(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, v, r, s);
    }

    /// @notice Burns an unused nonce so a signed authorization can never be submitted.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        if (_authorizationStates[authorizer][nonce]) revert AuthNonceAlreadyUsed(authorizer, nonce);

        bytes32 structHash = keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce));
        _requireSignedBy(authorizer, structHash, v, r, s);

        _authorizationStates[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /// @dev Shared body of the two authorization entry points. Only the typehash differs, which
    ///      is the entire distinction between them.
    function _authorize(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        if (block.timestamp <= validAfter) revert AuthNotYetValid(validAfter, block.timestamp);
        if (block.timestamp >= validBefore) revert AuthExpired(validBefore, block.timestamp);
        if (_authorizationStates[from][nonce]) revert AuthNonceAlreadyUsed(from, nonce);

        bytes32 structHash = keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce));
        _requireSignedBy(from, structHash, v, r, s);

        _authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    function _requireSignedBy(address expected, bytes32 structHash, uint8 v, bytes32 r, bytes32 s) private view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != expected) revert InvalidSignature();
    }
}
