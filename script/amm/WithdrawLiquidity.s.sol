// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {AMMScriptBase} from "./AMMScriptBase.s.sol";

contract WithdrawLiquidityScript is AMMScriptBase {
    function run() external returns (uint256 baseAmount, uint256 quoteAmount) {
        MinimalDodoPMM pool = _pool();
        uint256 privateKey = _privateKey();
        uint256 shares = vm.envUint("SHARES");
        uint256 minBaseAmount = vm.envOr("MIN_BASE_AMOUNT", uint256(0));
        uint256 minQuoteAmount = vm.envOr("MIN_QUOTE_AMOUNT", uint256(0));

        vm.startBroadcast(privateKey);
        (baseAmount, quoteAmount) = pool.withdrawLiquidity(shares, minBaseAmount, minQuoteAmount);
        vm.stopBroadcast();

        console2.log("pool:", address(pool));
        console2.log("lp:", _sender());
        console2.log("sharesBurned:", shares);
        console2.log("baseAmount:", baseAmount);
        console2.log("quoteAmount:", quoteAmount);
    }
}
