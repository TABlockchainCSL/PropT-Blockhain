// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PropertyPMM} from "../src/amm/PropertyPMM.sol";
import {TestnetERC20} from "../src/amm/testnet/TestnetERC20.sol";

contract DeployPropertyPMMScript is Script {
    uint256 internal constant LP_FEE_RATE = 5e15;
    uint256 internal constant MAINTAINER_FEE_RATE = 0;
    uint256 internal constant DEFAULT_K = 1e17;
    uint256 internal constant DEFAULT_INITIAL_VALUATION_PRICE = 100e18;
    uint256 internal constant DEFAULT_QUOTE_MINT_AMOUNT = 1_000_000e18;
    string internal constant DEFAULT_SHARE_NAME = "PropT AMM LP";
    string internal constant DEFAULT_SHARE_SYMBOL = "PAMM-LP";
    string internal constant DEFAULT_QUOTE_NAME = "USD";
    string internal constant DEFAULT_QUOTE_SYMBOL = "USD";

    function run() external returns (PropertyPMM pool) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        address baseToken = vm.envAddress("BASE_TOKEN");
        address quoteToken = vm.envOr("QUOTE_TOKEN", address(0));
        uint256 quoteMintAmount = vm.envOr("QUOTE_MINT_AMOUNT", DEFAULT_QUOTE_MINT_AMOUNT);
        uint256 initialValuationPrice = vm.envOr("INITIAL_VALUATION_PRICE", DEFAULT_INITIAL_VALUATION_PRICE);

        vm.startBroadcast(privateKey);

        if (quoteToken == address(0)) {
            TestnetERC20 quote = new TestnetERC20(DEFAULT_QUOTE_NAME, DEFAULT_QUOTE_SYMBOL, 18);
            quote.mint(deployer, quoteMintAmount);
            quoteToken = address(quote);
        }

        pool = new PropertyPMM(
            deployer,
            deployer,
            address(0),
            baseToken,
            quoteToken,
            initialValuationPrice,
            LP_FEE_RATE,
            MAINTAINER_FEE_RATE,
            DEFAULT_K,
            DEFAULT_SHARE_NAME,
            DEFAULT_SHARE_SYMBOL
        );

        vm.stopBroadcast();

        console2.log("PropertyPMM deployed at:", address(pool));
        console2.log("owner:", deployer);
        console2.log("supervisor:", deployer);
        console2.log("maintainer:", address(0));
        console2.log("baseToken:", baseToken);
        console2.log("quoteToken:", quoteToken);
        console2.log("quoteMintAmount:", quoteMintAmount);
        console2.log("initialValuationPrice:", initialValuationPrice);
        console2.log("lpFeeRate:", LP_FEE_RATE);
        console2.log("maintainerFeeRate:", MAINTAINER_FEE_RATE);
        console2.log("k:", DEFAULT_K);
        console2.log("maxK:", pool.maxK());
        console2.log("kGrowthPerSecond:", pool.kGrowthPerSecond());
    }
}
