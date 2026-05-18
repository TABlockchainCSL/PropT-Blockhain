// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import "../../contracts/core/KYCRegistry.sol";
import "../../contracts/core/PropertyRegistry.sol";
import "../../contracts/core/PropertyToken.sol";
import "../../contracts/core/PropertyTokenFactory.sol";
import "../../contracts/interfaces/IPropertyTokenFactory.sol";
import "../../contracts/interfaces/IPropertyRegistry.sol";

/// @title TokenizationIntegrationTest
/// @notice End-to-end integration tests for the tokenization lifecycle:
///         full flow, multi-token isolation, full lifecycle with upgrade.
contract TokenizationIntegrationTest is Test {
    address internal owner;
    address internal user1;
    address internal user2;
    address internal user3;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyTokenFactory internal factory;
    UpgradeableBeacon internal beacon;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy =
            new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        kycRegistry = KYCRegistry(address(kycProxy));

        PropertyRegistry regImpl = new PropertyRegistry();
        ERC1967Proxy regProxy =
            new ERC1967Proxy(address(regImpl), abi.encodeCall(PropertyRegistry.initialize, ()));
        propertyRegistry = PropertyRegistry(address(regProxy));

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

    /**
     * @notice Verifies the complete end-to-end tokenization flow.
     * Includes KYC, creation, distribution, transfers, and metadata updates.
     */

    function test_E2E_fullTokenizationFlow() public {
        // 1. KYC onboarding
        kycRegistry.addUser(owner);
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);

        // 2. Create token via factory
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "RealToken - Apartemen Sudirman Park Unit A",
                symbol: "RTASPA",
                totalSupply: 1000 ether,
                propertyName: "Apartemen Sudirman Park Unit A",
                propertyAddress: "Jl. Jend. Sudirman No. 1, Jakarta Selatan",
                totalValue: 500 ether,
                ipfsDocumentURI: "ipfs://QmPropertyDocumentHash12345",
                tokenOwner: owner
            })
        );

        // 3. Verify property registration
        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(1);
        assertEq(prop.propertyName, "Apartemen Sudirman Park Unit A");
        assertEq(prop.ipfsDocumentURI, "ipfs://QmPropertyDocumentHash12345");
        assertTrue(prop.isActive);

        // 4. Get deployed token
        address tokenAddr = factory.getTokenByPropertyId(1);
        PropertyToken token = PropertyToken(tokenAddr);

        // 5. Distribute tokens to KYC-verified investors
        token.transfer(user1, 200 ether);
        token.transfer(user2, 300 ether);
        assertEq(token.balanceOf(user1), 200 ether);
        assertEq(token.balanceOf(user2), 300 ether);
        assertEq(token.balanceOf(owner), 500 ether);

        // 6. user1 → user2 transfer (both KYC verified)
        vm.prank(user1);
        token.transfer(user2, 50 ether);
        assertEq(token.balanceOf(user1), 150 ether);
        assertEq(token.balanceOf(user2), 350 ether);

        // 7. Unverified user3 cannot receive
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.RecipientNotAuthorized.selector, user3)
        );
        token.transfer(user3, 10 ether);

        // 8. Update IPFS metadata
        propertyRegistry.updateIPFSDocument(1, "ipfs://QmUpdatedDocWithNewPhotos");
        IPropertyRegistry.Property memory updatedProp = propertyRegistry.getProperty(1);
        assertEq(updatedProp.ipfsDocumentURI, "ipfs://QmUpdatedDocWithNewPhotos");
    }

    /**
     * @notice Verifies that multiple tokens can operate independently using the same KYC registry.
     */

    function test_Functional_multiTokenIndependentKYC() public {
        kycRegistry.addUser(owner);
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);

        // Token A
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Token A",
                symbol: "TKA",
                totalSupply: 1000 ether,
                propertyName: "Property A",
                propertyAddress: "Jl. A No. 1",
                totalValue: 100 ether,
                ipfsDocumentURI: "ipfs://A",
                tokenOwner: owner
            })
        );
        address tokenAAddr = factory.getTokenByPropertyId(1);
        PropertyToken tokenA = PropertyToken(tokenAAddr);

        // Token B
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Token B",
                symbol: "TKB",
                totalSupply: 500 ether,
                propertyName: "Property B",
                propertyAddress: "Jl. B No. 2",
                totalValue: 200 ether,
                ipfsDocumentURI: "ipfs://B",
                tokenOwner: owner
            })
        );
        address tokenBAddr = factory.getTokenByPropertyId(2);
        PropertyToken tokenB = PropertyToken(tokenBAddr);

        // Same KYC status valid for both tokens
        tokenA.transfer(user1, 50 ether);
        assertEq(tokenA.balanceOf(user1), 50 ether);

        tokenA.transfer(user2, 50 ether);
        tokenB.transfer(user2, 50 ether);
        assertEq(tokenA.balanceOf(user2), 50 ether);
        assertEq(tokenB.balanceOf(user2), 50 ether);

        // Separate propertyIds and supplies
        assertEq(tokenA.propertyId(), 1);
        assertEq(tokenB.propertyId(), 2);
        assertEq(factory.getDeployedTokenCount(), 2);
    }

    /**
     * @notice Tests the full lifecycle of a token: transfer, pause, unpause, and beacon upgrade.
     */

    function test_Functional_fullLifecycle() public {
        kycRegistry.addUser(owner);
        kycRegistry.addUser(user1);

        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Lifecycle Token",
                symbol: "LCT",
                totalSupply: 1000 ether,
                propertyName: "Lifecycle Property",
                propertyAddress: "Jl. Lifecycle No. 1",
                totalValue: 500 ether,
                ipfsDocumentURI: "ipfs://lifecycle",
                tokenOwner: owner
            })
        );
        address tokenAddr = factory.getTokenByPropertyId(1);
        PropertyToken token = PropertyToken(tokenAddr);

        // Transfer works
        token.transfer(user1, 100 ether);
        assertEq(token.balanceOf(user1), 100 ether);

        // Pause blocks transfers
        token.pause();
        vm.expectRevert();
        token.transfer(user1, 10 ether);

        // Unpause restores
        token.unpause();
        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 110 ether);

        // Beacon upgrade: state must survive
        PropertyToken tokenV2 = new PropertyToken();
        beacon.upgradeTo(address(tokenV2));

        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 120 ether);
        assertEq(token.name(), "Lifecycle Token");
        assertEq(token.propertyId(), 1);
        assertEq(token.totalSupply(), 1000 ether);
    }

    /**
     * @notice Verifies state preservation across contract upgrades for KYC and Property registries.
     */

    function test_Upgrade_KYCRegistry_preservesState() public {
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);

        KYCRegistry kycV2 = new KYCRegistry();
        kycRegistry.upgradeToAndCall(address(kycV2), "");

        assertTrue(kycRegistry.isVerified(user1));
        assertTrue(kycRegistry.isVerified(user2));
        assertEq(kycRegistry.getVerifiedUserCount(), 2);
    }

    function test_Upgrade_PropertyRegistry_preservesState() public {
        propertyRegistry.registerProperty(
            "Test Property", "Test Address", 100 ether, "ipfs://QmTest", user1
        );

        PropertyRegistry regV2 = new PropertyRegistry();
        propertyRegistry.upgradeToAndCall(address(regV2), "");

        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(1);
        assertEq(prop.propertyName, "Test Property");
        assertEq(prop.tokenAddress, user1);
        assertEq(propertyRegistry.getPropertyCount(), 1);
    }
}
