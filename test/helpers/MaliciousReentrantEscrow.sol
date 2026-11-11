// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";
import {ISplitRouter} from "../../src/interfaces/ISplitRouter.sol";

/// @dev Reentrancy attacker for splitCharge's nonReentrant guard (deferred finding M-6). Installed
///      at PAR's ESCROW key in place of MockCommissionEscrow. deposit() calls back into
///      SplitRouter.splitCharge() with attacker-supplied (but oracle-signed) parameters for a
///      DIFFERENT paymentRef than whatever outer call reached this deposit() — a same-ref replay
///      would trip `_chargeSettled[ref]` and prove nothing about nonReentrant. depositCallCount is
///      incremented before the reentrant call so a test can confirm it reads back 0 after the
///      outer call reverts (i.e. the attempted deposit did not durably happen either).
contract MaliciousReentrantEscrow is ICommissionEscrow {
    ISplitRouter public router;
    bytes32 public reentryPaymentRef;
    uint256 public reentryAmount;
    address public reentryPayer;
    bytes public reentrySig;
    ISplitRouter.Attribution public reentryAttr;
    uint256 public depositCallCount;

    function setReentryCall(
        address router_,
        bytes32 paymentRef_,
        uint256 amount_,
        address payer_,
        ISplitRouter.Attribution calldata attr_,
        bytes calldata sig_
    ) external {
        router = ISplitRouter(router_);
        reentryPaymentRef = paymentRef_;
        reentryAmount = amount_;
        reentryPayer = payer_;
        reentryAttr = attr_;
        reentrySig = sig_;
    }

    function deposit(uint256, uint256, address, uint256, bytes32, uint8, uint128, uint128, uint128, uint256)
        external
        returns (uint256 escrowId)
    {
        depositCallCount++;
        router.splitCharge(reentryPaymentRef, reentryAmount, reentryPayer, reentryAttr, reentrySig);
        return 1;
    }

    function bind(uint256, uint256) external {}
    function settleHeldBack(uint256, uint8) external {}
    function releaseCashback(uint256) external {}
    function cashbackToReviewer(uint256) external {}
    function triggerSettleFallback(uint256) external {}
    function setTreasury(address) external {}
    function setSettlementWindow(uint40) external {}
    function pause() external {}
    function unpause() external {}

    function getEscrow(uint256) external pure returns (EscrowRecord memory) {
        return EscrowRecord({
            reviewerAgentId: 0,
            buyerAgentId: 0,
            buyerWallet: address(0),
            pausedTotalAtDeposit: 0,
            merchantId: 0,
            productId: bytes32(0),
            heldBackAmt: 0,
            cashbackAmt: 0,
            originalPurchaseAmt: 0,
            depositTimestamp: 0,
            windowEnd: 0,
            productType: 0,
            state: EscrowState.Holding,
            cashbackReleased: false
        });
    }

    function totalEscrows() external pure returns (uint256) {
        return 0;
    }

    function usdc() external pure returns (address) {
        return address(0);
    }

    function treasury() external pure returns (address) {
        return address(0);
    }

    function settlementWindow() external pure returns (uint40) {
        return 0;
    }

    function totalPausedSeconds() external pure returns (uint40) {
        return 0;
    }

    function paused() external pure returns (bool) {
        return false;
    }
}
