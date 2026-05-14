// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MinimalDodoPMM} from "../src/amm/MinimalDodoPMM.sol";

contract DeployMinimalDodoPMMScript is Script {
    uint256 internal constant LP_FEE_RATE = 5e15;
    uint256 internal constant MAINTAINER_FEE_RATE = 0;
    uint256 internal constant DEFAULT_K = 1e17;
    string internal constant DEFAULT_SHARE_NAME = "PropT AMM LP";
    string internal constant DEFAULT_SHARE_SYMBOL = "PAMM-LP";

    function run() external returns (MinimalDodoPMM pool) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        address baseToken = vm.envAddress("BASE_TOKEN");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");
        address oracle = vm.envAddress("ORACLE");

        vm.startBroadcast(privateKey);

        pool = new MinimalDodoPMM(
            deployer,
            deployer,
            address(0),
            baseToken,
            quoteToken,
            oracle,
            LP_FEE_RATE,
            MAINTAINER_FEE_RATE,
            DEFAULT_K,
            DEFAULT_SHARE_NAME,
            DEFAULT_SHARE_SYMBOL
        );

        vm.stopBroadcast();

        console2.log("MinimalDodoPMM deployed at:", address(pool));
        console2.log("owner:", deployer);
        console2.log("supervisor:", deployer);
        console2.log("maintainer:", address(0));
        console2.log("baseToken:", baseToken);
        console2.log("quoteToken:", quoteToken);
        console2.log("oracle:", oracle);
        console2.log("lpFeeRate:", LP_FEE_RATE);
        console2.log("maintainerFeeRate:", MAINTAINER_FEE_RATE);
        console2.log("k:", DEFAULT_K);
        console2.log("maxK:", pool.maxK());
        console2.log("kGrowthPerSecond:", pool.kGrowthPerSecond());
    }
}
