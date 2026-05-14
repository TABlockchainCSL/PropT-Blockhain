// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {TestnetERC20} from "../../src/amm/testnet/TestnetERC20.sol";
import {TestnetPriceOracle} from "../../src/amm/testnet/TestnetPriceOracle.sol";

contract DeployTestnetAMMScript is Script {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant INITIAL_PRICE = 100 * ONE;
    uint256 internal constant INITIAL_BASE_LIQUIDITY = 10 * ONE;
    uint256 internal constant INITIAL_QUOTE_LIQUIDITY = 1000 * ONE;
    uint256 internal constant INITIAL_WALLET_BASE = 1000 * ONE;
    uint256 internal constant INITIAL_WALLET_QUOTE = 100_000 * ONE;
    uint256 internal constant LP_FEE_RATE = 5e15;
    uint256 internal constant MAINTAINER_FEE_RATE = 0;
    uint256 internal constant DEFAULT_K = 1e17;

    function run() external returns (MinimalDodoPMM pool) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);

        TestnetERC20 base = new TestnetERC20("PropT Test Property", "tPROP", 18);
        TestnetERC20 quote = new TestnetERC20("PropT Test Rupiah", "tIDR", 18);
        TestnetPriceOracle oracle = new TestnetPriceOracle(INITIAL_PRICE);

        pool = new MinimalDodoPMM(
            deployer,
            deployer,
            address(0),
            address(base),
            address(quote),
            address(oracle),
            LP_FEE_RATE,
            MAINTAINER_FEE_RATE,
            DEFAULT_K,
            "PropT AMM LP",
            "PAMM-LP"
        );

        base.mint(deployer, INITIAL_WALLET_BASE);
        quote.mint(deployer, INITIAL_WALLET_QUOTE);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        pool.provideLiquidity(INITIAL_BASE_LIQUIDITY, INITIAL_QUOTE_LIQUIDITY, 0);
        pool.enableTrading();

        vm.stopBroadcast();

        console2.log("networkChainId:", block.chainid);
        console2.log("deployer:", deployer);
        console2.log("pool:", address(pool));
        console2.log("base:", address(base));
        console2.log("quote:", address(quote));
        console2.log("oracle:", address(oracle));
        console2.log("initialPrice:", INITIAL_PRICE);
        console2.log("initialBaseLiquidity:", INITIAL_BASE_LIQUIDITY);
        console2.log("initialQuoteLiquidity:", INITIAL_QUOTE_LIQUIDITY);
    }
}
