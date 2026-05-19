// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "./MathHelpers.sol";

library DecimalMath {
    uint256 internal constant ONE = 1e18;

    function mul(uint256 target, uint256 d) internal pure returns (uint256) {
        return (target * d) / ONE;
    }

    function mulCeil(uint256 target, uint256 d) internal pure returns (uint256) {
        return MathHelpers.ceilDiv(target * d, ONE);
    }

    function divFloor(uint256 target, uint256 d) internal pure returns (uint256) {
        require(d != 0, "DIV_BY_ZERO");
        return (target * ONE) / d;
    }

    function divCeil(uint256 target, uint256 d) internal pure returns (uint256) {
        require(d != 0, "DIV_BY_ZERO");
        return MathHelpers.ceilDiv(target * ONE, d);
    }
}
