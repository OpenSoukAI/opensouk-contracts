// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title ProtocolConstants
/// @notice Shared protocol-wide constants — single source of truth so SplitRouter
///         and CommissionEscrow can't drift on the same magic value.
library ProtocolConstants {
    /// @notice Sentinel buyer agent id for agent-less purchases. A real ERC-8004
    ///         agent id can never equal it (IdentityRegistry mints from 0 upward), so it
    ///         unambiguously marks an escrow whose buyer wallet is bound to an identity later.
    uint256 internal constant SENTINEL_BUYER = type(uint256).max;

    /// @notice Sentinel reviewer agent id recorded on a no-referral escrow (`reviewId == 0`).
    ///         Same value as SENTINEL_BUYER but a different field: never compare one against
    ///         the other's constant.
    uint256 internal constant SENTINEL_REVIEWER = type(uint256).max;
}
