// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";

/// @dev External wrapper so `vm.expectRevert` sees a lower-depth call (the library is internal
///      and would otherwise inline into the test, defeating expectRevert).
contract SplitMathUnitHarness {
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

contract SplitMathTest is Test {
    uint16 constant CAP = 4_000; // = MULTIPLIER_MIN, the default admin cap

    SplitMathUnitHarness internal h;

    function setUp() public {
        h = new SplitMathUnitHarness();
    }

    function test_compute_cashbackIsShareOfCommission_merchantUnaffected() public pure {
        // gross 1000, commission 10% (base 100), multiplier 100% (immediate 100),
        // cashback 40% OF COMMISSION (4000 bps → 100 × 0.40 = 40), fee 0.
        SplitMath.Split memory s = SplitMath.compute(1000, 1000, 4000, 0, 10_000, CAP);
        assertEq(s.cashbackAmt, 40);
        assertEq(s.immediateCommission, 100);
        assertEq(s.reviewerImmediateNet, 60); // 100 - 40
        assertEq(s.heldBack, 0);
        assertEq(s.merchantAmt, 900); // 1000 - 100 commission - 0 fee (cashback NOT deducted)
    }

    function test_compute_revertsWhenCashbackExceedsCap() public {
        // cashback is a share OF COMMISSION; cap 40% → max 4000 bps. 4001 must revert.
        vm.expectRevert(
            abi.encodeWithSelector(SplitMath.CashbackExceedsCommissionCap.selector, uint16(4001), uint16(1000), CAP)
        );
        h.compute(1000, 1000, 4001, 0, 4_000, CAP);
    }

    function test_compute_adminCapTightensBelowCeiling() public {
        // admin cap 30% of commission: cashback 3000 bps ok (100 × 0.30 = 30), 4000 reverts.
        SplitMath.Split memory ok = SplitMath.compute(1000, 1000, 3000, 0, 10_000, 3_000);
        assertEq(ok.cashbackAmt, 30);
        vm.expectRevert(
            abi.encodeWithSelector(
                SplitMath.CashbackExceedsCommissionCap.selector, uint16(4000), uint16(1000), uint16(3_000)
            )
        );
        h.compute(1000, 1000, 4000, 0, 10_000, 3_000);
    }

    function test_compute_revertsWhenCapAboveCeiling() public {
        // a cap above MULTIPLIER_MIN (4000) is rejected defensively.
        vm.expectRevert(abi.encodeWithSelector(SplitMath.CapAboveCeiling.selector, uint16(4_001)));
        h.compute(1000, 1000, 0, 0, 10_000, 4_001);
    }

    function test_compute_capHoldsAtWorstCaseMultiplier() public pure {
        // multiplier at floor 4000: immediate = base×0.4 = 40; cashback at cap 40% of commission = 40 → net 0.
        SplitMath.Split memory s = SplitMath.compute(1000, 1000, 4000, 0, 4_000, CAP);
        assertEq(s.immediateCommission, 40);
        assertEq(s.cashbackAmt, 40);
        assertEq(s.reviewerImmediateNet, 0);
    }

    function test_compute_cashbackNeverExceedsImmediate_dustAmounts() public pure {
        // Of-commission cashback can never exceed immediate (cashbackBps ≤ cap ≤ MULTIPLIER_MIN ≤ multiplier),
        // so the clamp at :81-83 is a defensive guard. Dust: base=2, immediate floors to 0, cashback floors to 0.
        SplitMath.Split memory s = SplitMath.compute(5000, 5, 4000, 0, 4_000, 4_000);
        assertEq(s.immediateCommission, 0);
        assertEq(s.cashbackAmt, 0);
        assertEq(s.reviewerImmediateNet, 0); // no underflow
    }
}
