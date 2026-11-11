// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {SplitRouter} from "../../../src/SplitRouter.sol";
import {ProtocolAddressRegistry} from "../../../src/ProtocolAddressRegistry.sol";
import {ISplitRouter} from "../../../src/interfaces/ISplitRouter.sol";
import {IReviewRegistry} from "../../../src/interfaces/IReviewRegistry.sol";
import {IProductRegistry} from "../../../src/interfaces/IProductRegistry.sol";
import {ERC3009Signer} from "../../helpers/ERC3009Signer.sol";
import {MockUSDC} from "../../helpers/MockUSDC.sol";
import {MockAgentRegistry} from "../../helpers/MockAgentRegistry.sol";
import {MockMerchantRegistry} from "../../helpers/MockMerchantRegistry.sol";
import {MockCommissionEscrow} from "../../helpers/MockCommissionEscrow.sol";
import {MockReviewRegistry} from "../../helpers/MockReviewRegistry.sol";
import {MockProductRegistry} from "../../helpers/MockProductRegistry.sol";

/// @dev Bounded handler for SplitRouter invariant testing.
///      Two route actions: one with product commission=0 (no reviewer) and one with
///      a non-zero product commission routed to a seeded reviewer pool, covering _resolveWallet
///      and the immediate-commission transfer leg. Commission is read live from ProductRegistry.
contract SplitRouterHandler is CommonBase, StdCheats, StdUtils {
    SplitRouter internal router;
    MockUSDC internal usdc;
    MockAgentRegistry internal agentRegistry;
    MockMerchantRegistry internal merchantRegistry;
    MockCommissionEscrow internal escrow;
    MockReviewRegistry internal reviewRegistry;
    MockProductRegistry internal productRegistry;

    address internal facilitator;
    address internal admin;

    bytes32 internal constant PRODUCT_ID = keccak256("handler-product");

    // Pre-minted actor pools
    uint256[] internal buyerAgentIds;
    address[] internal buyerAddrs;
    /// @dev Buyers must be keyed: route() pulls via a signed ERC-3009 authorization.
    uint256[] internal buyerPks;
    uint256[] internal merchantIds;
    uint256[] internal reviewerAgentIds;
    address[] internal reviewerAddrs;
    uint256[] internal reviewIds;

    // Non-zero treasury pool
    address[] internal treasuryPool;
    ProtocolAddressRegistry internal par;

    // Cached so the signing helper makes no external call, which would consume the pending
    // vm.prank before route() ran.
    bytes32 internal usdcDomainSeparator;
    uint256 internal authNonce;

    // Ghost variables for invariants
    uint256 public ghost_routeCallCount;
    uint256 public ghost_immediateCommissionTotal;

    constructor(
        SplitRouter router_,
        MockUSDC usdc_,
        MockAgentRegistry agentRegistry_,
        MockMerchantRegistry merchantRegistry_,
        MockCommissionEscrow escrow_,
        MockReviewRegistry reviewRegistry_,
        MockProductRegistry productRegistry_,
        address facilitator_,
        address admin_,
        ProtocolAddressRegistry par_
    ) {
        router = router_;
        usdc = usdc_;
        agentRegistry = agentRegistry_;
        merchantRegistry = merchantRegistry_;
        escrow = escrow_;
        reviewRegistry = reviewRegistry_;
        productRegistry = productRegistry_;
        facilitator = facilitator_;
        admin = admin_;
        par = par_;
        usdcDomainSeparator = usdc_.DOMAIN_SEPARATOR();

        for (uint256 i = 0; i < 3; i++) {
            // Derived from a key rather than synthesized, so the buyer can sign its own pull.
            uint256 buyerPk = 0xB000 + i;
            address buyerAddr = vm.addr(buyerPk);
            uint256 buyerAgentId = agentRegistry_.mint(buyerAddr);
            buyerAgentIds.push(buyerAgentId);
            buyerAddrs.push(buyerAddr);
            buyerPks.push(buyerPk);

            address merchantOwner = address(uint160(0xA000 + i));
            uint256 merchantId = agentRegistry_.mint(merchantOwner);
            merchantIds.push(merchantId);
            merchantRegistry_.setActiveRaw(merchantId, true);

            // Commission is read live from ProductRegistry at settle. Register the
            // product per merchant; each route action sets the commission it needs.
            productRegistry_.addProduct(merchantId, PRODUCT_ID, 0, IProductRegistry.ProductType.Repeat, "");

            address reviewerAddr = address(uint160(0xD000 + i));
            uint256 reviewerAgentId = agentRegistry_.mint(reviewerAddr);
            reviewerAgentIds.push(reviewerAgentId);
            reviewerAddrs.push(reviewerAddr);

            uint256 reviewId = i + 1;
            reviewIds.push(reviewId);
            reviewRegistry_.setReviewRaw(
                reviewId,
                IReviewRegistry.Review({
                    agentId: reviewerAgentId,
                    merchantId: merchantId,
                    productId: PRODUCT_ID,
                    contentHash: bytes32(0),
                    proofType: IReviewRegistry.ProofType.AdminApproved,
                    timestamp: uint40(block.timestamp),
                    editedAt: 0
                })
            );
        }

        treasuryPool.push(address(uint160(0xC001)));
        treasuryPool.push(address(uint160(0xC002)));
        treasuryPool.push(address(uint160(0xC003)));
    }

    // -------------------------------------------------------------------------
    // Bounded actions
    // -------------------------------------------------------------------------

    /// @dev Signs the authorization route() pulls with, under the `ReceiveWithAuthorization`
    ///      typehash. `to` is the router because `receiveWithAuthorization` requires
    ///      `to == msg.sender`. The nonce counter keeps repeated routes by one buyer from
    ///      colliding on the token's per-authorizer nonce map.
    function _signRouteAuth(ISplitRouter.RouteParams memory routeParams, uint256 buyerPk)
        private
        returns (ISplitRouter.ERC3009Params memory)
    {
        authNonce++;
        return ERC3009Signer.signReceive(
            vm,
            buyerPk,
            usdcDomainSeparator,
            ERC3009Signer.Authorization({
                from: routeParams.buyer,
                to: address(router),
                value: routeParams.grossAmount,
                validAfter: 0,
                validBefore: type(uint256).max,
                nonce: bytes32(authNonce)
            })
        );
    }

    /// @dev Route with no commission (reviewId=0). Covers cashback + platform fee legs.
    function route(uint256 grossAmount, uint16 cashbackBps) external {
        grossAmount = bound(grossAmount, 1, type(uint96).max);

        // Cashback is a share OF COMMISSION; the admin cap is maxCashbackBpsOfCommission (default 4000).
        cashbackBps = uint16(bound(cashbackBps, 0, 4000));

        uint256 idx = grossAmount % buyerAgentIds.length;
        uint256 buyerAgentId = buyerAgentIds[idx];
        address buyer = buyerAddrs[idx];
        uint256 merchantId = merchantIds[idx];

        usdc.mint(buyer, grossAmount);

        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: 0,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: grossAmount,
            buyer: buyer,
            commissionMultiplierBps: 4000,
            lockedCashbackBps: cashbackBps
        });
        ISplitRouter.ERC3009Params memory ep = _signRouteAuth(rp, buyerPks[idx]);

        vm.prank(facilitator);
        router.route(rp, ep);

        ghost_routeCallCount++;
    }

    /// @dev Route with non-zero commission to a seeded reviewer. Covers _resolveWallet
    ///      and the immediate-commission transfer leg. Tracks ghost sum for the invariant.
    function routeWithCommission(uint256 grossAmount, uint16 commissionBps, uint16 multiplierBps) external {
        grossAmount = bound(grossAmount, 1, type(uint96).max);
        uint16 feeBps = router.platformFeeBps();
        commissionBps = uint16(bound(commissionBps, 1, 10000 - feeBps));
        multiplierBps = uint16(bound(multiplierBps, 4000, 10000));

        uint256 idx = grossAmount % buyerAgentIds.length;
        uint256 buyerAgentId = buyerAgentIds[idx];
        address buyer = buyerAddrs[idx];
        uint256 merchantId = merchantIds[idx];
        uint256 reviewId = reviewIds[idx];

        usdc.mint(buyer, grossAmount);
        productRegistry.setCommission(merchantId, PRODUCT_ID, commissionBps);

        ISplitRouter.RouteParams memory rp = ISplitRouter.RouteParams({
            buyerAgentId: buyerAgentId,
            reviewId: reviewId,
            merchantId: merchantId,
            productId: PRODUCT_ID,
            grossAmount: grossAmount,
            buyer: buyer,
            commissionMultiplierBps: multiplierBps,
            lockedCashbackBps: 0
        });
        ISplitRouter.ERC3009Params memory ep = _signRouteAuth(rp, buyerPks[idx]);

        vm.prank(facilitator);
        router.route(rp, ep);

        uint256 baseCommission = grossAmount * commissionBps / 10_000;
        uint256 immediateCommission = baseCommission * multiplierBps / 10_000;
        ghost_immediateCommissionTotal += immediateCommission;
        ghost_routeCallCount++;
    }

    function setPlatformFeeBps(uint16 bps) external {
        bps = uint16(bound(bps, 0, router.MAX_PLATFORM_FEE_BPS()));
        vm.prank(admin);
        router.setPlatformFeeBps(bps);
    }

    /// @dev Rotates the treasury via PAR, which is now the single source of truth — the
    ///      router resolves TREASURY live on every route() rather than holding its own copy.
    ///      Keeps the original coverage (conservation invariants must hold across treasury
    ///      changes) and additionally exercises the live-resolution path.
    function setTreasury(address seed) external {
        bytes32 key = par.TREASURY();

        // Zero-address must always revert — the guard moved from SplitRouter.setTreasury
        // to PAR.setAddress, so assert it where it now lives.
        vm.prank(admin);
        vm.expectRevert();
        par.setAddress(key, address(0));

        uint256 idx = uint256(uint160(seed)) % treasuryPool.length;
        vm.startPrank(admin);
        par.setAddress(key, treasuryPool[idx]);
        vm.stopPrank();
        // Fixture PAR has timelockDelay 0, so the queued update is executable at once.
        par.executeUpdate(key);
    }

    /// @dev Sum of all reviewer USDC balances — used by the ghost invariant.
    function reviewerBalanceTotal() external view returns (uint256 total) {
        for (uint256 i = 0; i < reviewerAddrs.length; i++) {
            total += usdc.balanceOf(reviewerAddrs[i]);
        }
    }
}
