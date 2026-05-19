// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {AMMScriptBase} from "./AMMScriptBase.s.sol";

contract ConfigureTaxScript is AMMScriptBase {
    function run() external {
        MinimalDodoPMM pool = _pool();
        uint256 privateKey = _privateKey();
        address taxRecipient = vm.envAddress("TAX_RECIPIENT");
        uint256 buyTaxRate = vm.envOr("BUY_TAX_RATE", uint256(0));
        uint256 sellTaxRate = vm.envOr("SELL_TAX_RATE", uint256(0));
        bool enableTax = vm.envOr("ENABLE_TAX", true);

        vm.startBroadcast(privateKey);
        pool.setTaxRecipient(taxRecipient);
        pool.setBuyTaxRate(buyTaxRate);
        pool.setSellTaxRate(sellTaxRate);
        if (enableTax) {
            pool.enableTax();
        } else {
            pool.disableTax();
        }
        vm.stopBroadcast();

        console2.log("pool:", address(pool));
        console2.log("owner:", _sender());
        console2.log("taxRecipient:", taxRecipient);
        console2.log("buyTaxRate:", pool.buyTaxRate());
        console2.log("sellTaxRate:", pool.sellTaxRate());
        console2.log("taxEnabled:", pool.taxEnabled());
    }
}
