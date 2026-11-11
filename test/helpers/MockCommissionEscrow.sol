// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICommissionEscrow} from "../../src/interfaces/ICommissionEscrow.sol";

/// @dev Configurable stub for unit tests. deposit() auto-increments escrowId and stores
///      the record so callers can read it back via getEscrow().
contract MockCommissionEscrow is ICommissionEscrow {
    uint256 private _nextEscrowId = 1;
    mapping(uint256 => EscrowRecord) private _escrows;
    bool private _paused;
    address public immutable usdc_;
    address private _treasury;
    uint40 private _settlementWindow = uint40(60 days);

    constructor(address usdc__, address treasury_) {
        usdc_ = usdc__;
        _treasury = treasury_;
    }

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setEscrowRaw(uint256 escrowId, EscrowRecord calldata record) external {
        _escrows[escrowId] = record;
    }

    function setNextEscrowId(uint256 id) external {
        _nextEscrowId = id;
    }

    // -------------------------------------------------------------------------
    // ICommissionEscrow
    // -------------------------------------------------------------------------

    function deposit(
        uint256 reviewerAgentId,
        uint256 buyerAgentId,
        address buyerWallet,
        uint256 merchantId,
        bytes32 productId,
        uint8 productType,
        uint128 heldBackAmt,
        uint128 cashbackAmt,
        uint128 originalPurchaseAmt,
        uint256 reviewId
    ) external returns (uint256 escrowId) {
        escrowId = _nextEscrowId++;
        uint40 ts = uint40(block.timestamp);
        _escrows[escrowId] = EscrowRecord({
            reviewerAgentId: reviewerAgentId,
            buyerAgentId: buyerAgentId,
            buyerWallet: buyerWallet,
            pausedTotalAtDeposit: 0,
            merchantId: merchantId,
            productId: productId,
            heldBackAmt: heldBackAmt,
            cashbackAmt: cashbackAmt,
            originalPurchaseAmt: originalPurchaseAmt,
            depositTimestamp: ts,
            windowEnd: ts + _settlementWindow,
            productType: productType,
            state: EscrowState.Holding,
            cashbackReleased: false
        });
        emit EscrowDeposited(
            escrowId,
            reviewerAgentId,
            buyerAgentId,
            buyerWallet,
            reviewId,
            merchantId,
            productId,
            heldBackAmt,
            cashbackAmt
        );
    }

    function settleHeldBack(uint256, uint8) external {}

    function releaseCashback(uint256) external {}

    function cashbackToReviewer(uint256) external {}

    function triggerSettleFallback(uint256) external {}

    function setTreasury(address newTreasury) external {
        _treasury = newTreasury;
    }

    function setSettlementWindow(uint40 newWindow) external {
        _settlementWindow = newWindow;
    }

    function pause() external {
        _paused = true;
    }

    function unpause() external {
        _paused = false;
    }

    function getEscrow(uint256 escrowId) external view returns (EscrowRecord memory) {
        return _escrows[escrowId];
    }

    function bind(uint256 escrowId, uint256 agentId) external {
        _escrows[escrowId].buyerAgentId = agentId;
    }

    function totalEscrows() external view returns (uint256) {
        return _nextEscrowId - 1;
    }

    function usdc() external view returns (address) {
        return usdc_;
    }

    function treasury() external view returns (address) {
        return _treasury;
    }

    function settlementWindow() external view returns (uint40) {
        return _settlementWindow;
    }

    function totalPausedSeconds() external pure returns (uint40) {
        return 0;
    }

    function paused() external view returns (bool) {
        return _paused;
    }
}
