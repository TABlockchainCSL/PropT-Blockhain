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
        address[] memory multisigOwners = new address[](1);
        multisigOwners[0] = deployer;
        MultiSigWallet multiSig = new MultiSigWallet(multisigOwners, 1);
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

        // Transfer admin roles ke timelock
        _transferRoles(
            deployer,
            kycRegistry,
            propertyRegistry,
            beacon,
            factory,
            address(timelock)
        );

        console.log("\nAll admin roles transferred to TimelockController.");
        console.log("Operations now require: MultiSig -> Timelock -> Contract");
    }

    function _transferRoles(
        address deployer,
        KYCRegistry kycRegistry,
        PropertyRegistry propertyRegistry,
        UpgradeableBeacon beacon,
        PropertyTokenFactory factory,
        address timelock
    ) internal {
        bytes32 DEFAULT_ADMIN_ROLE = kycRegistry.DEFAULT_ADMIN_ROLE();
        bytes32 KYC_ADMIN_ROLE = kycRegistry.KYC_ADMIN_ROLE();

        kycRegistry.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        kycRegistry.grantRole(KYC_ADMIN_ROLE, timelock);
        kycRegistry.renounceRole(KYC_ADMIN_ROLE, deployer);
        kycRegistry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);

        bytes32 REGISTRY_ADMIN_ROLE = propertyRegistry.REGISTRY_ADMIN_ROLE();
        propertyRegistry.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, timelock);
        propertyRegistry.renounceRole(REGISTRY_ADMIN_ROLE, deployer);
        propertyRegistry.renounceRole(DEFAULT_ADMIN_ROLE, deployer);

        factory.transferOwnership(timelock);
        beacon.transferOwnership(timelock);
    }
}
