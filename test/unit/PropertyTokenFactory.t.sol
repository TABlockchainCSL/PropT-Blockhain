// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "../../contracts/core/KYCRegistry.sol";
import "../../contracts/core/PropertyRegistry.sol";
import "../../contracts/core/PropertyToken.sol";
import "../../contracts/core/PropertyTokenFactory.sol";
import "../../contracts/interfaces/IPropertyTokenFactory.sol";

/// @title PropertyTokenFactoryTest
/// @notice Unit tests for PropertyTokenFactory: createPropertyToken, parameter
///         validation, multi-token, upgradeability, and security paths.
contract PropertyTokenFactoryTest is Test {
    address internal owner;
    address internal attacker;
    address internal user1;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyTokenFactory internal factory;
    UpgradeableBeacon internal beacon;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");

        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry = KYCRegistry(
            address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ())))
        );

        PropertyRegistry regImpl = new PropertyRegistry();
        propertyRegistry = PropertyRegistry(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(PropertyRegistry.initialize, ())))
        );

        PropertyToken tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), owner);

        PropertyTokenFactory factoryImpl = new PropertyTokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                PropertyTokenFactory.initialize,
                (address(kycRegistry), address(propertyRegistry), address(beacon))
            )
        );
        factory = PropertyTokenFactory(address(factoryProxy));

        bytes32 REGISTRY_ADMIN_ROLE = propertyRegistry.REGISTRY_ADMIN_ROLE();
        propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, address(factory));
    }

    // --- Helpers ---

    function _defaultParams() internal view returns (IPropertyTokenFactory.CreateTokenParams memory) {
        return IPropertyTokenFactory.CreateTokenParams({
            name: "RealToken - Apartemen Sudirman",
            symbol: "RTAPS",
            totalSupply: 1000 ether,
            propertyName: "Apartemen Sudirman Park",
            propertyAddress: "Jl. Jend. Sudirman No. 1, Jakarta",
            totalValue: 100 ether,
            ipfsDocumentURI: "ipfs://QmExamplePropertyDocHash",
            tokenOwner: owner
        });
    }

    // =========================================================================
    //  createPropertyToken — happy path
    // =========================================================================

    function test_Factory_createAndRegister() public {
        factory.createPropertyToken(_defaultParams());

        address[] memory tokens = factory.getDeployedTokens();
        assertEq(tokens.length, 1);

        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(1);
        assertEq(prop.propertyName, "Apartemen Sudirman Park");
        assertEq(prop.tokenAddress, tokens[0]);
        assertEq(prop.ipfsDocumentURI, "ipfs://QmExamplePropertyDocHash");
    }

    function test_Factory_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IPropertyTokenFactory.PropertyTokenCreated(1, address(0), "", "", 0);
        factory.createPropertyToken(_defaultParams());
    }

    function test_Factory_multipleTokens() public {
        IPropertyTokenFactory.CreateTokenParams memory p1 = _defaultParams();
        p1.name = "Token A";
        p1.symbol = "TKA";
        p1.propertyName = "Property A";
        p1.propertyAddress = "Address A";
        p1.ipfsDocumentURI = "ipfs://QmHashA";
        factory.createPropertyToken(p1);

        IPropertyTokenFactory.CreateTokenParams memory p2 = _defaultParams();
        p2.name = "Token B";
        p2.symbol = "TKB";
        p2.totalSupply = 2000 ether;
        p2.propertyName = "Property B";
        p2.propertyAddress = "Address B";
        p2.totalValue = 200 ether;
        p2.ipfsDocumentURI = "ipfs://QmHashB";
        factory.createPropertyToken(p2);

        assertEq(factory.getDeployedTokenCount(), 2);
        assertEq(propertyRegistry.getPropertyCount(), 2);
    }

    function test_Factory_mintsToOwner() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.name = "Token C";
        p.symbol = "TKC";
        p.propertyName = "Property C";
        p.propertyAddress = "Address C";
        p.ipfsDocumentURI = "ipfs://QmHashC";
        factory.createPropertyToken(p);

        address tokenAddr = factory.getTokenByPropertyId(1);
        PropertyToken token = PropertyToken(tokenAddr);
        assertEq(token.balanceOf(owner), 1000 ether);
    }

    function test_Factory_getTokenByPropertyId() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.name = "Token D";
        p.symbol = "TKD";
        p.propertyName = "Property D";
        p.propertyAddress = "Address D";
        p.ipfsDocumentURI = "ipfs://QmHashD";
        factory.createPropertyToken(p);
        address tokenAddr = factory.getTokenByPropertyId(1);
        assertTrue(tokenAddr != address(0));
    }

    function test_Factory_returnsZeroForNonexistent() public {
        address tokenAddr = factory.getTokenByPropertyId(999);
        assertEq(tokenAddr, address(0));
    }

    // =========================================================================
    //  createPropertyToken — negative path (parameter validation)
    // =========================================================================

    function test_Factory_revertEmptyName() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.name = "";
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "name"));
        factory.createPropertyToken(p);
    }

    function test_Factory_revertEmptySymbol() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.symbol = "";
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "symbol"));
        factory.createPropertyToken(p);
    }

    function test_Factory_revertEmptyPropertyName() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.propertyName = "";
        vm.expectRevert(
            abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "propertyName")
        );
        factory.createPropertyToken(p);
    }

    function test_Factory_revertEmptyPropertyAddress() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.propertyAddress = "";
        vm.expectRevert(
            abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "propertyAddress")
        );
        factory.createPropertyToken(p);
    }

    function test_Factory_revertEmptyIPFS() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.ipfsDocumentURI = "";
        vm.expectRevert(
            abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "ipfsDocumentURI")
        );
        factory.createPropertyToken(p);
    }

    function test_Factory_revertZeroSupply() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.totalSupply = 0;
        vm.expectRevert(
            abi.encodeWithSelector(PropertyTokenFactory.ZeroValue.selector, "totalSupply")
        );
        factory.createPropertyToken(p);
    }

    function test_Factory_revertZeroValue() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.totalValue = 0;
        vm.expectRevert(
            abi.encodeWithSelector(PropertyTokenFactory.ZeroValue.selector, "totalValue")
        );
        factory.createPropertyToken(p);
    }

    function test_Factory_revertZeroTokenOwner() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.tokenOwner = address(0);
        vm.expectRevert();
        factory.createPropertyToken(p);
    }

    // =========================================================================
    //  initialize — zero-address guards (edge case)
    // =========================================================================

    function test_Factory_initialize_revertZeroKYC() public {
        PropertyTokenFactory factImpl = new PropertyTokenFactory();
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.ZeroAddress.selector));
        new ERC1967Proxy(
            address(factImpl),
            abi.encodeCall(
                PropertyTokenFactory.initialize, (address(0), address(propertyRegistry), address(beacon))
            )
        );
    }

    function test_Factory_initialize_revertZeroRegistry() public {
        PropertyTokenFactory factImpl = new PropertyTokenFactory();
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.ZeroAddress.selector));
        new ERC1967Proxy(
            address(factImpl),
            abi.encodeCall(
                PropertyTokenFactory.initialize, (address(kycRegistry), address(0), address(beacon))
            )
        );
    }

    function test_Factory_initialize_revertZeroBeacon() public {
        PropertyTokenFactory factImpl = new PropertyTokenFactory();
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.ZeroAddress.selector));
        new ERC1967Proxy(
            address(factImpl),
            abi.encodeCall(
                PropertyTokenFactory.initialize,
                (address(kycRegistry), address(propertyRegistry), address(0))
            )
        );
    }

    // =========================================================================
    //  Upgradeability
    // =========================================================================

    function test_Factory_upgrade_revertNonOwner() public {
        PropertyTokenFactory factoryV2 = new PropertyTokenFactory();
        vm.prank(user1);
        vm.expectRevert();
        factory.upgradeToAndCall(address(factoryV2), "");
    }

    function test_Factory_reInit_reverts() public {
        vm.expectRevert();
        factory.initialize(address(kycRegistry), address(propertyRegistry), address(beacon));
    }

    // =========================================================================
    //  Security: ACL negative path
    // =========================================================================

    function test_Factory_revertNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.createPropertyToken(_defaultParams());
    }

    function test_ACL_attackerCannotCreateToken() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.createPropertyToken(_defaultParams());
    }

    function test_UpgradeHijack_attackerCannotUpgradeFactory() public {
        PropertyTokenFactory factoryV2 = new PropertyTokenFactory();
        vm.prank(attacker);
        vm.expectRevert();
        factory.upgradeToAndCall(address(factoryV2), "");
    }
}

/// @title FactoryAccessControlTest
/// @notice RBAC tests: operator can create, attacker cannot, operator cannot upgrade.
contract FactoryAccessControlTest is Test {
    address internal admin;
    address internal operator;
    address internal attacker;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyTokenFactory internal factory;
    UpgradeableBeacon internal beacon;

    function setUp() public {
        admin = address(this);
        operator = makeAddr("operator");
        attacker = makeAddr("attacker");

        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy =
            new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        kycRegistry = KYCRegistry(address(kycProxy));

        PropertyRegistry regImpl = new PropertyRegistry();
        ERC1967Proxy regProxy =
            new ERC1967Proxy(address(regImpl), abi.encodeCall(PropertyRegistry.initialize, ()));
        propertyRegistry = PropertyRegistry(address(regProxy));

        PropertyToken tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), admin);

        PropertyTokenFactory factoryImpl = new PropertyTokenFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                PropertyTokenFactory.initialize,
                (address(kycRegistry), address(propertyRegistry), address(beacon))
            )
        );
        factory = PropertyTokenFactory(address(factoryProxy));

        propertyRegistry.grantRole(propertyRegistry.REGISTRY_ADMIN_ROLE(), address(factory));

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
