// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../contracts/core/KYCRegistry.sol";
import "../contracts/core/PropertyRegistry.sol";
import "../contracts/core/PropertyToken.sol";
import "../contracts/core/PropertyTokenFactory.sol";
import "../contracts/governance/MultiSigWallet.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPk);

        (
            KYCRegistry kycRegistry,
            PropertyRegistry propertyRegistry,
            UpgradeableBeacon beacon,
            PropertyTokenFactory factory
        ) = _deployCore(deployer);

        _deployGovernance(
            deployer,
            kycRegistry,
            propertyRegistry,
            beacon,
            factory
        );

        vm.stopBroadcast();
    }

    function _deployCore(
        address deployer
    )
        internal
        returns (
            KYCRegistry kycRegistry,
            PropertyRegistry propertyRegistry,
            UpgradeableBeacon beacon,
            PropertyTokenFactory factory
        )
    {
        kycRegistry = KYCRegistry(
            address(
                new ERC1967Proxy(
                    address(new KYCRegistry()),
                    abi.encodeCall(KYCRegistry.initialize, ())
                )
            )
        );
        console.log("KYCRegistry:", address(kycRegistry));

        propertyRegistry = PropertyRegistry(
            address(
                new ERC1967Proxy(
                    address(new PropertyRegistry()),
                    abi.encodeCall(PropertyRegistry.initialize, ())
                )
            )
        );
        console.log("PropertyRegistry:", address(propertyRegistry));

        beacon = new UpgradeableBeacon(address(new PropertyToken()), deployer);
        console.log("PropertyToken Beacon:", address(beacon));

        factory = PropertyTokenFactory(
            address(
                new ERC1967Proxy(
                    address(new PropertyTokenFactory()),
                    abi.encodeCall(
                        PropertyTokenFactory.initialize,
                        (
                            address(kycRegistry),
                            address(propertyRegistry),
                            address(beacon)
                        )
                    )
                )
            )
        );
        console.log("PropertyTokenFactory:", address(factory));

        propertyRegistry.grantRole(
            propertyRegistry.REGISTRY_ADMIN_ROLE(),
            address(factory)
        );
    }

    function _deployGovernance(
        address deployer,
        KYCRegistry kycRegistry,
        PropertyRegistry propertyRegistry,
        UpgradeableBeacon beacon,
        PropertyTokenFactory factory
    ) internal {
        address timelockAddr = _deployMultiSigTimelock();

        address kycOperator = vm.envAddress("KYC_OPERATOR_ADDRESS");
        address registryOperator = vm.envAddress("REGISTRY_OPERATOR_ADDRESS");
        address factoryOperator = vm.envAddress("FACTORY_OPERATOR_ADDRESS");

        _transferKYCRoles(kycRegistry, deployer, timelockAddr, kycOperator);
        _transferRegistryRoles(propertyRegistry, deployer, timelockAddr, registryOperator);
        _transferFactoryRoles(factory, deployer, timelockAddr, factoryOperator);
        beacon.transferOwnership(timelockAddr);

        console.log("\nGovernance roles transferred to TimelockController.");
        console.log("Operational roles granted to operator addresses.");
        console.log("Critical ops: MultiSig -> Timelock -> Contract");
        console.log("Daily ops: Operator -> Contract (no delay)");
    }

    function _deployMultiSigTimelock() internal returns (address) {
        address msOwner1 = vm.envAddress("MULTISIG_OWNER_1");
        address msOwner2 = vm.envAddress("MULTISIG_OWNER_2");
        address msOwner3 = vm.envAddress("MULTISIG_OWNER_3");
        uint256 msThreshold = vm.envUint("MULTISIG_THRESHOLD");

        address[] memory multisigOwners = new address[](3);
        multisigOwners[0] = msOwner1;
        multisigOwners[1] = msOwner2;
        multisigOwners[2] = msOwner3;
        MultiSigWallet multiSig = new MultiSigWallet(
            multisigOwners,
            msThreshold
        );
        console.log("MultiSigWallet:", address(multiSig));

        address[] memory proposers = new address[](1);
        proposers[0] = address(multiSig);
        address[] memory executors = new address[](1);
        executors[0] = address(multiSig);
        TimelockController timelock = new TimelockController(
            172800,
            proposers,
            executors,
            address(0)
        );
        console.log("TimelockController:", address(timelock));

        return address(timelock);
    }

    function _transferKYCRoles(
        KYCRegistry kycRegistry,
        address deployer,
        address timelock,
        address kycOperator
    ) internal {
        bytes32 adminRole = kycRegistry.DEFAULT_ADMIN_ROLE();
        bytes32 kycAdminRole = kycRegistry.KYC_ADMIN_ROLE();
        kycRegistry.grantRole(adminRole, timelock);
        kycRegistry.grantRole(kycAdminRole, kycOperator);
        kycRegistry.renounceRole(kycAdminRole, deployer);
        kycRegistry.renounceRole(adminRole, deployer);
    }

    function _transferRegistryRoles(
        PropertyRegistry propertyRegistry,
        address deployer,
        address timelock,
        address registryOperator
    ) internal {
        bytes32 adminRole = propertyRegistry.DEFAULT_ADMIN_ROLE();
        bytes32 regAdminRole = propertyRegistry.REGISTRY_ADMIN_ROLE();
        propertyRegistry.grantRole(adminRole, timelock);
        propertyRegistry.grantRole(regAdminRole, registryOperator);
        propertyRegistry.renounceRole(regAdminRole, deployer);
        propertyRegistry.renounceRole(adminRole, deployer);
    }

    function _transferFactoryRoles(
        PropertyTokenFactory factory,
        address deployer,
        address timelock,
        address factoryOperator
    ) internal {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes32 opRole = factory.OPERATOR_ROLE();
        factory.grantRole(adminRole, timelock);
        factory.grantRole(opRole, factoryOperator);
        factory.renounceRole(opRole, deployer);
        factory.renounceRole(adminRole, deployer);
    }
}
