// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockFixture} from "../helpers/Fixtures.sol";
import {CommissionEscrowHandler} from "./handlers/CommissionEscrowHandler.sol";
import {CommissionEscrow} from "../../src/CommissionEscrow.sol";
import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";

contract CommissionEscrowInvariant is StdInvariant, MockFixture {
    CommissionEscrowHandler internal handler;
    CommissionEscrow internal escrowReal;

    address internal oracleAddr = makeAddr("oracle");
    address internal reviewRegistryCaller = makeAddr("reviewRegistry");
    address internal splitRouterAddr = makeAddr("splitRouter");

    function setUp() public override {
        super.setUp();
        escrowReal = new CommissionEscrow(address(par), admin, address(usdc));

        vm.startPrank(admin);
        escrowReal.grantRole(keccak256("ORACLE_ROLE"), oracleAddr);
        escrowReal.grantRole(keccak256("ORACLE_ROLE"), reviewRegistryCaller);
        vm.stopPrank();

        vm.prank(admin);
        par.setAddress(keccak256("SPLIT_ROUTER"), splitRouterAddr);
        par.executeUpdate(keccak256("SPLIT_ROUTER"));

        handler = new CommissionEscrowHandler(
            escrowReal,
            usdc,
            agentRegistry,
            merchantRegistry,
            splitRouterAddr,
            oracleAddr,
            reviewRegistryCaller,
            treasury
        );

        targetContract(address(handler));
    }

    // =========================================================================
    // Invariants
    // =========================================================================

    /// @dev USDC held >= sum of pending held-back + pending cashback amounts.
    ///      The escrow contract must never be undercollateralised.
    function invariant_Solvency_BalanceGteAllPendingAmts() public view {
        assertGe(usdc.balanceOf(address(escrowReal)), handler.ghost_sumPendingAmts());
    }

    /// @dev totalEscrows() == number of successful deposit() calls.
    function invariant_TotalEscrows_MatchesDepositCount() public view {
        assertEq(escrowReal.totalEscrows(), handler.ghost_depositCount());
    }

    /// @dev Settled state is terminal — once Settled, heldBackPending is 0 for that escrow.
    function invariant_Settled_PendingAmtsAreZero() public view {
        uint256 count = handler.escrowIdCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 id = handler.escrowIdAt(i);
            if (escrowReal.getEscrow(id).state == ICommissionEscrow.EscrowState.Settled) {
                assertEq(handler.ghost_heldBackPending(id), 0);
            }
        }
    }
}
