// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EIP712Helpers} from "../helpers/EIP712Helpers.sol";
import {ERC3009Signer} from "../helpers/ERC3009Signer.sol";
import {MockAgentRegistry} from "../helpers/MockAgentRegistry.sol";
import {ProtocolAddressRegistry} from "../../src/ProtocolAddressRegistry.sol";
import {MerchantRegistry} from "../../src/MerchantRegistry.sol";
import {ProductRegistry} from "../../src/ProductRegistry.sol";
import {ReviewRegistry} from "../../src/ReviewRegistry.sol";
import {SplitRouter} from "../../src/SplitRouter.sol";
import {CommissionEscrow} from "../../src/CommissionEscrow.sol";
import {IProductRegistry} from "../../src/interfaces/IProductRegistry.sol";
import {IReviewRegistry} from "../../src/interfaces/IReviewRegistry.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";

interface IUSDC {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address account) external view returns (uint256);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @dev The only test in this repository that runs against real USDC bytecode (REF-269).
///
///      Before this file existed, nothing here had ever exercised `route()` against the token it
///      actually settles on. Both USDC mocks were written to agree with our own signers, so the
///      suite could only ever confirm that our code agreed with itself. That is how every signer
///      in the stack came to sign `TransferWithAuthorization` while `SplitRouter.route()` calls
///      `receiveWithAuthorization`, with CI green throughout.
///
///      Reads its endpoint from `BASE_FORK_RPC_URL`, defaulting to the public Base RPC. An
///      unreachable endpoint fails loudly rather than skipping: a fork test that quietly tests
///      nothing is the exact failure mode this file exists to end.
///
///      `SKIP_FORK_TESTS=1` opts out, and the main CI job sets it deliberately — this suite runs
///      in `.github/workflows/fork-tests.yml` instead, on changes that could break the agreement
///      with real USDC plus nightly. That is not a blanket skip: a typehash regression is caught
///      by the hermetic suite anyway (reverting the signer to Transfer fails 73 tests with this
///      file excluded). What only this file catches is our mock, signer and digest vector being
///      CONSISTENTLY wrong relative to Circle's token — which is why its trigger paths are the
///      typehash strings, the domain builder, both mocks and the router.
///
///      The fork block is pinned. Foundry only caches RPC responses for a pinned block, so this
///      is both deterministic and ~8x faster on a warm cache. Note that `createSelectFork` still
///      needs to reach the endpoint even when cached, which is why CI separates the job rather
///      than relying on the cache.
///
///      Wires the protocol itself rather than reusing `IntegrationFixture`, whose `usdc` field is
///      typed `MockUSDC` and which deploys that mock in `setUp`. Worth consolidating behind a
///      token-agnostic deployer if a second fork test appears.
contract SplitRouterUSDCForkTest is Test {
    /// @dev Circle USDC on Base mainnet (FiatTokenV2_2 behind a proxy).
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Deliberately NOT `RPC_URL` from `.env`: that key names a Base-mainnet Alchemy app
    ///      which has BASE_MAINNET disabled and answers 403.
    string internal constant DEFAULT_BASE_RPC = "https://mainnet.base.org";

    /// @dev Pinned so the fork is deterministic AND cacheable. Foundry only caches RPC responses
    ///      for a pinned block; an unpinned fork re-reads the live tip every run, which is both a
    ///      hard network dependency on every CI run and a test whose fixture moves under it.
    uint256 internal constant FORK_BLOCK = 50_900_000;

    IUSDC internal usdc;
    MockAgentRegistry internal agentRegistry;
    ProtocolAddressRegistry internal par;
    MerchantRegistry internal merchantRegistry;
    ProductRegistry internal productRegistry;
    ReviewRegistry internal reviewRegistry;
    SplitRouter internal splitRouter;
    CommissionEscrow internal escrow;

    address internal admin = makeAddr("admin");
    address internal oracle = makeAddr("oracle");
    address internal facilitator = makeAddr("facilitator");
    address internal treasury = makeAddr("treasury");
    address internal merchantOwner = makeAddr("merchantOwner");
    address internal reviewer;
    uint256 internal reviewerPk;

    address internal buyer;
    uint256 internal buyerPk;

    uint256 internal buyerAgentId;
    uint256 internal merchantId;
    uint256 internal reviewerAgentId;
    uint256 internal reviewId;

    bytes32 internal usdcDomainSeparator;
    bool internal forked;

    bytes32 internal constant PRODUCT_ID = keccak256("product-alpha");
    uint256 internal constant GROSS = 100e6; // 100 USDC
    uint16 internal constant COMMISSION_BPS = 1000;
    uint16 internal constant PLATFORM_FEE_BPS = 200;
    uint16 internal constant COMMISSION_MULTIPLIER_BPS = 7000;

    function setUp() public {
        if (vm.envOr("SKIP_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.envOr("BASE_FORK_RPC_URL", DEFAULT_BASE_RPC), FORK_BLOCK);
        forked = true;

        usdc = IUSDC(BASE_USDC);
        usdcDomainSeparator = usdc.DOMAIN_SEPARATOR();

        (buyer, buyerPk) = makeAddrAndKey("buyer");
        // The reviewer signs the ReviewCommitment the oracle publishes on its behalf.
        (reviewer, reviewerPk) = makeAddrAndKey("reviewer");
        deal(BASE_USDC, buyer, GROSS);
        assertEq(usdc.balanceOf(buyer), GROSS, "could not fund buyer with real USDC");

        _deployProtocol();
        _seedActors();
    }

    function _deployProtocol() private {
        agentRegistry = new MockAgentRegistry();

        bytes32[] memory keys = new bytes32[](2);
        address[] memory vals = new address[](2);
        keys[0] = keccak256("AGENT_REGISTRY");
        vals[0] = address(agentRegistry);
        keys[1] = keccak256("TREASURY");
        vals[1] = treasury;
        par = new ProtocolAddressRegistry(admin, makeAddr("guardian"), 0, keys, vals);

        merchantRegistry = new MerchantRegistry(address(par), admin);
        productRegistry = new ProductRegistry(address(par));
        reviewRegistry = new ReviewRegistry(address(par), admin);
        escrow = new CommissionEscrow(address(par), admin, BASE_USDC);
        splitRouter = new SplitRouter(address(par), admin, BASE_USDC, PLATFORM_FEE_BPS);

        vm.startPrank(admin);
        _parSet(keccak256("MERCHANT_REGISTRY"), address(merchantRegistry));
        _parSet(keccak256("PRODUCT_REGISTRY"), address(productRegistry));
        _parSet(keccak256("REVIEW_REGISTRY"), address(reviewRegistry));
        _parSet(keccak256("ESCROW"), address(escrow));
        _parSet(keccak256("SPLIT_ROUTER"), address(splitRouter));
        reviewRegistry.grantRole(keccak256("ORACLE_ROLE"), oracle);
        escrow.grantRole(keccak256("ORACLE_ROLE"), oracle);
        splitRouter.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);
        vm.stopPrank();
    }

    function _parSet(bytes32 key, address value) private {
        par.setAddress(key, value);
        par.executeUpdate(key);
    }

    function _seedActors() private {
        buyerAgentId = agentRegistry.mint(buyer);
        reviewerAgentId = agentRegistry.mint(reviewer);
        merchantId = agentRegistry.mint(merchantOwner);

        vm.prank(merchantOwner);
        merchantRegistry.setActive(merchantId, true);
        vm.prank(merchantOwner);
        productRegistry.addProduct(
            merchantId, PRODUCT_ID, COMMISSION_BPS, IProductRegistry.ProductType.Repeat, "ipfs://test"
        );

        bytes32 contentHash = keccak256("review content");
        uint256 expiry = block.timestamp + 1 days;
        bytes memory reviewerSig = EIP712Helpers.signReviewCommitment(
            vm,
            reviewerPk,
            address(reviewRegistry),
            block.chainid,
            reviewerAgentId,
            merchantId,
            PRODUCT_ID,
            contentHash,
            1,
            expiry
        );
        vm.prank(oracle);
        reviewId = reviewRegistry.publishReview(
            reviewerAgentId,
            merchantId,
            PRODUCT_ID,
            contentHash,
            IReviewRegistry.ProofType.AdminApproved,
            IReviewRegistry.Sig({nonce: 1, expiry: expiry, agentSignature: reviewerSig})
        );
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

    function _auth(bytes32 nonce) internal view returns (ERC3009Signer.Authorization memory) {
        return ERC3009Signer.Authorization({
            from: buyer,
            to: address(splitRouter),
            value: GROSS,
            validAfter: 0,
            validBefore: type(uint256).max,
            nonce: nonce
        });
    }

    // =========================================================================
    // Tests
    // =========================================================================

    /// @dev Real USDC settles a `ReceiveWithAuthorization`-signed pull. This is the assertion
    ///      that makes Option A real rather than asserted.
    function test_Fork_Route_Succeeds_WithReceiveSignature() public {
        if (!forked) {
            vm.skip(true);
        }

        ISplitRouter.RouteParams memory rp = _routeParams();
        bytes32 nonce = keccak256("fork-receive");
        ISplitRouter.ERC3009Params memory ep = ERC3009Signer.signReceive(vm, buyerPk, usdcDomainSeparator, _auth(nonce));

        vm.prank(facilitator);
        uint256 escrowId = splitRouter.route(rp, ep);

        assertEq(escrowId, 1);
        assertTrue(usdc.authorizationState(buyer, nonce), "real USDC did not record the authorization");
        assertEq(usdc.balanceOf(buyer), 0, "buyer was not debited");
        assertEq(usdc.balanceOf(address(splitRouter)), 0, "router stranded USDC");
        // 100 gross − 10 commission − 2 platform fee
        assertEq(usdc.balanceOf(merchantOwner), 88e6);
        assertEq(usdc.balanceOf(treasury), 2e6);
    }

    /// @dev The pre-REF-269 signature, against the token that actually validates it. Real USDC
    ///      rejects it inside `receiveWithAuthorization`, so nothing moves and the x402 rail
    ///      cannot settle — independent of whether the protocol is deployed.
    function test_Fork_Route_Reverts_WithTransferSignature() public {
        if (!forked) {
            vm.skip(true);
        }

        ISplitRouter.RouteParams memory rp = _routeParams();
        bytes32 nonce = keccak256("fork-transfer");
        ISplitRouter.ERC3009Params memory ep =
            ERC3009Signer.signTransfer(vm, buyerPk, usdcDomainSeparator, _auth(nonce));

        vm.prank(facilitator);
        vm.expectRevert(); // FiatTokenV2_2: "invalid signature"
        splitRouter.route(rp, ep);

        // The rejection costs nothing on-chain: the nonce stays unused, so the same
        // authorization can be re-signed under the correct typehash and retried (REF-269 item 12).
        assertFalse(usdc.authorizationState(buyer, nonce));
        assertEq(usdc.balanceOf(buyer), GROSS);
    }

    /// @dev Guards the domain assumption the off-chain signers hard-code: name "USD Coin",
    ///      version "2", the fork's chain id, and the token address. A signer that gets any of
    ///      these wrong produces a valid-looking signature real USDC will not accept.
    function test_Fork_DomainSeparator_MatchesHandRolledDomain() public {
        if (!forked) {
            vm.skip(true);
        }

        assertEq(usdcDomainSeparator, ERC3009Signer.domainSeparator("USD Coin", "2", block.chainid, BASE_USDC));
    }
}
