// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {CommissionEscrow} from "../../../src/CommissionEscrow.sol";
import {MockUSDC} from "../../helpers/MockUSDC.sol";
import {MockAgentRegistry} from "../../helpers/MockAgentRegistry.sol";
import {MockMerchantRegistry} from "../../helpers/MockMerchantRegistry.sol";

/// @dev Bounded handler for CommissionEscrow invariant testing.
///      Covers the new two-bucket (heldBack + cashback) state machine:
///        Holding → Settled  (for heldBack via settleHeldBack or triggerSettleFallback)
///        cashbackReleased   (independent boolean, set by releaseCashback /
///                            cashbackToReviewer / triggerSettleFallback)
///      Ghost variables shadow on-chain state so invariant contracts can assert
///      conserved quantities without reading storage directly.
contract CommissionEscrowHandler is CommonBase, StdCheats, StdUtils {
    CommissionEscrow internal escrow;
    MockUSDC internal usdc;
    MockAgentRegistry internal agentRegistry;
    MockMerchantRegistry internal merchantRegistry;

    address internal splitRouter;
    address internal oracle;
    address internal reviewRegistryCaller;
    address internal treasury;

    bytes32 internal constant PRODUCT_ID = keccak256("handler-product");

    // Pre-minted actor pools (3 of each, indices 0-2)
    uint256[] internal buyerAgentIds;
    uint256[] internal reviewerAgentIds;
    uint256[] internal merchantIds;

    // -------------------------------------------------------------------------
    // Ghost variables
    // -------------------------------------------------------------------------

    uint256 public ghost_depositCount;
    uint256[] public ghost_escrowIds;
    /// @dev heldBackAmt still owed to someone (0 once settled)
    mapping(uint256 => uint256) public ghost_heldBackPending;
    /// @dev cashbackAmt still owed to someone (0 once released)
    mapping(uint256 => uint256) public ghost_cashbackPending;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        CommissionEscrow escrow_,
        MockUSDC usdc_,
        MockAgentRegistry agentRegistry_,
        MockMerchantRegistry merchantRegistry_,
        address splitRouter_,
        address oracle_,
        address reviewRegistryCaller_,
        address treasury_
    ) {
        escrow = escrow_;
        usdc = usdc_;
        agentRegistry = agentRegistry_;
        merchantRegistry = merchantRegistry_;
        splitRouter = splitRouter_;
        oracle = oracle_;
        reviewRegistryCaller = reviewRegistryCaller_;
        treasury = treasury_;

        // Pre-mint 3 buyers, 3 reviewers, 3 merchants.
        for (uint256 i = 0; i < 3; i++) {
            address buyerAddr = address(uint160(0xB000 + i));
            uint256 buyerAgentId = agentRegistry_.mint(buyerAddr);
            buyerAgentIds.push(buyerAgentId);

            address reviewerAddr = address(uint160(0xD000 + i));
            uint256 reviewerAgentId = agentRegistry_.mint(reviewerAddr);
            reviewerAgentIds.push(reviewerAgentId);

            address merchantOwner = address(uint160(0xA000 + i));
            uint256 merchantId = agentRegistry_.mint(merchantOwner);
            merchantIds.push(merchantId);
            merchantRegistry_.setActiveRaw(merchantId, true);
        }
    }

    // -------------------------------------------------------------------------
    // Bounded actions — called by invariant test runner
    // -------------------------------------------------------------------------

    /// @notice Creates a new escrow record. Mints USDC to the escrow contract
    ///         to simulate the transfer SplitRouter would have made.
    function deposit(uint256 heldBackAmt, uint256 cashbackAmt, uint256 merchantIdSeed) external {
        heldBackAmt = bound(heldBackAmt, 0, type(uint96).max / 2);
        cashbackAmt = bound(cashbackAmt, 0, type(uint96).max / 2);

        uint256 idx = merchantIdSeed % merchantIds.length;

        // Fund the escrow contract before deposit so transfers never underflow.
        usdc.mint(address(escrow), heldBackAmt + cashbackAmt);

        uint128 held = uint128(heldBackAmt);
        uint128 cash = uint128(cashbackAmt);
        uint128 total = uint128(heldBackAmt + cashbackAmt);

        vm.prank(splitRouter);
        uint256 escrowId = escrow.deposit(
            reviewerAgentIds[idx],
            buyerAgentIds[idx],
            address(uint160(0xB000 + idx)),
            merchantIds[idx],
            PRODUCT_ID,
            0, // productType = Repeat
            held,
            cash,
            total,
            0
        );

        ghost_depositCount++;
        ghost_heldBackPending[escrowId] = heldBackAmt;
        ghost_cashbackPending[escrowId] = cashbackAmt;
        ghost_escrowIds.push(escrowId);
    }

    /// @notice Oracle settles the held-back portion. Reverts if already Settled.
    function settleHeldBack(uint256 escrowIdSeed, uint8 unlockPct) external {
        if (ghost_escrowIds.length == 0) return;
        uint256 escrowId = ghost_escrowIds[escrowIdSeed % ghost_escrowIds.length];

        vm.prank(oracle);
        try escrow.settleHeldBack(escrowId, unlockPct) {
            ghost_heldBackPending[escrowId] = 0;
        } catch {}
    }

    /// @notice Oracle releases cashback to the buyer. Idempotent — contract no-ops
    ///         if already released, so ghost update is safe on success too.
    function releaseCashback(uint256 escrowIdSeed) external {
        if (ghost_escrowIds.length == 0) return;
        uint256 escrowId = ghost_escrowIds[escrowIdSeed % ghost_escrowIds.length];

        vm.prank(reviewRegistryCaller);
        try escrow.releaseCashback(escrowId) {
            ghost_cashbackPending[escrowId] = 0;
        } catch {}
    }

    /// @notice Oracle returns cashback to reviewer after windowEnd (day 60).
    ///         Reverts if cashback already released or window not yet elapsed.
    function cashbackToReviewer(uint256 escrowIdSeed) external {
        if (ghost_escrowIds.length == 0) return;
        uint256 escrowId = ghost_escrowIds[escrowIdSeed % ghost_escrowIds.length];

        vm.prank(oracle);
        try escrow.cashbackToReviewer(escrowId) {
            ghost_cashbackPending[escrowId] = 0;
        } catch {}
    }

    /// @notice Public fallback after windowEnd + 10 days (day 70).
    ///         Settles heldBack to treasury and unreleased cashback to merchant.
    function triggerSettleFallback(uint256 escrowIdSeed) external {
        if (ghost_escrowIds.length == 0) return;
        uint256 escrowId = ghost_escrowIds[escrowIdSeed % ghost_escrowIds.length];

        try escrow.triggerSettleFallback(escrowId) {
            ghost_heldBackPending[escrowId] = 0;
            ghost_cashbackPending[escrowId] = 0;
        } catch {}
    }

    /// @notice Advances block time by up to 100 days to exercise time-gated paths.
    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 0, 100 days);
        vm.warp(block.timestamp + seconds_);
    }

    // -------------------------------------------------------------------------
    // Ghost helpers
    // -------------------------------------------------------------------------

    /// @notice Sum of all pending (unsettled / unreleased) USDC amounts tracked
    ///         by ghost variables. Invariant: must equal escrow's USDC balance.
    function ghost_sumPendingAmts() external view returns (uint256 total) {
        for (uint256 i = 0; i < ghost_escrowIds.length; i++) {
            uint256 id = ghost_escrowIds[i];
            total += ghost_heldBackPending[id] + ghost_cashbackPending[id];
        }
    }

    function escrowIdCount() external view returns (uint256) {
        return ghost_escrowIds.length;
    }

    function escrowIdAt(uint256 index) external view returns (uint256) {
        return ghost_escrowIds[index];
    }
}
