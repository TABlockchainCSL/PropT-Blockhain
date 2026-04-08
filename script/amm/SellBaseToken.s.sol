// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {AMMScriptBase} from "./AMMScriptBase.s.sol";

contract SellBaseTokenScript is AMMScriptBase {
    function run() external returns (uint256 receiveQuote) {
        MinimalDodoPMM pool = _pool();
        uint256 privateKey = _privateKey();
        uint256 sellAmount = vm.envUint("BASE_AMOUNT");
        uint256 quotedReceive = pool.querySellBaseToken(sellAmount);
        uint256 minReceiveQuote = vm.envOr("MIN_RECEIVE_QUOTE", quotedReceive);

        vm.startBroadcast(privateKey);
        _approveBase(pool);
        receiveQuote = pool.sellBaseToken(sellAmount, minReceiveQuote);
        vm.stopBroadcast();

        console2.log("pool:", address(pool));
        console2.log("seller:", _sender());
        console2.log("baseSold:", sellAmount);
        console2.log("quotedReceive:", quotedReceive);
        console2.log("minReceiveQuote:", minReceiveQuote);
        console2.log("receiveQuote:", receiveQuote);
    }
}
