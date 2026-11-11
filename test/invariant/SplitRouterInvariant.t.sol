// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {SplitRouterHandler} from "./handlers/SplitRouterHandler.sol";
import {SplitRouter} from "../../src/SplitRouter.sol";
import {ProtocolAddressRegistry} from "../../src/ProtocolAddressRegistry.sol";

contract SplitRouterInvariant is StdInvariant, MockFixture {
    SplitRouterHandler internal handler;
    SplitRouter internal router;

    function setUp() public override {
        super.setUp();
        router = new SplitRouter(address(par), admin, address(usdc), 200);
        vm.prank(admin);
        router.grantRole(keccak256("FACILITATOR_ROLE"), facilitator);

        handler = new SplitRouterHandler(
            router,
            usdc,
            agentRegistry,
            merchantRegistry,
            escrow,
            reviewRegistry,
            productRegistry,
            facilitator,
            admin,
            par
        );

        targetContract(address(handler));
    }

    // =========================================================================
    // Invariants
    // =========================================================================

    /// @dev SplitRouter is stateless w.r.t. USDC — balance is always 0 after route().
    ///      Any USDC left in SplitRouter is a bug (funds stranded).
    function invariant_SplitRouter_USDCBalanceAlwaysZero() public view {
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    /// @dev platformFeeBps never exceeds MAX_PLATFORM_FEE_BPS (20%).
    function invariant_PlatformFeeBps_NeverExceedsMax() public view {
        assertLe(router.platformFeeBps(), router.MAX_PLATFORM_FEE_BPS());
    }

    /// @dev The treasury the router will pay is never the zero address. The router no longer
    ///      holds its own copy — it resolves PAR's TREASURY key live on every route() — so the
    ///      invariant now asserts on PAR. getAddress itself reverts AddressNotSet on an unset
    ///      key, so this also proves the key stays populated across handler rotations.
    function invariant_Treasury_NeverZeroAddress() public view {
        assertTrue(par.getAddress(par.TREASURY()) != address(0));
    }

    /// @dev Sum of reviewer balances equals the ghost-tracked immediate commission total.
    ///      Ensures _resolveWallet + immediate transfer deliver exactly the computed amount.
    function invariant_ImmediateCommission_SentToReviewers() public view {
        assertEq(handler.reviewerBalanceTotal(), handler.ghost_immediateCommissionTotal());
    }

    /// @dev Liveness. Every other invariant here holds trivially when no route ever succeeds:
    ///      an empty router balance and a zero reviewer total are exactly what a suite that
    ///      routes nothing produces. A past bug hit precisely that — making the token verify
    ///      signatures reverted every handler action, and this suite still reported four
    ///      passing invariants.
    ///
    ///      Has to be `afterInvariant` rather than an `invariant_` function: Foundry evaluates
    ///      invariants once before the first call, where a zero route count is correct.
    function afterInvariant() public view {
        assertGt(handler.ghost_routeCallCount(), 0, "no route() call landed - invariants are vacuous");
    }
}
