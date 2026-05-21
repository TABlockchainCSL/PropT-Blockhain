// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {AMMScriptBase} from "./AMMScriptBase.s.sol";

contract EnableTradingScript is AMMScriptBase {
    function run() external {
        PropertyPMM pool = _pool();
        uint256 privateKey = _privateKey();

        vm.startBroadcast(privateKey);
        pool.enableTrading();
        vm.stopBroadcast();

        console2.log("pool:", address(pool));
        console2.log("owner:", _sender());
        console2.log("tradingEnabled:", pool.tradingEnabled());
    }
}
