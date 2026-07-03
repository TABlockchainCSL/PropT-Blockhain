// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";

interface IKYCRegistryAdmin {
    function addApprovedContract(address contractAddr) external;
}

/// @notice Deploys a dedicated Hoodi PMM for the token #20 daily-flow experiment.
contract DeployHoodiReplayPMM is Script {
    using SafeERC20 for IERC20;

    address private constant P_DEMO = 0x82C96966167940B21D5382258730b4668E0fB336;
    address private constant T_USD = 0x829aD27d87C5bf4e70f7C7D40eB17a25e74f824e;
    address private constant KYC_REGISTRY = 0xcF129c752C2957E98F57b670eab7fD68AB227BAA;
    address private constant DIVIDEND_DISTRIBUTOR = 0x45AA5173F5d66C82351f1F09384E940287A5F83B;

    uint256 private constant ONE = 1e18;
    uint256 private constant DEFAULT_BASE_LIQUIDITY = 200_000 * ONE;
    uint256 private constant DEFAULT_VALUATION = ONE;
    uint256 private constant DEFAULT_LP_FEE = 5e15;
    uint256 private constant DEFAULT_K = 5e16;
    uint256 private constant DEFAULT_TRADER_QUOTE_BUFFER = 50_000 * ONE;
    uint256 private constant DEFAULT_TRADER_ETH_FUNDING = 0.25 ether;

    function run() external returns (PropertyPMM pool) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 holderKey = vm.envUint("INVESTOR_A_PK");
        uint256 kycOperatorKey = vm.envUint("KYC_OPERATOR_PK");
        address deployer = vm.addr(deployerKey);
        address holder = vm.addr(holderKey);
        address supervisor = vm.addr(kycOperatorKey);

        uint256 baseLiquidity = vm.envOr("REPLAY_BASE_LIQUIDITY", DEFAULT_BASE_LIQUIDITY);
        uint256 valuation = vm.envOr("REPLAY_VALUATION", DEFAULT_VALUATION);
        uint256 lpFee = vm.envOr("REPLAY_LP_FEE", DEFAULT_LP_FEE);
        uint256 k = vm.envOr("REPLAY_K", DEFAULT_K);
        uint256 traderQuoteBuffer = vm.envOr("REPLAY_TRADER_QUOTE_BUFFER", DEFAULT_TRADER_QUOTE_BUFFER);
        uint256 traderEthFunding = vm.envOr("REPLAY_TRADER_ETH_FUNDING", DEFAULT_TRADER_ETH_FUNDING);
        uint256 quoteLiquidity = baseLiquidity * valuation / ONE;

        require(IERC20(P_DEMO).balanceOf(holder) >= baseLiquidity, "HOLDER_BASE_INSUFFICIENT");
        require(IERC20(T_USD).balanceOf(deployer) >= quoteLiquidity + traderQuoteBuffer, "DEPLOYER_QUOTE_INSUFFICIENT");
        require(deployer.balance >= traderEthFunding, "DEPLOYER_ETH_INSUFFICIENT");

        vm.startBroadcast(deployerKey);
        pool = new PropertyPMM(
            deployer,
            supervisor,
            address(0),
            P_DEMO,
            T_USD,
            valuation,
            lpFee,
            0,
            k,
            DIVIDEND_DISTRIBUTOR
        );
        vm.stopBroadcast();

        vm.startBroadcast(kycOperatorKey);
        IKYCRegistryAdmin(KYC_REGISTRY).addApprovedContract(address(pool));
        vm.stopBroadcast();

        vm.startBroadcast(deployerKey);
        (bool funded,) = payable(holder).call{value: traderEthFunding}("");
        require(funded, "TRADER_ETH_FUNDING_FAILED");
        IERC20(T_USD).safeTransfer(holder, quoteLiquidity + traderQuoteBuffer);
        vm.stopBroadcast();

        vm.startBroadcast(holderKey);
        IERC20(P_DEMO).forceApprove(address(pool), baseLiquidity);
        IERC20(T_USD).forceApprove(address(pool), quoteLiquidity);
        pool.provideLiquidity(baseLiquidity, quoteLiquidity, 0);
        vm.stopBroadcast();

        vm.startBroadcast(deployerKey);
        pool.enableTrading();
        vm.stopBroadcast();

    }
}
