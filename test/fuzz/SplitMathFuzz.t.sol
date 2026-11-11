// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";

/// @dev External wrapper so `vm.expectRevert` sees a lower-depth call (the library is internal
///      and would otherwise inline into the test, defeating expectRevert).
contract SplitMathHarness {
    function compute(
        uint256 gross,
        uint16 commissionBps,
        uint16 cashbackBps,
        uint16 feeBps,
        uint16 multiplierBps,
        uint16 maxCashbackBpsOfCommission
    ) external pure returns (SplitMath.Split memory) {
        return SplitMath.compute(gross, commissionBps, cashbackBps, feeBps, multiplierBps, maxCashbackBpsOfCommission);
    }
}

/// @dev Fuzzes the shared pure split formula (used by both of SplitRouter's rails — route + splitCharge).
contract SplitMathFuzz is Test {
    SplitMathHarness internal h = new SplitMathHarness();

    function testFuzz_Conservation(
        uint256 gross,
        uint16 commissionBps,
        uint16 cashbackBps,
        uint16 feeBps,
        uint16 multiplierBps
    ) public pure {
        gross = bound(gross, 0, 1e30);
        commissionBps = uint16(bound(commissionBps, 0, 10000));
        cashbackBps = uint16(bound(cashbackBps, 0, 10000));
        feeBps = uint16(bound(feeBps, 0, 10000));
        // Keep commission + fee ≤ 100% and multiplier in range so compute() doesn't revert.
        vm.assume(uint256(commissionBps) + feeBps <= 10000);
        // Cashback is a share OF COMMISSION, so the cap is a direct bps ceiling (≤ MULTIPLIER_MIN = 4000).
        cashbackBps = uint16(bound(cashbackBps, 0, 4000));
        multiplierBps = uint16(bound(multiplierBps, 4000, 10000));

        SplitMath.Split memory s = SplitMath.compute(gross, commissionBps, cashbackBps, feeBps, multiplierBps, 4_000);

        // Cashback is reviewer-funded (carved from immediateCommission), not a separate gross deduction.
        // Conservation: immediateCommission + heldBack + platformFeeAmt + merchantAmt == gross.
        // cashbackAmt is a sub-component of immediateCommission, so NOT added separately.
        assertEq(s.immediateCommission + s.heldBack + s.platformFeeAmt + s.merchantAmt, gross);

        // immediate + held == base commission.
        uint256 baseCommission = gross * commissionBps / 10_000;
        assertEq(s.immediateCommission + s.heldBack, baseCommission);

        // reviewerImmediateNet == immediateCommission - cashbackAmt (≥ 0 by cap).
        assertEq(s.reviewerImmediateNet, s.immediateCommission - s.cashbackAmt);
        assertLe(s.cashbackAmt, s.immediateCommission);

        // Components never exceed their share. Cashback is a share OF COMMISSION.
        assertLe(s.immediateCommission, baseCommission);
        assertLe(s.cashbackAmt, baseCommission * cashbackBps / 10_000);
        assertEq(s.platformFeeAmt, gross * feeBps / 10_000);
    }

    function testFuzz_Revert_RatesExceedTotal(uint16 commissionBps, uint16 feeBps) public {
        commissionBps = uint16(bound(commissionBps, 0, 10000));
        feeBps = uint16(bound(feeBps, 0, 10000));
        vm.assume(uint256(commissionBps) + feeBps > 10000);
        // cashbackBps is irrelevant to this revert — only commission + fee is checked.
        vm.expectRevert(abi.encodeWithSelector(SplitMath.RatesExceedTotal.selector, commissionBps, feeBps));
        h.compute(100e6, commissionBps, 0, feeBps, 7000, 4_000);
    }

    function testFuzz_Revert_MultiplierOutOfRange(uint16 multiplierBps) public {
        vm.assume(multiplierBps < 4000 || multiplierBps > 10000);
        vm.expectRevert(abi.encodeWithSelector(SplitMath.MultiplierOutOfRange.selector, multiplierBps));
        h.compute(100e6, 1000, 0, 200, multiplierBps, 4_000);
    }

    /// @dev Explicit conservation in reviewerImmediateNet + heldBack + cashbackAmt + platformFeeAmt + merchantAmt form.
    ///      cashbackAmt is carved from immediateCommission (reviewer-funded), so:
    ///        reviewerImmediateNet + cashbackAmt == immediateCommission
    ///        => reviewerImmediateNet + cashbackAmt + heldBack + platformFeeAmt + merchantAmt == gross.
    /// @dev SM-01: the `cashbackAmt > immediateCommission` clamp in compute() is unreachable while the
    ///      constraint chain holds (cashbackBps ≤ cap ≤ MULTIPLIER_MIN ≤ multiplierBps), because both
    ///      values are a single floor of `base × rate / 10_000` and floor is monotone in the rate.
    ///      Pin that: the returned cashback must equal the UNCLAMPED formula for every valid input.
    ///      Fails the moment the chain is loosened enough for the clamp to bite.
    function testFuzz_DustClamp_NeverFires(
        uint256 gross,
        uint16 commissionBps,
        uint16 cashbackBps,
        uint16 feeBps,
        uint16 multiplierBps,
        uint16 adminCap
    ) public pure {
        gross = bound(gross, 0, 1e30);
        commissionBps = uint16(bound(commissionBps, 0, 10_000));
        feeBps = uint16(bound(feeBps, 0, 10_000));
        vm.assume(uint256(commissionBps) + feeBps <= 10_000);
        adminCap = uint16(bound(adminCap, 0, 4_000));
        cashbackBps = uint16(bound(cashbackBps, 0, adminCap));
        multiplierBps = uint16(bound(multiplierBps, 4_000, 10_000));

        SplitMath.Split memory s = SplitMath.compute(gross, commissionBps, cashbackBps, feeBps, multiplierBps, adminCap);

        uint256 baseCommission = gross * commissionBps / 10_000;
        assertEq(s.cashbackAmt, baseCommission * cashbackBps / 10_000, "clamp altered cashback");
        assertEq(s.immediateCommission, baseCommission * multiplierBps / 10_000, "immediate formula");
        // Direct statement of why the clamp cannot fire.
        assertLe(s.cashbackAmt, s.immediateCommission, "cashback exceeded immediate");
    }

    function testFuzz_ReviewerFundedConservation(uint256 gross, uint16 cBps, uint16 cbBps, uint16 mBps, uint16 fBps)
        public
        pure
    {
        gross = bound(gross, 1, 1e18);
        cBps = uint16(bound(cBps, 0, 5_000));
        fBps = uint16(bound(fBps, 0, 1_000));
        mBps = uint16(bound(mBps, 4_000, 10_000));
        // Cashback is a share OF COMMISSION, capped directly at MULTIPLIER_MIN (4000 bps = 40%).
        cbBps = uint16(bound(cbBps, 0, 4_000));
        vm.assume(uint256(cBps) + fBps <= 10_000);

        SplitMath.Split memory s = SplitMath.compute(gross, cBps, cbBps, fBps, mBps, 4_000);

        // Reviewer-funded form: reviewerImmediateNet + cashbackAmt == immediateCommission.
        assertEq(s.reviewerImmediateNet + s.cashbackAmt, s.immediateCommission, "reviewer + cashback == immediate");
        // Full conservation: reviewer + cashback + held + fee + merchant == gross.
        assertEq(
            s.reviewerImmediateNet + s.heldBack + s.cashbackAmt + s.platformFeeAmt + s.merchantAmt,
            gross,
            "full conservation"
        );
        // Cashback never exceeds immediate (post-clamp).
        assertLe(s.cashbackAmt, s.immediateCommission, "cashback fits in immediate");
    }

    /// @dev Cap enforcement: cashback (a share of commission) must revert when cashbackBps > adminCap.
    ///      Tests both in-cap (must succeed) and over-cap (must revert) for random rates.
    function testFuzz_CapEnforcement_InCapSucceeds_OverCapReverts(
        uint256 gross,
        uint16 cBps,
        uint16 adminCap,
        uint16 overCap
    ) public {
        gross = bound(gross, 1e6, 1e18);
        cBps = uint16(bound(cBps, 100, 5_000)); // non-zero commission so cashback is fundable
        adminCap = uint16(bound(adminCap, 0, 4_000));
        vm.assume(uint256(cBps) + 200 <= 10_000);

        // In-cap: cashbackBps == adminCap is the max allowed and must succeed.
        SplitMath.Split memory s = SplitMath.compute(gross, cBps, adminCap, 200, 7_000, adminCap);
        assertLe(s.cashbackAmt, s.immediateCommission, "in-cap: cashback fits in immediate");

        // Over-cap: any cashbackBps > adminCap must revert.
        if (adminCap < type(uint16).max) {
            overCap = uint16(bound(overCap, adminCap + 1, type(uint16).max));
            vm.expectRevert(
                abi.encodeWithSelector(SplitMath.CashbackExceedsCommissionCap.selector, overCap, cBps, adminCap)
            );
            h.compute(gross, cBps, overCap, 200, 7_000, adminCap);
        }
    }
}
