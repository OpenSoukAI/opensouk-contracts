// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title SplitMath
/// @notice Pure commission/cashback/fee split arithmetic. Shared by both of SplitRouter's rails —
///         x402 `route()` and MPP `splitCharge()` — so the formula cannot drift between them.
///
///         Split calculation:
///           base_commission      = grossAmount × commissionBps / 10_000
///           immediate_commission = base_commission × commissionMultiplierBps / 10_000
///           held_back            = base_commission − immediate_commission
///           cashback             = base_commission × lockedCashbackBps / 10_000   (share OF COMMISSION)
///           platform_fee         = grossAmount × platformFeeBps / 10_000
///           merchant_net         = grossAmount − base_commission − platform_fee
///           reviewer_immediate_net = immediate_commission − cashback
///
/// @dev Value conservation holds exactly:
///        reviewer_immediate_net + held_back + cashback + platform_fee + merchant_net == grossAmount
///      because every term is derived by subtraction from `baseCommission` and `grossAmount`
///      (no independent rounding leaks). Rounding dust from the two floor divisions stays with
///      the merchant (via `merchant_net`) and the held-back (via `held_back`).
///
///      Constraint chain that makes cashback always fundable from the reviewer's immediate cut:
///        lockedCashbackBps ≤ maxCashbackBpsOfCommission ≤ MULTIPLIER_MIN ≤ commissionMultiplierBps
///      so in exact arithmetic `cashback ≤ immediate_commission`, and `reviewer_immediate_net ≥ 0`.
library SplitMath {
    /// @dev All amounts in the token's base units. Callers narrow to uint128 for escrow storage.
    struct Split {
        uint256 immediateCommission; // reviewer's share paid at purchase, BEFORE cashback is carved out
        uint256 heldBack; // reviewer's share escrowed until the oracle settles
        uint256 platformFeeAmt; // treasury
        uint256 cashbackAmt; // buyer rebate, escrowed; funded from immediateCommission
        uint256 merchantAmt; // merchant net
        uint256 reviewerImmediateNet; // immediate − cashback (what the reviewer is paid at purchase)
    }

    /// @dev Basis-point denominator (100% = 10_000).
    uint256 internal constant BPS_DENOM = 10_000;
    /// @dev Lower bound of `commissionMultiplierBps` (≥ 40% of commission is paid immediately) AND
    ///      the ceiling of the cashback cap. Tying both to one constant is what guarantees
    ///      cashback ≤ immediate (see the contract header).
    uint16 internal constant MULTIPLIER_MIN = 4_000;

    /// @notice Thrown when commission + platform fee exceeds 100% (negative merchant net).
    error RatesExceedTotal(uint16 commissionBps, uint16 platformFeeBps);

    /// @notice Thrown when commissionMultiplierBps is outside [4000, 10000].
    error MultiplierOutOfRange(uint16 multiplierBps);

    /// @notice Thrown when the reviewer cashback rate (a share of commission) exceeds the
    ///         admin cap (cashbackBps must be ≤ maxCashbackBpsOfCommission).
    error CashbackExceedsCommissionCap(uint16 cashbackBps, uint16 commissionBps, uint16 maxCashbackBpsOfCommission);

    /// @notice Thrown when the supplied admin cap exceeds the immutable structural ceiling MULTIPLIER_MIN.
    error CapAboveCeiling(uint16 maxCashbackBpsOfCommission);

    /// @notice Computes the payment split. Pure — fee rate is passed in by the caller.
    /// @param grossAmount                  Total amount being split.
    /// @param commissionBps          Reviewer commission rate, read LIVE from ProductRegistry by the caller.
    /// @param lockedCashbackBps            Buyer cashback rate as a share OF COMMISSION (locked at review submission).
    /// @param platformFeeBps               Platform fee rate (the router's current rate).
    /// @param commissionMultiplierBps      Immediate/held-back split of the commission; must be [4000, 10000].
    /// @param maxCashbackBpsOfCommission   Admin cap: cashbackBps ≤ cap; must be ≤ MULTIPLIER_MIN.
    /// @return s The split. All four constraint checks run before any arithmetic.
    function compute(
        uint256 grossAmount,
        uint16 commissionBps,
        uint16 lockedCashbackBps,
        uint16 platformFeeBps,
        uint16 commissionMultiplierBps,
        uint16 maxCashbackBpsOfCommission
    ) internal pure returns (Split memory s) {
        // Widen before adding: two uint16 near 10_000 would not overflow uint16 (max 65_535),
        // but the widening makes the intent explicit and future-proofs a denominator change.
        if (uint256(commissionBps) + uint256(platformFeeBps) > BPS_DENOM) {
            revert RatesExceedTotal(commissionBps, platformFeeBps);
        }
        if (commissionMultiplierBps < MULTIPLIER_MIN || commissionMultiplierBps > BPS_DENOM) {
            revert MultiplierOutOfRange(commissionMultiplierBps);
        }
        // Admin cap can only tighten; it can never exceed the structural ceiling (worst-case immediate).
        if (maxCashbackBpsOfCommission > MULTIPLIER_MIN) {
            revert CapAboveCeiling(maxCashbackBpsOfCommission);
        }
        // Reviewer-funded cashback cap: cashback is a share OF COMMISSION, so the cap is a direct
        // bps ceiling (≤ maxCashbackBpsOfCommission ≤ MULTIPLIER_MIN ≤ worst-case immediate multiplier).
        if (lockedCashbackBps > maxCashbackBpsOfCommission) {
            revert CashbackExceedsCommissionCap(lockedCashbackBps, commissionBps, maxCashbackBpsOfCommission);
        }

        // grossAmount * commissionBps cannot overflow: grossAmount is a USDC amount (≪ 2^240).
        uint256 baseCommission = grossAmount * commissionBps / BPS_DENOM;
        s.immediateCommission = baseCommission * commissionMultiplierBps / BPS_DENOM;
        s.heldBack = baseCommission - s.immediateCommission;
        s.cashbackAmt = baseCommission * lockedCashbackBps / BPS_DENOM;
        // Belt-and-braces clamp. Both immediateCommission and cashbackAmt are a single floor of
        // `baseCommission × rate / BPS_DENOM`, and floor is monotone in `rate`, so with
        // lockedCashbackBps ≤ commissionMultiplierBps (guaranteed by the constraint chain above)
        // cashbackAmt ≤ immediateCommission ALWAYS holds and this branch is unreachable. Kept so
        // value conservation survives if the constraint chain is ever loosened; not a live path
        // and not coverable by tests (SM-01).
        if (s.cashbackAmt > s.immediateCommission) {
            s.cashbackAmt = s.immediateCommission;
        }
        s.reviewerImmediateNet = s.immediateCommission - s.cashbackAmt; // ≥ 0
        s.platformFeeAmt = grossAmount * platformFeeBps / BPS_DENOM;
        // Cashback is NOT deducted here: it comes out of the reviewer's immediate cut, not the
        // merchant's. Cannot underflow: commission + fee ≤ 100% is checked above.
        s.merchantAmt = grossAmount - baseCommission - s.platformFeeAmt; // cashback no longer deducted
    }
}
