// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC3009Signer} from "./ERC3009Signer.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockAgentRegistry} from "./MockAgentRegistry.sol";
import {MockMerchantRegistry} from "./MockMerchantRegistry.sol";
import {MockProductRegistry} from "./MockProductRegistry.sol";
import {MockReviewRegistry} from "./MockReviewRegistry.sol";
import {MockCommissionEscrow} from "./MockCommissionEscrow.sol";
import {ProtocolAddressRegistry} from "../../src/ProtocolAddressRegistry.sol";
import {MerchantRegistry} from "../../src/MerchantRegistry.sol";
import {ProductRegistry} from "../../src/ProductRegistry.sol";
import {ReviewRegistry} from "../../src/ReviewRegistry.sol";
import {SplitRouter} from "../../src/SplitRouter.sol";
import {CommissionEscrow} from "../../src/CommissionEscrow.sol";
import {IProductRegistry} from "../../src/interfaces/IProductRegistry.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";

/// @dev Shared fixture base for unit tests that use mocks.
///      Deploys real SUT + all dependencies as mocks.
contract MockFixture is Test {
    MockUSDC internal usdc;
    MockAgentRegistry internal agentRegistry;
    MockMerchantRegistry internal merchantRegistry;
    MockProductRegistry internal productRegistry;
    MockReviewRegistry internal reviewRegistry;
    MockCommissionEscrow internal escrow;
    ProtocolAddressRegistry internal par;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal oracle = makeAddr("oracle");
    address internal keeper = makeAddr("keeper");
    address internal facilitator = makeAddr("facilitator");
    address internal treasury = makeAddr("treasury");

    /// @dev Monotonic ERC-3009 nonce source; see `signRouteAuth`.
    uint256 private _authNonce;

    /// @dev Cached so `signRouteAuth` makes no external call. A call there would consume a
    ///      pending `vm.prank` before `route()` ever ran, since the authorization is signed while
    ///      building the arguments.
    bytes32 internal usdcDomainSeparator;

    function setUp() public virtual {
        usdc = new MockUSDC();
        usdcDomainSeparator = usdc.DOMAIN_SEPARATOR();
        agentRegistry = new MockAgentRegistry();
        merchantRegistry = new MockMerchantRegistry();
        productRegistry = new MockProductRegistry();
        reviewRegistry = new MockReviewRegistry();
        escrow = new MockCommissionEscrow(address(usdc), treasury);

        bytes32[] memory keys = new bytes32[](7);
        keys[0] = keccak256("AGENT_REGISTRY");
        keys[1] = keccak256("MERCHANT_REGISTRY");
        keys[2] = keccak256("PRODUCT_REGISTRY");
        keys[3] = keccak256("REVIEW_REGISTRY");
        keys[4] = keccak256("ESCROW");
        keys[5] = keccak256("SPLIT_ROUTER");
        // TREASURY is resolved LIVE by SplitRouter.route() and CommissionEscrow settlement,
        // so it must be present or every settlement reverts AddressNotSet.
        keys[6] = keccak256("TREASURY");

        address[] memory vals = new address[](7);
        vals[0] = address(agentRegistry);
        vals[1] = address(merchantRegistry);
        vals[2] = address(productRegistry);
        vals[3] = address(reviewRegistry);
        vals[4] = address(escrow);
        vals[5] = address(0xdead); // placeholder; SplitRouter address not yet known
        vals[6] = treasury;

        par = new ProtocolAddressRegistry(admin, guardian, 0, keys, vals);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Signs the ERC-3009 authorization `SplitRouter.route()` will pull with, under the
    ///      `ReceiveWithAuthorization` typehash (REF-269). `to` is the router because
    ///      `receiveWithAuthorization` requires `to == msg.sender`.
    ///
    ///      Derives `from`/`value` from `routeParams` so a call site cannot sign an authorization
    ///      that disagrees with the route it accompanies. The nonce counter keeps repeated routes
    ///      in one test from colliding on the token's per-authorizer nonce map.
    function signRouteAuth(address router, ISplitRouter.RouteParams memory routeParams, uint256 buyerPk)
        internal
        returns (ISplitRouter.ERC3009Params memory)
    {
        _authNonce++;
        return ERC3009Signer.signReceive(
            vm,
            buyerPk,
            usdcDomainSeparator,
            ERC3009Signer.Authorization({
                from: routeParams.buyer,
                to: router,
                value: routeParams.grossAmount,
                validAfter: 0,
                validBefore: type(uint256).max,
                nonce: bytes32(_authNonce)
            })
        );
    }

    function mintAgent(address owner) internal returns (uint256 agentId) {
        agentId = agentRegistry.mint(owner);
    }

    function setupMerchant(uint256 merchantId) internal {
        merchantRegistry.setActiveRaw(merchantId, true);
    }

    function setupProduct(
        uint256 merchantId,
        bytes32 productId,
        uint16 commissionBps,
        uint16 /*cashbackBps*/
    )
        internal
    {
        IProductRegistry.Product memory p = IProductRegistry.Product({
            merchantId: merchantId,
            productId: productId,
            commissionBps: commissionBps,
            active: true,
            productCardURI: "",
            createdAt: uint40(block.timestamp),
            productType: IProductRegistry.ProductType.Repeat
        });
        productRegistry.setProductRaw(merchantId, productId, p);
    }
}

/// @dev Shared fixture base for integration tests.
///      Deploys all real contracts wired together.
contract IntegrationFixture is Test {
    MockUSDC internal usdc;
    MockAgentRegistry internal agentRegistry;
    ProtocolAddressRegistry internal par;
    MerchantRegistry internal merchantRegistry;
    ProductRegistry internal productRegistry;
    ReviewRegistry internal reviewRegistry;
    SplitRouter internal splitRouter;
    CommissionEscrow internal escrow;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal oracle = makeAddr("oracle");
    address internal keeper = makeAddr("keeper");
    address internal facilitator = makeAddr("facilitator");
    address internal treasury = makeAddr("treasury");

    uint16 internal constant PLATFORM_FEE_BPS = 200; // 2%

    /// @dev Monotonic ERC-3009 nonce source; see `signRouteAuth`.
    uint256 private _authNonce;

    /// @dev Cached so `signRouteAuth` makes no external call. A call there would consume a
    ///      pending `vm.prank` before `route()` ever ran, since the authorization is signed while
    ///      building the arguments.
    bytes32 internal usdcDomainSeparator;

    function setUp() public virtual {
        usdc = new MockUSDC();
        usdcDomainSeparator = usdc.DOMAIN_SEPARATOR();
        agentRegistry = new MockAgentRegistry();

        // Seed AGENT_REGISTRY and TREASURY through the PAR constructor, mirroring
        // Deploy.s.sol: both must resolve before the protocol contracts can function.
        // AGENT_REGISTRY is cached as an immutable at construction; TREASURY is resolved
        // LIVE on every settlement, so an unset key reverts AddressNotSet.
        bytes32[] memory keys = new bytes32[](2);
        address[] memory vals = new address[](2);
        keys[0] = keccak256("AGENT_REGISTRY");
        vals[0] = address(agentRegistry);
        keys[1] = keccak256("TREASURY");
        vals[1] = treasury;
        par = new ProtocolAddressRegistry(admin, guardian, 0, keys, vals);

        merchantRegistry = new MerchantRegistry(address(par), admin);
        productRegistry = new ProductRegistry(address(par));
        reviewRegistry = new ReviewRegistry(address(par), admin);
        escrow = new CommissionEscrow(address(par), admin, address(usdc));
        splitRouter = new SplitRouter(address(par), admin, address(usdc), PLATFORM_FEE_BPS);

        _wireParAddresses();
        _grantRoles();
    }

    function _wireParAddresses() private {
        vm.startPrank(admin);
        // PAR has timelock 0 in tests; setAddress + executeUpdate immediately.
        _parSet(keccak256("MERCHANT_REGISTRY"), address(merchantRegistry));
        _parSet(keccak256("PRODUCT_REGISTRY"), address(productRegistry));
        _parSet(keccak256("REVIEW_REGISTRY"), address(reviewRegistry));
        _parSet(keccak256("ESCROW"), address(escrow));
        _parSet(keccak256("SPLIT_ROUTER"), address(splitRouter));
        vm.stopPrank();
    }

    function _parSet(bytes32 key, address value) private {
        par.setAddress(key, value);
        par.executeUpdate(key);
    }

    function _grantRoles() private {
        vm.startPrank(admin);
        reviewRegistry.grantRole(keccak256("ORACLE_ROLE"), oracle);
        escrow.grantRole(keccak256("ORACLE_ROLE"), oracle);
        splitRouter.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);
        // Pausing is its own role (REF-327); the deploy scripts always grant it to the admin so a
        // deployment is never left unpausable, and this fixture mirrors that.
        escrow.grantRole(keccak256("PAUSER_ROLE"), admin);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function mintAgent(address owner) internal returns (uint256 agentId) {
        agentId = agentRegistry.mint(owner);
    }

    function mintMerchant(address owner) internal returns (uint256 merchantId) {
        merchantId = agentRegistry.mint(owner);
        vm.prank(owner);
        merchantRegistry.setActive(merchantId, true);
    }

    function addProduct(
        uint256 merchantId,
        address merchantOwner,
        bytes32 productId,
        uint16 commissionBps,
        uint16 /*cashbackBps*/
    )
        internal
    {
        vm.prank(merchantOwner);
        productRegistry.addProduct(
            merchantId, productId, commissionBps, IProductRegistry.ProductType.Repeat, "ipfs://test"
        );
    }

    /// @dev Signs the ERC-3009 authorization `SplitRouter.route()` will pull with, under the
    ///      `ReceiveWithAuthorization` typehash (REF-269). `to` is the router because
    ///      `receiveWithAuthorization` requires `to == msg.sender`.
    ///
    ///      Derives `from`/`value` from `routeParams` so a call site cannot sign an authorization
    ///      that disagrees with the route it accompanies. The nonce counter keeps repeated routes
    ///      in one test from colliding on the token's per-authorizer nonce map.
    function signRouteAuth(ISplitRouter.RouteParams memory routeParams, uint256 buyerPk)
        internal
        returns (ISplitRouter.ERC3009Params memory)
    {
        _authNonce++;
        return ERC3009Signer.signReceive(
            vm,
            buyerPk,
            usdcDomainSeparator,
            ERC3009Signer.Authorization({
                from: routeParams.buyer,
                to: address(splitRouter),
                value: routeParams.grossAmount,
                validAfter: 0,
                validBefore: type(uint256).max,
                nonce: bytes32(_authNonce)
            })
        );
    }

    /// @dev `buyerPk` must be the key behind `buyer` — the route pulls via a signed ERC-3009
    ///      authorization, so an address without a key cannot pay (REF-269).
    function fundAndRoute(
        address buyer,
        uint256 buyerPk,
        uint256 buyerAgentId,
        uint256 reviewId,
        uint256 merchantId,
        bytes32 productId,
        uint256 grossAmount,
        uint16 commissionMultiplierBps,
        uint16 lockedCashbackBps
    ) internal returns (uint256 escrowId) {
        // Commission is read live from ProductRegistry at settle (REF-159); the caller must have
        // registered `productId` with the desired commission before invoking this helper.
        usdc.mint(buyer, grossAmount);
        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: productId,
            grossAmount: grossAmount,
            buyer: buyer,
            commissionMultiplierBps: commissionMultiplierBps,
            lockedCashbackBps: lockedCashbackBps
        });
        ISplitRouter.ERC3009Params memory ep = signRouteAuth(rp, buyerPk);
        vm.prank(facilitator);
        escrowId = splitRouter.route(rp, ep);
    }
}
