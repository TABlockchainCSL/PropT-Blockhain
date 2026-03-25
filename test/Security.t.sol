// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../contracts/core/KYCRegistry.sol";
import "../contracts/core/PropertyRegistry.sol";
import "../contracts/core/PropertyToken.sol";
import "../contracts/core/PropertyTokenFactory.sol";
import "../contracts/governance/MultiSigWallet.sol";
import "../contracts/interfaces/IPropertyTokenFactory.sol";

/// @title SecurityTest
/// @notice Security tests: access control, KYC bypass, upgrade hijack,
///         re-initialization, storage collision, pause, multisig, and timelock.
contract SecurityTest is Test {
    address owner;
    address admin;
    address attacker;
    address user1;

    KYCRegistry kycRegistry;
    PropertyRegistry propertyRegistry;
    PropertyTokenFactory factory;
    PropertyToken token;
    UpgradeableBeacon beacon;

    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");

        // Deploy KYCRegistry via UUPS proxy
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(
            address(kycImpl),
            abi.encodeCall(KYCRegistry.initialize, ())
        );
        kycRegistry = KYCRegistry(address(kycProxy));

        // Deploy PropertyRegistry via UUPS proxy
        PropertyRegistry regImpl = new PropertyRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(PropertyRegistry.initialize, ())
        );
        propertyRegistry = PropertyRegistry(address(regProxy));

        // Deploy PropertyToken beacon
        PropertyToken tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), owner);

        // Deploy PropertyTokenFactory via UUPS proxy
        PropertyTokenFactory factoryImpl = new PropertyTokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                PropertyTokenFactory.initialize,
                (
                    address(kycRegistry),
                    address(propertyRegistry),
                    address(beacon)
                )
            )
        );
        factory = PropertyTokenFactory(address(factoryProxy));

        // Grant roles
        bytes32 REGISTRY_ADMIN_ROLE = propertyRegistry.REGISTRY_ADMIN_ROLE();
        propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, address(factory));

        bytes32 KYC_ADMIN_ROLE = kycRegistry.KYC_ADMIN_ROLE();
        kycRegistry.grantRole(KYC_ADMIN_ROLE, admin);

        // KYC users
        vm.prank(admin);
        kycRegistry.addUser(owner, 2);
        vm.prank(admin);
        kycRegistry.addUser(user1, 1);

        // Create a token
        (address tokenAddress, ) = factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Test Token",
                symbol: "TST",
                totalSupply: 1000 ether,
                propertyName: "Test Property",
                propertyAddress: "Jl. Test No. 1",
                totalValue: 100 ether,
                ipfsDocumentURI: "ipfs://test",
                requiredKYCLevel: 1
            })
        );
        token = PropertyToken(tokenAddress);
    }

    function test_ACL_attackerCannotAddKYC() public {
        vm.prank(attacker);
        vm.expectRevert();
        kycRegistry.addUser(attacker, 1);
    }

    function test_ACL_attackerCannotBatchAddKYC() public {
        address[] memory users = new address[](1);
        users[0] = attacker;
        uint8[] memory levels = new uint8[](1);
        levels[0] = 1;

        vm.prank(attacker);
        vm.expectRevert();
        kycRegistry.batchAddUsers(users, levels);
    }

    function test_ACL_attackerCannotRemoveKYC() public {
        vm.prank(attacker);
        vm.expectRevert();
        kycRegistry.removeUser(user1);
    }

    function test_ACL_attackerCannotRegisterProperty() public {
        vm.prank(attacker);
        vm.expectRevert();
        propertyRegistry.registerProperty(
            "Fake",
            "Jl. Fake",
            1 ether,
            "ipfs://fake",
            attacker
        );
    }

    function test_ACL_attackerCannotCreateToken() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Fake",
                symbol: "FAKE",
                totalSupply: 100 ether,
                propertyName: "Fake Property",
                propertyAddress: "Jl. Fake No. 1",
                totalValue: 10 ether,
                ipfsDocumentURI: "ipfs://fake",
                requiredKYCLevel: 1
            })
        );
    }

    function test_ACL_attackerCannotMint() public {
        vm.prank(attacker);
        vm.expectRevert();
        token.mint(attacker, 1000 ether);
    }

    function test_ACL_attackerCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        token.pause();
    }

    function test_ACL_attackerCannotUnpause() public {
        token.pause();
        vm.prank(attacker);
        vm.expectRevert();
        token.unpause();
    }

    function test_ACL_attackerCannotGrantAdminRole() public {
        bytes32 DEFAULT_ADMIN_ROLE = kycRegistry.DEFAULT_ADMIN_ROLE();
        vm.prank(attacker);
        vm.expectRevert();
        kycRegistry.grantRole(DEFAULT_ADMIN_ROLE, attacker);
    }

    function test_ACL_attackerCannotDeactivateProperty() public {
        vm.prank(attacker);
        vm.expectRevert();
        propertyRegistry.deactivateProperty(1);
    }

    function test_KYCBypass_nonKYCCannotReceive() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.RecipientNotKYCVerified.selector,
                attacker
            )
        );
        token.transfer(attacker, 10 ether);
    }

    function test_KYCBypass_revokedSenderCannotTransfer() public {
        token.transfer(user1, 10 ether);
        vm.prank(admin);
        kycRegistry.removeUser(user1);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.SenderNotKYCVerified.selector,
                user1
            )
        );
        token.transfer(owner, 5 ether);
    }

    function test_KYCBypass_level2RejectsLevel1() public {
        (address premiumAddr, ) = factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Premium Token",
                symbol: "PREM",
                totalSupply: 500 ether,
                propertyName: "Premium Property",
                propertyAddress: "Jl. Premium No. 1",
                totalValue: 200 ether,
                ipfsDocumentURI: "ipfs://premium",
                requiredKYCLevel: 2
            })
        );
        PropertyToken premiumToken = PropertyToken(premiumAddr);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.InsufficientKYCLevel.selector,
                user1,
                2,
                1
            )
        );
        premiumToken.transfer(user1, 10 ether);
    }

    function test_UpgradeHijack_attackerCannotUpgradeKYCRegistry() public {
        KYCRegistry kycV2 = new KYCRegistry();
        vm.prank(attacker);
        vm.expectRevert();
        kycRegistry.upgradeToAndCall(address(kycV2), "");
    }

    function test_UpgradeHijack_attackerCannotUpgradePropertyRegistry() public {
        PropertyRegistry regV2 = new PropertyRegistry();
        vm.prank(attacker);
        vm.expectRevert();
        propertyRegistry.upgradeToAndCall(address(regV2), "");
    }

    function test_UpgradeHijack_attackerCannotUpgradeFactory() public {
        PropertyTokenFactory factoryV2 = new PropertyTokenFactory();
        vm.prank(attacker);
        vm.expectRevert();
        factory.upgradeToAndCall(address(factoryV2), "");
    }

    function test_UpgradeHijack_attackerCannotUpgradeBeacon() public {
        PropertyToken fakeImpl = new PropertyToken();
        vm.prank(attacker);
        vm.expectRevert();
        beacon.upgradeTo(address(fakeImpl));
    }

    function test_ReInit_KYCRegistry() public {
        vm.expectRevert();
        kycRegistry.initialize();
    }

    function test_ReInit_PropertyRegistry() public {
        vm.expectRevert();
        propertyRegistry.initialize();
    }

    function test_ReInit_PropertyTokenFactory() public {
        vm.expectRevert();
        factory.initialize(
            address(kycRegistry),
            address(propertyRegistry),
            address(beacon)
        );
    }

    function test_ReInit_PropertyToken() public {
        vm.expectRevert();
        token.initialize(
            "Hack",
            "HACK",
            100 ether,
            99,
            address(kycRegistry),
            1,
            attacker
        );
    }

    function test_StorageCollision_KYCRegistryPreservesData() public {
        uint256 userCount = kycRegistry.getVerifiedUserCount();
        bool isVerified = kycRegistry.isVerified(user1);

        KYCRegistry kycV2 = new KYCRegistry();
        kycRegistry.upgradeToAndCall(address(kycV2), "");

        assertEq(kycRegistry.getVerifiedUserCount(), userCount);
        assertEq(kycRegistry.isVerified(user1), isVerified);
    }

    function test_StorageCollision_PropertyRegistryPreservesData() public {
        uint256 count = propertyRegistry.getPropertyCount();

        PropertyRegistry regV2 = new PropertyRegistry();
        propertyRegistry.upgradeToAndCall(address(regV2), "");

        assertEq(propertyRegistry.getPropertyCount(), count);
    }

    function test_EmergencyPause_blocksTransfers() public {
        token.pause();
        vm.expectRevert();
        token.transfer(user1, 10 ether);
    }

    function test_EmergencyPause_blocksMinting() public {
        token.pause();
        vm.expectRevert();
        token.mint(owner, 100 ether);
    }

    function test_EmergencyPause_unpauseRestores() public {
        token.pause();
        token.unpause();

        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 10 ether);
    }

    function test_MultiSigSecurity() public {
        address[] memory msOwners = new address[](3);
        msOwners[0] = owner;
        msOwners[1] = admin;
        msOwners[2] = user1;
        MultiSigWallet ms = new MultiSigWallet(msOwners, 2);

        // non-owner cannot submit
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.NotOwner.selector)
        );
        ms.submitTransaction(attacker, 0, "");

        // non-owner cannot confirm
        ms.submitTransaction(owner, 0, "");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.NotOwner.selector)
        );
        ms.confirmTransaction(0);

        // cannot execute below threshold
        ms.confirmTransaction(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSigWallet.InsufficientConfirmations.selector,
                1,
                2
            )
        );
        ms.executeTransaction(0);

        // cannot directly call owner management
        vm.expectRevert("Must call via multisig tx");
        ms.addOwner(attacker);

        vm.expectRevert("Must call via multisig tx");
        ms.removeOwner(owner);

        vm.expectRevert("Must call via multisig tx");
        ms.changeThreshold(1);
    }

    function test_TimelockSecurity_attackerCannotSchedule() public {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;
        TimelockController timelock = new TimelockController(
            3600,
            proposers,
            executors,
            address(0)
        );

        vm.prank(attacker);
        vm.expectRevert();
        timelock.schedule(attacker, 0, "", bytes32(0), keccak256("hack"), 3600);
    }

    function test_TimelockSecurity_attackerCannotExecute() public {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;
        TimelockController timelock = new TimelockController(
            3600,
            proposers,
            executors,
            address(0)
        );

        bytes memory calldata_ = abi.encodeCall(
            KYCRegistry.addUser,
            (attacker, 1)
        );
        bytes32 salt = keccak256("test");
        timelock.schedule(
            address(kycRegistry),
            0,
            calldata_,
            bytes32(0),
            salt,
            3600
        );

        vm.prank(attacker);
        vm.expectRevert();
        timelock.execute(address(kycRegistry), 0, calldata_, bytes32(0), salt);
    }

    function test_TimelockSecurity_attackerCannotCancel() public {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;
        TimelockController timelock = new TimelockController(
            3600,
            proposers,
            executors,
            address(0)
        );

        bytes32 salt = keccak256("cancel-test");
        timelock.schedule(owner, 0, "", bytes32(0), salt, 3600);

        bytes32 opId = keccak256(
            abi.encode(owner, uint256(0), bytes(""), bytes32(0), salt)
        );

        vm.prank(attacker);
        vm.expectRevert();
        timelock.cancel(opId);
    }
}
