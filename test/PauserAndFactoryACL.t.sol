// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import "../contracts/core/KYCRegistry.sol";
import "../contracts/core/PropertyRegistry.sol";
import "../contracts/core/PropertyToken.sol";
import "../contracts/core/PropertyTokenFactory.sol";
import "../contracts/interfaces/IPropertyTokenFactory.sol";

/// @title PauserTest
/// @notice Tests for the pauser mechanism: setPauser, pause by pauser,
///         only owner can unpause, attacker still blocked.
contract PauserTest is Test {
    address owner;
    address pauser;
    address attacker;
    address user1;

    KYCRegistry kycRegistry;
    PropertyToken token;

    function setUp() public {
        owner = address(this);
        pauser = makeAddr("pauser");
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");

        // Deploy KYCRegistry
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        kycRegistry = KYCRegistry(address(kycProxy));

        // Deploy PropertyToken via beacon
        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), owner);
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(PropertyToken.initialize, ("Test Token", "TST", 1000 ether, 1, address(kycRegistry), owner))
        );
        token = PropertyToken(address(proxy));

        // KYC users
        kycRegistry.addUser(owner);
        kycRegistry.addUser(user1);

        // Set pauser
        token.setPauser(pauser);
    }

    function test_Pauser_canPause() public {
        vm.prank(pauser);
        token.pause();
        assertTrue(token.paused());
    }

    function test_Pauser_ownerCanStillPause() public {
        token.pause();
        assertTrue(token.paused());
    }

    function test_Pauser_attackerCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.NotPauserOrOwner.selector, attacker));
        token.pause();
    }

    function test_Pauser_cannotUnpause() public {
        token.pause();
        vm.prank(pauser);
        vm.expectRevert();
        token.unpause();
    }

    function test_Pauser_ownerCanUnpause() public {
        vm.prank(pauser);
        token.pause();
        token.unpause();
        assertFalse(token.paused());
    }

    function test_Pauser_onlyOwnerCanSetPauser() public {
        vm.prank(attacker);
        vm.expectRevert();
        token.setPauser(attacker);
    }

    function test_Pauser_setPauserEmitsEvent() public {
        address newPauser = makeAddr("newPauser");
        vm.expectEmit(true, true, false, true);
        emit PropertyToken.PauserUpdated(pauser, newPauser);
        token.setPauser(newPauser);
    }

    function test_Pauser_blocksTransferWhenPaused() public {
        vm.prank(pauser);
        token.pause();

        vm.expectRevert();
        token.transfer(user1, 10 ether);
    }

    function test_Pauser_resumeAfterUnpause() public {
        vm.prank(pauser);
        token.pause();
        token.unpause();

        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 10 ether);
    }
}

/// @title FactoryAccessControlTest
/// @notice Tests for Factory RBAC: operator can create tokens,
///         non-operator cannot, operator cannot upgrade.
contract FactoryAccessControlTest is Test {
    address admin;
    address operator;
    address attacker;

    KYCRegistry kycRegistry;
    PropertyRegistry propertyRegistry;
    PropertyTokenFactory factory;
    UpgradeableBeacon beacon;

    function setUp() public {
        admin = address(this);
        operator = makeAddr("operator");
        attacker = makeAddr("attacker");

        // Deploy KYCRegistry
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        kycRegistry = KYCRegistry(address(kycProxy));

        // Deploy PropertyRegistry
        PropertyRegistry regImpl = new PropertyRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), abi.encodeCall(PropertyRegistry.initialize, ()));
        propertyRegistry = PropertyRegistry(address(regProxy));

        // Deploy beacon
        PropertyToken tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), admin);

        // Deploy factory
        PropertyTokenFactory factoryImpl = new PropertyTokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                PropertyTokenFactory.initialize, (address(kycRegistry), address(propertyRegistry), address(beacon))
            )
        );
        factory = PropertyTokenFactory(address(factoryProxy));

        // Grant REGISTRY_ADMIN to factory
        propertyRegistry.grantRole(propertyRegistry.REGISTRY_ADMIN_ROLE(), address(factory));

        // Grant OPERATOR_ROLE to operator, revoke from admin
        factory.grantRole(factory.OPERATOR_ROLE(), operator);
        factory.renounceRole(factory.OPERATOR_ROLE(), admin);
    }

    function test_FactoryACL_operatorCanCreate() public {
        vm.prank(operator);
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Test",
                symbol: "TST",
                totalSupply: 1000 ether,
                propertyName: "Property",
                propertyAddress: "Jl. Test No. 1",
                totalValue: 100 ether,
                ipfsDocumentURI: "ipfs://test",
                tokenOwner: admin
            })
        );
        assertEq(factory.getDeployedTokenCount(), 1);
    }

    function test_FactoryACL_attackerCannotCreate() public {
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
                tokenOwner: attacker
            })
        );
    }

    function test_FactoryACL_operatorCannotUpgrade() public {
        PropertyTokenFactory factoryV2 = new PropertyTokenFactory();
        vm.prank(operator);
        vm.expectRevert();
        factory.upgradeToAndCall(address(factoryV2), "");
    }

    function test_FactoryACL_adminCanUpgrade() public {
        PropertyTokenFactory factoryV2 = new PropertyTokenFactory();
        factory.upgradeToAndCall(address(factoryV2), "");
    }

    function test_FactoryACL_tokenOwnerIsCorrect() public {
        vm.prank(operator);
        (address tokenAddr,) = factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Owner Test",
                symbol: "OT",
                totalSupply: 500 ether,
                propertyName: "Owner Property",
                propertyAddress: "Jl. Owner No. 1",
                totalValue: 50 ether,
                ipfsDocumentURI: "ipfs://owner",
                tokenOwner: admin
            })
        );
        PropertyToken token = PropertyToken(tokenAddr);
        assertEq(token.owner(), admin);
    }
}
