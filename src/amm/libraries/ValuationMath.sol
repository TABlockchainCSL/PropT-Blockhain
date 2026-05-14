// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {MathHelpers} from "./MathHelpers.sol";

library ValuationMath {
    function effectiveK(
        uint256 baseK,
        uint256 maxK,
        uint256 growthPerSecond,
        uint256 updatedAt,
        uint256 currentTimestamp
    ) internal pure returns (uint256) {
        uint256 kRoom = maxK - baseK;
        if (growthPerSecond == 0 || kRoom == 0) {
            return baseK;
        }

        uint256 age = currentTimestamp - updatedAt;
        if (age >= MathHelpers.ceilDiv(kRoom, growthPerSecond)) {
            return maxK;
        }

        return baseK + (age * growthPerSecond);
    }
}
