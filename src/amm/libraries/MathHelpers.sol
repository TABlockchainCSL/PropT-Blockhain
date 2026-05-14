// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

library MathHelpers {
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "DIV_BY_ZERO");
        return a == 0 ? 0 : ((a - 1) / b) + 1;
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) {
            return 0;
        }

        uint256 z = (x / 2) + 1;
        y = x;
        while (z < y) {
            y = z;
            z = ((x / z) + z) / 2;
        }
    }
}
