// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice PMM formulas adapted from DODO V1's proactive market maker model.
/// @dev The surrounding pool/accounting code is project-specific; this library keeps the DODO-style
///      integration and quadratic target/trade equations isolated for review and citation.
library PMMMath {
    uint256 private constant WAD = 1e18;

    /// @notice Integrate the PMM curve between two inventory points.
    function generalIntegrate(uint256 v0, uint256 v1, uint256 v2, uint256 i, uint256 k)
        internal
        pure
        returns (uint256)
    {
        uint256 fairAmount = FixedPointMathLib.mulWad(i, v1 - v2);
        uint256 penalty = FixedPointMathLib.mulWad(k, FixedPointMathLib.divWadUp((v0 * v0) / v1, v2));
        return FixedPointMathLib.mulWad(fairAmount, WAD - k + penalty);
    }

    /// @notice Solve the DODO PMM trade equation for the new reserve.
    function solveQuadraticFunctionForTrade(uint256 q0, uint256 q1, uint256 iDeltaB, bool deltaBSig, uint256 k)
        internal
        pure
        returns (uint256)
    {
        uint256 kQ02Q1 = (FixedPointMathLib.mulWad(k, q0) * q0) / q1;
        uint256 b = FixedPointMathLib.mulWad(WAD - k, q1);
        bool minusBSig = true;

        if (deltaBSig) {
            b += iDeltaB;
        } else {
            kQ02Q1 += iDeltaB;
        }

        if (b >= kQ02Q1) {
            b -= kQ02Q1;
        } else {
            b = kQ02Q1 - b;
            minusBSig = false;
        }

        uint256 squareRoot = FixedPointMathLib.mulWad((WAD - k) * 4, FixedPointMathLib.mulWad(k, q0) * q0);
        squareRoot = FixedPointMathLib.sqrt(b * b + squareRoot);

        uint256 denominator = (WAD - k) * 2;
        uint256 numerator = minusBSig ? b + squareRoot : squareRoot - b;

        return deltaBSig
            ? FixedPointMathLib.divWad(numerator, denominator)
            : FixedPointMathLib.divWadUp(numerator, denominator);
    }

    /// @notice Solve the DODO PMM target equation after inventory moves.
    function solveQuadraticFunctionForTarget(uint256 v1, uint256 k, uint256 fairAmount)
        internal
        pure
        returns (uint256 v0)
    {
        uint256 root = FixedPointMathLib.divWadUp(FixedPointMathLib.mulWad(k, fairAmount) * 4, v1);
        root = FixedPointMathLib.sqrt((root + WAD) * WAD);
        uint256 premium = FixedPointMathLib.divWadUp(root - WAD, k * 2);
        return FixedPointMathLib.mulWad(v1, WAD + premium);
    }
}
