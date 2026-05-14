// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {IERC20Minimal} from "../../src/amm/interfaces/IERC20Minimal.sol";

abstract contract AMMScriptBase is Script {
    function _privateKey() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    function _sender() internal view returns (address) {
        return vm.addr(_privateKey());
    }

    function _pool() internal view returns (MinimalDodoPMM) {
        return MinimalDodoPMM(vm.envAddress("POOL"));
    }

    function _baseToken(MinimalDodoPMM pool) internal view returns (IERC20Minimal) {
        return pool.baseToken();
    }

    function _quoteToken(MinimalDodoPMM pool) internal view returns (IERC20Minimal) {
        return pool.quoteToken();
    }

    function _approveBase(MinimalDodoPMM pool) internal {
        _baseToken(pool).approve(address(pool), type(uint256).max);
    }

    function _approveQuote(MinimalDodoPMM pool) internal {
        _quoteToken(pool).approve(address(pool), type(uint256).max);
    }
}
