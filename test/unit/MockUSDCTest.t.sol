// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC3009Signer} from "../helpers/ERC3009Signer.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// @dev First tests for the deployable testnet token.
///
///      `src/MockUSDC.sol` is what the Sepolia deployment and the local anvil e2e harness run
///      against, and it had no test of its own. It carried Circle's Receive-variant caller guard
///      bolted onto the Transfer typehash — neither real ERC-3009 function — and nothing could
///      observe that.
///
///      These cases assert the property that distinguishes the two entry points: each verifies
///      its own typehash, and a signature for one is worthless to the other.
contract MockUSDCTest is Test {
    MockUSDC internal usdc;
    bytes32 internal domainSep;

    address internal buyer;
    uint256 internal buyerPk;
    address internal payee = makeAddr("payee");

    uint256 internal constant AMOUNT = 100e6;

    function setUp() public {
        usdc = new MockUSDC();
        domainSep = usdc.DOMAIN_SEPARATOR();
        (buyer, buyerPk) = makeAddrAndKey("buyer");
        usdc.mint(buyer, AMOUNT * 4);
    }

    function _auth(address to, bytes32 nonce) internal view returns (ERC3009Signer.Authorization memory) {
        return ERC3009Signer.Authorization({
            from: buyer, to: to, value: AMOUNT, validAfter: 0, validBefore: type(uint256).max, nonce: nonce
        });
    }

    // =========================================================================
    // Domain
    // =========================================================================

    /// @dev The domain every off-chain signer in the stack hard-codes for this token.
    function test_DomainSeparator_MatchesUsdCoinVersion2() public view {
        assertEq(domainSep, ERC3009Signer.domainSeparator("USD Coin", "2", block.chainid, address(usdc)));
    }

    function test_Decimals_IsSix() public view {
        assertEq(usdc.decimals(), 6);
    }

    // =========================================================================
    // The two typehashes are not interchangeable
    // =========================================================================

    function test_ReceiveWithAuthorization_AcceptsReceiveSignature() public {
        bytes32 nonce = keccak256("a");
        (uint8 v, bytes32 r, bytes32 s) = _signReceive(nonce, payee);

        vm.prank(payee);
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);

        assertEq(usdc.balanceOf(payee), AMOUNT);
        assertTrue(usdc.authorizationState(buyer, nonce));
    }

    /// @dev The typehash bug, asserted on the deployable token: the signature every signer in the
    ///      stack produced is rejected by the function `SplitRouter.route()` calls.
    function test_ReceiveWithAuthorization_RejectsTransferSignature() public {
        bytes32 nonce = keccak256("b");
        (uint8 v, bytes32 r, bytes32 s) = _signTransfer(nonce, payee);

        vm.prank(payee);
        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);
    }

    function test_TransferWithAuthorization_AcceptsTransferSignature() public {
        bytes32 nonce = keccak256("c");
        (uint8 v, bytes32 r, bytes32 s) = _signTransfer(nonce, payee);

        // Deliberately not the payee: transferWithAuthorization has no caller restriction.
        vm.prank(makeAddr("anyone"));
        usdc.transferWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);

        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_TransferWithAuthorization_RejectsReceiveSignature() public {
        bytes32 nonce = keccak256("d");
        (uint8 v, bytes32 r, bytes32 s) = _signReceive(nonce, payee);

        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        usdc.transferWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);
    }

    // =========================================================================
    // Caller guard — the difference that matters for front-running
    // =========================================================================

    function test_ReceiveWithAuthorization_Revert_CallerIsNotThePayee() public {
        bytes32 nonce = keccak256("e");
        (uint8 v, bytes32 r, bytes32 s) = _signReceive(nonce, payee);

        address frontRunner = makeAddr("frontRunner");
        vm.prank(frontRunner);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.CallerMustBePayee.selector, frontRunner, payee));
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);
    }

    // =========================================================================
    // Nonce lifecycle
    // =========================================================================

    function test_Revert_NonceReplayed() public {
        bytes32 nonce = keccak256("f");
        (uint8 v, bytes32 r, bytes32 s) = _signReceive(nonce, payee);

        vm.prank(payee);
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AuthNonceAlreadyUsed.selector, buyer, nonce));
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);
    }

    /// @dev A nonce burned by the Transfer path is unusable on the Receive path too — the state
    ///      is per (authorizer, nonce), not per typehash.
    function test_NonceState_IsSharedAcrossBothEntryPoints() public {
        bytes32 nonce = keccak256("g");
        (uint8 tv, bytes32 tr, bytes32 ts) = _signTransfer(nonce, payee);
        usdc.transferWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, tv, tr, ts);

        (uint8 v, bytes32 r, bytes32 s) = _signReceive(nonce, payee);
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AuthNonceAlreadyUsed.selector, buyer, nonce));
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);
    }

    function test_CancelAuthorization_BurnsTheNonce() public {
        bytes32 nonce = keccak256("h");
        bytes32 structHash =
            keccak256(abi.encode(keccak256("CancelAuthorization(address authorizer,bytes32 nonce)"), buyer, nonce));
        (uint8 cv, bytes32 cr, bytes32 cs) =
            vm.sign(buyerPk, keccak256(abi.encodePacked("\x19\x01", domainSep, structHash)));

        usdc.cancelAuthorization(buyer, nonce, cv, cr, cs);
        assertTrue(usdc.authorizationState(buyer, nonce));

        (uint8 v, bytes32 r, bytes32 s) = _signReceive(nonce, payee);
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AuthNonceAlreadyUsed.selector, buyer, nonce));
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, 0, type(uint256).max, nonce, v, r, s);
    }

    function test_CancelAuthorization_Revert_NotSignedByAuthorizer() public {
        bytes32 nonce = keccak256("i");
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes32 structHash =
            keccak256(abi.encode(keccak256("CancelAuthorization(address authorizer,bytes32 nonce)"), buyer, nonce));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(strangerPk, keccak256(abi.encodePacked("\x19\x01", domainSep, structHash)));

        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        usdc.cancelAuthorization(buyer, nonce, v, r, s);
    }

    // =========================================================================
    // Validity window
    // =========================================================================

    function test_Revert_NotYetValid() public {
        bytes32 nonce = keccak256("j");
        ERC3009Signer.Authorization memory auth = _auth(payee, nonce);
        auth.validAfter = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(ERC3009Signer.RECEIVE_WITH_AUTHORIZATION_TYPEHASH, auth);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AuthNotYetValid.selector, block.timestamp, block.timestamp));
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, block.timestamp, type(uint256).max, nonce, v, r, s);
    }

    function test_Revert_Expired() public {
        bytes32 nonce = keccak256("k");
        ERC3009Signer.Authorization memory auth = _auth(payee, nonce);
        auth.validBefore = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _signAuth(ERC3009Signer.RECEIVE_WITH_AUTHORIZATION_TYPEHASH, auth);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.AuthExpired.selector, block.timestamp, block.timestamp));
        usdc.receiveWithAuthorization(buyer, payee, AMOUNT, 0, block.timestamp, nonce, v, r, s);
    }

    // =========================================================================
    // Signing helpers
    // =========================================================================

    function _signReceive(bytes32 nonce, address to) internal view returns (uint8, bytes32, bytes32) {
        return _signAuth(ERC3009Signer.RECEIVE_WITH_AUTHORIZATION_TYPEHASH, _auth(to, nonce));
    }

    function _signTransfer(bytes32 nonce, address to) internal view returns (uint8, bytes32, bytes32) {
        return _signAuth(ERC3009Signer.TRANSFER_WITH_AUTHORIZATION_TYPEHASH, _auth(to, nonce));
    }

    function _signAuth(bytes32 typehash, ERC3009Signer.Authorization memory auth)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        return vm.sign(buyerPk, ERC3009Signer.digest(typehash, domainSep, auth));
    }

    // ── Blacklist query ─────────────────────────────────────────────────────────
    //
    // Real USDC freezes addresses, and a frozen payout recipient reverts the whole
    // `splitCharge` — with the buyer's funds already pooled in the router. The backend
    // pre-flights that by calling `isBlacklisted`, so the mock has to answer it: without the
    // function the call reverts, and a reverting read is indistinguishable from an unhealthy
    // node, which would make every local charge retry forever.
    //
    // The setter exists so the harness can exercise the BLOCK path. A mock that only ever
    // answers false makes the guard unobservable outside Go unit tests.

    function test_IsBlacklisted_DefaultsFalse() public view {
        assertFalse(usdc.isBlacklisted(buyer), "no address starts frozen");
        assertFalse(usdc.isBlacklisted(payee), "no address starts frozen");
        assertFalse(usdc.isBlacklisted(address(0)), "the zero address is not special here");
    }

    function test_SetBlacklisted_TogglesOneAddressOnly() public {
        usdc.setBlacklisted(buyer, true);
        assertTrue(usdc.isBlacklisted(buyer), "buyer should be frozen");
        assertFalse(usdc.isBlacklisted(payee), "freezing one address must not affect another");

        usdc.setBlacklisted(buyer, false);
        assertFalse(usdc.isBlacklisted(buyer), "unfreezing must be possible");
    }

    // The query is a READ ONLY mirror of Circle's surface. The mock must not start enforcing it
    // in transfers: `SplitRouter` is what reverts on a frozen recipient in production, via the
    // real token, and a mock that also enforced it would change what the contracts suite tests.
    function test_Blacklisting_DoesNotBlockTransfersInTheMock() public {
        usdc.mint(buyer, AMOUNT);
        usdc.setBlacklisted(buyer, true);

        vm.prank(buyer);
        usdc.transfer(payee, AMOUNT);

        assertEq(usdc.balanceOf(payee), AMOUNT, "the mock's blacklist is a query, not a gate");
    }
}

