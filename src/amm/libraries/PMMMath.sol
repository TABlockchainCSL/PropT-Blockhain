// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "./DecimalMath.sol";
import "./MathHelpers.sol";

library PMMMath {
    using MathHelpers for uint256;

    function generalIntegrate(uint256 v0, uint256 v1, uint256 v2, uint256 i, uint256 k)
        internal
        pure
        returns (uint256)
    {
        uint256 fairAmount = DecimalMath.mul(i, v1 - v2);
        uint256 penalty = DecimalMath.mul(k, DecimalMath.divCeil((v0 * v0) / v1, v2));
        return DecimalMath.mul(fairAmount, DecimalMath.ONE - k + penalty);
    }

    function solveQuadraticFunctionForTrade(uint256 q0, uint256 q1, uint256 iDeltaB, bool deltaBSig, uint256 k)
        internal
        pure
        returns (uint256)
    {
        uint256 kQ02Q1 = (DecimalMath.mul(k, q0) * q0) / q1;
        uint256 b = DecimalMath.mul(DecimalMath.ONE - k, q1);
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

        uint256 squareRoot = DecimalMath.mul((DecimalMath.ONE - k) * 4, DecimalMath.mul(k, q0) * q0);
        squareRoot = (b * b + squareRoot).sqrt();

        uint256 denominator = (DecimalMath.ONE - k) * 2;
        uint256 numerator = minusBSig ? b + squareRoot : squareRoot - b;

        return deltaBSig ? DecimalMath.divFloor(numerator, denominator) : DecimalMath.divCeil(numerator, denominator);
    }

    function solveQuadraticFunctionForTarget(uint256 v1, uint256 k, uint256 fairAmount)
        internal
        pure
        returns (uint256 v0)
    {
        uint256 root = DecimalMath.divCeil(DecimalMath.mul(k, fairAmount) * 4, v1);
        root = ((root + DecimalMath.ONE) * DecimalMath.ONE).sqrt();
        uint256 premium = DecimalMath.divCeil(root - DecimalMath.ONE, k * 2);
        return DecimalMath.mul(v1, DecimalMath.ONE + premium);
    }
}
