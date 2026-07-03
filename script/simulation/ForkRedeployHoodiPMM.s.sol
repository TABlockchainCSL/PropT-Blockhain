// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";

interface IKYCRegistryAdmin {
    function addApprovedContract(address contractAddr) external;
}

/// @notice Deploys a fresh PMM against the existing Hoodi PDemo and tUSD
/// contracts, but only on a local Anvil fork. The 1:1 valuation aligns the
/// secondary guide price with the current InitialSale price of 1 tUSD/PDemo.
contract ForkRedeployHoodiPMM is Script {
    address private constant P_DEMO = 0x82C96966167940B21D5382258730b4668E0fB336;
    address private constant T_USD = 0x829aD27d87C5bf4e70f7C7D40eB17a25e74f824e;
    address private constant KYC_REGISTRY = 0xcF129c752C2957E98F57b670eab7fD68AB227BAA;
    address private constant DIVIDEND_DISTRIBUTOR = 0x45AA5173F5d66C82351f1F09384E940287A5F83B;

    uint256 private constant ONE = 1e18;
    uint256 private constant DEFAULT_BASE_LIQUIDITY = 200_000 * ONE;
    uint256 private constant DEFAULT_PRICE = 1 * ONE;
    uint256 private constant DEFAULT_LP_FEE = 5e15;
    uint256 private constant DEFAULT_K = 5e16;

    function run() external returns (PropertyPMM pool) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 holderKey = vm.envUint("INVESTOR_A_PK");
        uint256 kycOperatorKey = vm.envUint("KYC_OPERATOR_PK");
        address deployer = vm.addr(deployerKey);
        address holder = vm.addr(holderKey);
        address supervisor = vm.addr(kycOperatorKey);

        uint256 baseLiquidity = vm.envOr("FORK_BASE_LIQUIDITY", DEFAULT_BASE_LIQUIDITY);
        uint256 valuationPrice = vm.envOr("FORK_INITIAL_VALUATION_PRICE", DEFAULT_PRICE);
        uint256 lpFeeRate = vm.envOr("FORK_LP_FEE_RATE", DEFAULT_LP_FEE);
        uint256 k = vm.envOr("FORK_PMM_K", DEFAULT_K);
        uint256 quoteLiquidity = baseLiquidity * valuationPrice / ONE;

        vm.startBroadcast(deployerKey);
        pool = new PropertyPMM(
            deployer,
            supervisor,
            address(0),
            P_DEMO,
            T_USD,
            valuationPrice,
            lpFeeRate,
            0,
            k,
            DIVIDEND_DISTRIBUTOR
        );
        vm.stopBroadcast();

        vm.startBroadcast(kycOperatorKey);
        IKYCRegistryAdmin(KYC_REGISTRY).addApprovedContract(address(pool));
        vm.stopBroadcast();

        vm.startBroadcast(deployerKey);
        IERC20(T_USD).transfer(holder, quoteLiquidity);
        vm.stopBroadcast();

        vm.startBroadcast(holderKey);
        IERC20(P_DEMO).approve(address(pool), baseLiquidity);
        IERC20(T_USD).approve(address(pool), quoteLiquidity);
        pool.provideLiquidity(baseLiquidity, quoteLiquidity, 0);
        vm.stopBroadcast();

        vm.startBroadcast(deployerKey);
        pool.enableTrading();
        vm.stopBroadcast();

        console2.log("Fork-only PDemo PMM:", address(pool));
        console2.log("Base liquidity:", baseLiquidity / ONE);
        console2.log("Quote liquidity:", quoteLiquidity / ONE);
        console2.log("Guide valuation:", valuationPrice / ONE);
        console2.log("LP fee WAD:", lpFeeRate);
        console2.log("K WAD:", k);
    }
}
