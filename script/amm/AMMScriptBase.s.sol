// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

abstract contract AMMScriptBase is Script {
    function _privateKey() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    function _sender() internal view returns (address) {
        return vm.addr(_privateKey());
    }

    function _pool() internal view returns (PropertyPMM) {
        return PropertyPMM(vm.envAddress("POOL"));
    }

    function _baseToken(PropertyPMM pool) internal view returns (IERC20Metadata) {
        return pool.baseToken();
    }

    function _quoteToken(PropertyPMM pool) internal view returns (IERC20Metadata) {
        return pool.quoteToken();
    }

    function _approveBase(PropertyPMM pool) internal {
        _baseToken(pool).approve(address(pool), type(uint256).max);
    }

    function _approveQuote(PropertyPMM pool) internal {
        _quoteToken(pool).approve(address(pool), type(uint256).max);
    }
}
