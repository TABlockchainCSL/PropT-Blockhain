// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../contracts/core/PropertyRegistry.sol";
import "../../contracts/interfaces/IPropertyRegistry.sol";

/// @title PropertyRegistryTest
/// @notice Unit tests for PropertyRegistry: happy path, negative path, edge case,
///         upgradeability, and access-control security tests.
contract PropertyRegistryTest is Test {
    address internal owner;
    address internal attacker;
    address internal user1;
    address internal user2;

    PropertyRegistry internal propertyRegistry;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        PropertyRegistry regImpl = new PropertyRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(PropertyRegistry.initialize, ())
        );
        propertyRegistry = PropertyRegistry(address(regProxy));
    }

    /**
     * @notice registerProperty — happy path
     */

    function test_Registry_registerProperty() public {
        vm.expectEmit(true, true, false, true);
        emit IPropertyRegistry.PropertyRegistered(
            1,
            "Apartemen Sudirman Park",
            user1,
            "ipfs://QmExampleHash123456789"
        );
        propertyRegistry.registerProperty(
            "Apartemen Sudirman Park",
            "Jl. Jend. Sudirman No. 1, Jakarta",
            100 ether,
            "ipfs://QmExampleHash123456789",
            user1
        );

        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            1
        );
        assertEq(prop.propertyName, "Apartemen Sudirman Park");
        assertEq(prop.propertyAddress, "Jl. Jend. Sudirman No. 1, Jakarta");
        assertEq(prop.totalValue, 100 ether);
        assertEq(prop.ipfsDocumentURI, "ipfs://QmExampleHash123456789");
        assertEq(prop.tokenAddress, user1);
        assertTrue(prop.isActive);
    }

    function test_Registry_incrementPropertyCount() public {
        propertyRegistry.registerProperty(
            "Apartemen 1",
            "Jl. A",
            100 ether,
            "ipfs://QmHash1",
            user1
        );
        propertyRegistry.registerProperty(
            "Apartemen 2",
            "Jl. Thamrin",
            50 ether,
            "ipfs://QmSecondHash",
            user2
        );
        assertEq(propertyRegistry.getPropertyCount(), 2);
    }

    function test_Registry_getAllPropertyIds() public {
        propertyRegistry.registerProperty(
            "P1",
            "A",
            1 ether,
            "ipfs://x",
            user1
        );
        propertyRegistry.registerProperty(
            "P2",
            "B",
            2 ether,
            "ipfs://y",
            user2
        );
        uint256[] memory ids = propertyRegistry.getAllPropertyIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    /**
     * @notice registerProperty — negative path
     */

    function test_Registry_revertEmptyName() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.EmptyString.selector,
                "propertyName"
            )
        );
        propertyRegistry.registerProperty(
            "",
            "Jl. A",
            100 ether,
            "ipfs://Qm",
            user1
        );
    }

    function test_Registry_revertEmptyAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.EmptyString.selector,
                "propertyAddress"
            )
        );
        propertyRegistry.registerProperty(
            "Name",
            "",
            100 ether,
            "ipfs://x",
            user1
        );
    }

    function test_Registry_revertEmptyIPFS() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.EmptyString.selector,
                "ipfsDocumentURI"
            )
        );
        propertyRegistry.registerProperty("Name", "Addr", 100 ether, "", user1);
    }

    function test_Registry_revertZeroTokenAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(IPropertyRegistry.ZeroAddress.selector)
        );
        propertyRegistry.registerProperty(
            "Prop",
            "Jl. A",
            100 ether,
            "ipfs://Qm",
            address(0)
        );
    }

    function test_Registry_revertZeroTotalValue() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.ZeroValue.selector,
                "totalValue"
            )
        );
        propertyRegistry.registerProperty("Name", "Addr", 0, "ipfs://x", user1);
    }

    function test_Registry_revertTokenAlreadyRegistered() public {
        propertyRegistry.registerProperty(
            "Prop 1",
            "Addr 1",
            100 ether,
            "ipfs://Qm1",
            user1
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.TokenAlreadyRegistered.selector,
                user1
            )
        );
        propertyRegistry.registerProperty(
            "Prop 2",
            "Addr 2",
            50 ether,
            "ipfs://Qm2",
            user1
        );
    }

    function test_Registry_revertNonAdminRegister() public {
        vm.prank(user1);
        vm.expectRevert();
        propertyRegistry.registerProperty(
            "Name",
            "Addr",
            1 ether,
            "ipfs://x",
            user2
        );
    }

    /**
     * @notice getProperty — edge cases
     */

    function test_Registry_revertGetPropertyNotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.PropertyNotFound.selector,
                999
            )
        );
        propertyRegistry.getProperty(999);
    }

    function test_Registry_getByToken() public {
        propertyRegistry.registerProperty(
            "Prop",
            "Addr",
            100 ether,
            "ipfs://Qm",
            user1
        );
        IPropertyRegistry.Property memory prop = propertyRegistry
            .getPropertyByToken(user1);
        assertEq(prop.propertyName, "Prop");
    }

    function test_Registry_getPropertyByToken_unknown() public {
        vm.expectRevert();
        propertyRegistry.getPropertyByToken(address(0xdead));
    }

    /**
     * @notice updateIPFSDocument — happy path + negative
     */

    function test_Registry_updateIPFS() public {
        propertyRegistry.registerProperty(
            "Prop",
            "Addr",
            100 ether,
            "ipfs://OldHash",
            user1
        );
        vm.expectEmit(true, false, false, true);
        emit IPropertyRegistry.IPFSDocumentUpdated(
            1,
            "ipfs://OldHash",
            "ipfs://QmNewHashUpdated"
        );
        propertyRegistry.updateIPFSDocument(1, "ipfs://QmNewHashUpdated");
        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            1
        );
        assertEq(prop.ipfsDocumentURI, "ipfs://QmNewHashUpdated");
    }

    function test_Registry_updateIPFS_revertNonExistent() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.PropertyNotFound.selector,
                999
            )
        );
        propertyRegistry.updateIPFSDocument(999, "ipfs://QmHash");
    }

    function test_Registry_updateIPFS_revertEmptyURI() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.EmptyString.selector,
                "ipfsDocumentURI"
            )
        );
        propertyRegistry.updateIPFSDocument(1, "");
    }

    /**
     * @notice updatePropertyName / updatePropertyValue
     */

    function test_Registry_updatePropertyName() public {
        propertyRegistry.registerProperty(
            "Old Name",
            "Addr",
            1 ether,
            "ipfs://x",
            user1
        );
        propertyRegistry.updatePropertyName(1, "New Name");
        IPropertyRegistry.Property memory p = propertyRegistry.getProperty(1);
        assertEq(p.propertyName, "New Name");
    }

    function test_Registry_updatePropertyName_revertEmpty() public {
        propertyRegistry.registerProperty(
            "Old",
            "Addr",
            1 ether,
            "ipfs://x",
            user1
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.EmptyString.selector,
                "propertyName"
            )
        );
        propertyRegistry.updatePropertyName(1, "");
    }

    function test_Registry_updatePropertyValue() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        propertyRegistry.updatePropertyValue(1, 99 ether);
        IPropertyRegistry.Property memory p = propertyRegistry.getProperty(1);
        assertEq(p.totalValue, 99 ether);
    }

    function test_Registry_updatePropertyValue_revertZero() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.ZeroValue.selector,
                "totalValue"
            )
        );
        propertyRegistry.updatePropertyValue(1, 0);
    }

    /**
     * @notice deactivate / reactivate
     */

    function test_Registry_deactivate() public {
        propertyRegistry.registerProperty(
            "Prop",
            "Addr",
            100 ether,
            "ipfs://Qm",
            user1
        );
        propertyRegistry.deactivateProperty(1);
        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            1
        );
        assertFalse(prop.isActive);
    }

    function test_Registry_reactivate() public {
        propertyRegistry.registerProperty(
            "Prop",
            "Addr",
            100 ether,
            "ipfs://Qm",
            user1
        );
        propertyRegistry.deactivateProperty(1);
        propertyRegistry.reactivateProperty(1);
        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            1
        );
        assertTrue(prop.isActive);
    }

    function test_Registry_revertUpdateDeactivated() public {
        propertyRegistry.registerProperty(
            "Prop",
            "Addr",
            100 ether,
            "ipfs://Qm",
            user1
        );
        propertyRegistry.deactivateProperty(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.PropertyNotActive.selector,
                1
            )
        );
        propertyRegistry.updateIPFSDocument(1, "ipfs://QmNew");
    }

    function test_Registry_revertDeactivateAlreadyInactive() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        propertyRegistry.deactivateProperty(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.PropertyNotActive.selector,
                1
            )
        );
        propertyRegistry.deactivateProperty(1);
    }

    function test_Registry_revertReactivateNotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPropertyRegistry.PropertyNotFound.selector,
                777
            )
        );
        propertyRegistry.reactivateProperty(777);
    }

    /**
     * @notice Upgradeability
     */

    function test_Registry_upgrade_preservesState() public {
        propertyRegistry.registerProperty(
            "Test Property",
            "Test Address",
            100 ether,
            "ipfs://QmTest",
            user1
        );

        PropertyRegistry regV2 = new PropertyRegistry();
        propertyRegistry.upgradeToAndCall(address(regV2), "");

        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            1
        );
        assertEq(prop.propertyName, "Test Property");
        assertEq(prop.tokenAddress, user1);
        assertEq(propertyRegistry.getPropertyCount(), 1);
    }

    function test_Registry_reInit_reverts() public {
        vm.expectRevert();
        propertyRegistry.initialize();
    }

    /**
     * @notice Security: ACL negative path
     */

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

    function test_ACL_attackerCannotDeactivateProperty() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        vm.prank(attacker);
        vm.expectRevert();
        propertyRegistry.deactivateProperty(1);
    }

    function test_ACL_revertNonAdminDeactivate() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        vm.prank(user1);
        vm.expectRevert();
        propertyRegistry.deactivateProperty(1);
    }

    function test_UpgradeHijack_attackerCannotUpgradePropertyRegistry() public {
        PropertyRegistry regV2 = new PropertyRegistry();
        vm.prank(attacker);
        vm.expectRevert();
        propertyRegistry.upgradeToAndCall(address(regV2), "");
    }
}
