// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {AMMScriptBase} from "./AMMScriptBase.s.sol";

contract BuyBaseTokenScript is AMMScriptBase {
    function run() external returns (uint256 totalPaid) {
        PropertyPMM pool = _pool();
        uint256 privateKey = _privateKey();
        uint256 buyAmount = vm.envUint("BASE_AMOUNT");
        uint256 quotedCost = pool.queryBuyBaseToken(buyAmount);
        uint256 maxPayQuote = vm.envOr("MAX_PAY_QUOTE", quotedCost);

        vm.startBroadcast(privateKey);
        _approveQuote(pool);
        totalPaid = pool.buyBaseToken(buyAmount, maxPayQuote);
        vm.stopBroadcast();

        console2.log("pool:", address(pool));
        console2.log("buyer:", _sender());
        console2.log("baseBought:", buyAmount);
        console2.log("quotedCost:", quotedCost);
        console2.log("maxPayQuote:", maxPayQuote);
        console2.log("totalPaid:", totalPaid);
    }
}
