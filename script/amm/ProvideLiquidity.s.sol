// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {AMMScriptBase} from "./AMMScriptBase.s.sol";

contract ProvideLiquidityScript is AMMScriptBase {
    function run() external returns (uint256 sharesMinted, uint256 baseAmount, uint256 quoteAmount) {
        MinimalDodoPMM pool = _pool();
        uint256 privateKey = _privateKey();
        uint256 baseAmountMax = vm.envUint("BASE_AMOUNT");
        uint256 quoteAmountMax = vm.envUint("QUOTE_AMOUNT");
        uint256 minShares = vm.envOr("MIN_SHARES", uint256(0));

        vm.startBroadcast(privateKey);
        _approveBase(pool);
        _approveQuote(pool);
        (sharesMinted, baseAmount, quoteAmount) = pool.provideLiquidity(baseAmountMax, quoteAmountMax, minShares);
        vm.stopBroadcast();

        console2.log("pool:", address(pool));
        console2.log("provider:", _sender());
        console2.log("sharesMinted:", sharesMinted);
        console2.log("baseAdded:", baseAmount);
        console2.log("quoteAdded:", quoteAmount);
    }
}
