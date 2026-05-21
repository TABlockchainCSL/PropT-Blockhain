// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {AMMScriptBase} from "./AMMScriptBase.s.sol";

contract ClaimQuoteDividendsScript is AMMScriptBase {
    function run() external returns (uint256 quoteAmount) {
        PropertyPMM pool = _pool();
        uint256 privateKey = _privateKey();
        address dividendDistributor = vm.envAddress("DIVIDEND_DISTRIBUTOR");
        uint256 maxEpochs = vm.envOr("MAX_EPOCHS", type(uint256).max);

        vm.startBroadcast(privateKey);
        quoteAmount = pool.claimQuoteDividends(dividendDistributor, maxEpochs);
        vm.stopBroadcast();

        console2.log("pool:", address(pool));
        console2.log("dividendDistributor:", dividendDistributor);
        console2.log("quoteClaimed:", quoteAmount);
        console2.log("quoteBalance:", pool.quoteBalance());
        console2.log("targetQuoteTokenAmount:", pool.targetQuoteTokenAmount());
    }
}
