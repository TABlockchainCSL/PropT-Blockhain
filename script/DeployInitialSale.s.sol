// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {InitialSale} from "../src/sale/InitialSale.sol";
import {IPropertyToken} from "../src/interfaces/IPropertyToken.sol";
import {IKYCRegistry} from "../src/interfaces/IKYCRegistry.sol";

/// @notice Deploys InitialSale and registers it as an approved contract in the KYC registry.
/// @dev Two signers are used: the deployer broadcasts the deployment, the KYC operator
///      broadcasts addApprovedContract (deposit() reverts until the sale is approved).
contract DeployInitialSaleScript is Script {
    function run() external returns (InitialSale sale) {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 kycOperatorPk = vm.envUint("KYC_OPERATOR_PK");

        address propertyToken = vm.envAddress("SALE_PROPERTY_TOKEN");
        address paymentToken = vm.envAddress("SALE_PAYMENT_TOKEN");
        address treasury = vm.envAddress("SALE_TREASURY");
        address owner = vm.envAddress("SALE_OWNER");
        uint256 pricePerToken = vm.envUint("SALE_PRICE_PER_TOKEN");

        // The KYC registry is inferred from the property token (same as the InitialSale constructor).
        IKYCRegistry kyc = IPropertyToken(propertyToken).kycRegistry();
        require(address(kyc) != address(0), "kycRegistry is zero");

        // 1. Deploy the sale (deployer signs; owner is set via constructor arg).
        vm.startBroadcast(deployerPk);
        sale = new InitialSale(propertyToken, paymentToken, treasury, pricePerToken, owner);
        vm.stopBroadcast();

        // 2. Approve the sale contract in the KYC registry (KYC operator holds KYC_ADMIN_ROLE).
        vm.startBroadcast(kycOperatorPk);
        kyc.addApprovedContract(address(sale));
        vm.stopBroadcast();

        console2.log("InitialSale deployed at:", address(sale));
        console2.log("propertyToken:", propertyToken);
        console2.log("paymentToken:", paymentToken);
        console2.log("treasury:", treasury);
        console2.log("owner:", owner);
        console2.log("pricePerToken:", pricePerToken);
        console2.log("kycRegistry:", address(kyc));
        console2.log("approvedInKyc:", kyc.isApprovedContract(address(sale)));
        console2.log("saleActive:", sale.saleActive());
    }
}
