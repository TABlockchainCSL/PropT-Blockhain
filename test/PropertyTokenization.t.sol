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

/// @title PropertyTokenizationTest
/// @notice Tests for core tokenization contracts: KYCRegistry, PropertyRegistry,
///         PropertyToken, PropertyTokenFactory, ERC20Votes, ERC20Permit, and upgrades.
contract PropertyTokenizationTest is Test {
    address owner;
    address admin;
    address user1;
    address user2;
    address user3;

    KYCRegistry kycRegistry;
    PropertyRegistry propertyRegistry;
    PropertyTokenFactory factory;
    UpgradeableBeacon beacon;

    uint8 constant KYC_LEVEL_BASIC = 1;
    uint8 constant KYC_LEVEL_ENHANCED = 2;

    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

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

        // Grant REGISTRY_ADMIN_ROLE to factory
        bytes32 REGISTRY_ADMIN_ROLE = propertyRegistry.REGISTRY_ADMIN_ROLE();
        propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, address(factory));
    }

    // --- KYCRegistry ---

    function test_KYC_addUser_basic() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        assertTrue(kycRegistry.isVerified(user1));
        assertEq(kycRegistry.getKYCLevel(user1), KYC_LEVEL_BASIC);
    }

    function test_KYC_addUser_enhanced() public {
        kycRegistry.addUser(user1, KYC_LEVEL_ENHANCED);
        assertTrue(kycRegistry.isVerified(user1));
        assertEq(kycRegistry.getKYCLevel(user1), KYC_LEVEL_ENHANCED);
    }

    function test_KYC_addUser_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IKYCRegistry.UserApproved(user1, KYC_LEVEL_BASIC, owner);
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
    }

    function test_KYC_addUser_revertAlreadyVerified() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        vm.expectRevert(
            abi.encodeWithSelector(
                IKYCRegistry.UserAlreadyVerified.selector,
                user1
            )
        );
        kycRegistry.addUser(user1, KYC_LEVEL_ENHANCED);
    }

    function test_KYC_addUser_revertLevelZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(IKYCRegistry.InvalidKYCLevel.selector, 0)
        );
        kycRegistry.addUser(user1, 0);
    }

    function test_KYC_addUser_revertLevelTooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(IKYCRegistry.InvalidKYCLevel.selector, 3)
        );
        kycRegistry.addUser(user1, 3);
    }

    function test_KYC_addUser_revertZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(IKYCRegistry.ZeroAddress.selector)
        );
        kycRegistry.addUser(address(0), KYC_LEVEL_BASIC);
    }

    function test_KYC_addUser_revertNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        kycRegistry.addUser(user2, KYC_LEVEL_BASIC);
    }

    function test_KYC_removeUser() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.removeUser(user1);
        assertFalse(kycRegistry.isVerified(user1));
        assertEq(kycRegistry.getKYCLevel(user1), 0);
    }

    function test_KYC_removeUser_emitsEvent() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        vm.expectEmit(true, true, false, true);
        emit IKYCRegistry.UserRemoved(user1, owner);
        kycRegistry.removeUser(user1);
    }

    function test_KYC_removeUser_revertNotVerified() public {
        vm.expectRevert(
            abi.encodeWithSelector(IKYCRegistry.UserNotVerified.selector, user2)
        );
        kycRegistry.removeUser(user2);
    }

    function test_KYC_removeUser_decreasesCount() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user2, KYC_LEVEL_BASIC);
        assertEq(kycRegistry.getVerifiedUserCount(), 2);

        kycRegistry.removeUser(user1);
        assertEq(kycRegistry.getVerifiedUserCount(), 1);
    }

    function test_KYC_batchAddUsers() public {
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        uint8[] memory levels = new uint8[](3);
        levels[0] = KYC_LEVEL_BASIC;
        levels[1] = KYC_LEVEL_ENHANCED;
        levels[2] = KYC_LEVEL_BASIC;

        kycRegistry.batchAddUsers(users, levels);

        assertTrue(kycRegistry.isVerified(user1));
        assertTrue(kycRegistry.isVerified(user2));
        assertTrue(kycRegistry.isVerified(user3));
        assertEq(kycRegistry.getKYCLevel(user2), KYC_LEVEL_ENHANCED);
        assertEq(kycRegistry.getVerifiedUserCount(), 3);
    }

    function test_KYC_batchAddUsers_revertLengthMismatch() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint8[] memory levels = new uint8[](1);
        levels[0] = KYC_LEVEL_BASIC;

        vm.expectRevert(
            abi.encodeWithSelector(IKYCRegistry.ArrayLengthMismatch.selector)
        );
        kycRegistry.batchAddUsers(users, levels);
    }

    function test_KYC_updateLevel() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.updateKYCLevel(user1, KYC_LEVEL_ENHANCED);
        assertEq(kycRegistry.getKYCLevel(user1), KYC_LEVEL_ENHANCED);
    }

    function test_KYC_updateLevel_emitsEvent() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        vm.expectEmit(true, false, false, true);
        emit IKYCRegistry.KYCLevelUpdated(
            user1,
            KYC_LEVEL_BASIC,
            KYC_LEVEL_ENHANCED
        );
        kycRegistry.updateKYCLevel(user1, KYC_LEVEL_ENHANCED);
    }

    function test_KYC_updateLevel_revertNotVerified() public {
        vm.expectRevert(
            abi.encodeWithSelector(IKYCRegistry.UserNotVerified.selector, user2)
        );
        kycRegistry.updateKYCLevel(user2, KYC_LEVEL_ENHANCED);
    }

    function test_KYC_getVerifiedUsers() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user2, KYC_LEVEL_ENHANCED);

        address[] memory users = kycRegistry.getVerifiedUsers();
        assertEq(users.length, 2);
    }

    // --- PropertyRegistry ---

    function test_Registry_registerProperty() public {
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

    function test_Registry_registerProperty_emitsEvent() public {
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

    function test_Registry_updateIPFS() public {
        propertyRegistry.registerProperty(
            "Prop",
            "Addr",
            100 ether,
            "ipfs://OldHash",
            user1
        );
        propertyRegistry.updateIPFSDocument(1, "ipfs://QmNewHashUpdated");
        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            1
        );
        assertEq(prop.ipfsDocumentURI, "ipfs://QmNewHashUpdated");
    }

    function test_Registry_updateIPFS_emitsEvent() public {
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

    // --- PropertyToken ---

    function _deployToken(
        uint8 requiredLevel
    ) internal returns (PropertyToken) {
        PropertyToken impl = new PropertyToken();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), owner);
        BeaconProxy proxy = new BeaconProxy(
            address(b),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "RealToken - Jl. Sudirman No. 1",
                    "RTJKS1",
                    1000 ether,
                    1,
                    address(kycRegistry),
                    requiredLevel,
                    owner
                )
            )
        );
        return PropertyToken(address(proxy));
    }

    function _deployTokenSetup() internal returns (PropertyToken) {
        PropertyToken token = _deployToken(KYC_LEVEL_BASIC);
        kycRegistry.addUser(owner, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user2, KYC_LEVEL_ENHANCED);
        return token;
    }

    function test_Token_nameAndSymbol() public {
        PropertyToken token = _deployTokenSetup();
        assertEq(token.name(), "RealToken - Jl. Sudirman No. 1");
        assertEq(token.symbol(), "RTJKS1");
    }

    function test_Token_mintsToOwner() public {
        PropertyToken token = _deployTokenSetup();
        assertEq(token.balanceOf(owner), 1000 ether);
        assertEq(token.totalSupply(), 1000 ether);
    }

    function test_Token_propertyId() public {
        PropertyToken token = _deployTokenSetup();
        assertEq(token.propertyId(), 1);
    }

    function test_Token_kycRegistryAddr() public {
        PropertyToken token = _deployTokenSetup();
        assertEq(address(token.kycRegistry()), address(kycRegistry));
    }

    function test_Token_transferBetweenKYC() public {
        PropertyToken token = _deployTokenSetup();
        token.transfer(user1, 100 ether);
        assertEq(token.balanceOf(user1), 100 ether);
    }

    function test_Token_transferUser1ToUser2() public {
        PropertyToken token = _deployTokenSetup();
        token.transfer(user1, 100 ether);
        vm.prank(user1);
        token.transfer(user2, 50 ether);
        assertEq(token.balanceOf(user2), 50 ether);
    }

    function test_Token_revertTransferToNonKYC() public {
        PropertyToken token = _deployTokenSetup();
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.RecipientNotAuthorized.selector,
                user3
            )
        );
        token.transfer(user3, 100 ether);
    }

    function test_Token_revertTransferFromNonKYC() public {
        PropertyToken token = _deployTokenSetup();
        kycRegistry.addUser(user3, KYC_LEVEL_BASIC);
        token.transfer(user3, 100 ether);
        kycRegistry.removeUser(user3);

        vm.prank(user3);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.SenderNotAuthorized.selector,
                user3
            )
        );
        token.transfer(user1, 10 ether);
    }

    function test_Token_revertInsufficientKYCLevel() public {
        _deployTokenSetup(); // sets up kycRegistry
        // Deploy an Enhanced-level token
        PropertyToken enhancedToken = _deployToken(KYC_LEVEL_ENHANCED);
        // owner is KYC level 1 (Basic), token requires level 2 → should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.InsufficientKYCLevel.selector,
                owner,
                2,
                1
            )
        );
        enhancedToken.transfer(user2, 100 ether);
    }

    function test_Token_pause() public {
        PropertyToken token = _deployTokenSetup();
        token.pause();
        vm.expectRevert();
        token.transfer(user1, 10 ether);
    }

    function test_Token_unpause() public {
        PropertyToken token = _deployTokenSetup();
        token.pause();
        token.unpause();
        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 10 ether);
    }

    function test_Token_pauseRevertNonOwner() public {
        PropertyToken token = _deployTokenSetup();
        vm.prank(user1);
        vm.expectRevert();
        token.pause();
    }

    function test_Token_mintAdditional() public {
        PropertyToken token = _deployTokenSetup();
        token.mint(owner, 500 ether);
        assertEq(token.totalSupply(), 1500 ether);
    }

    function test_Token_mintRevertNonOwner() public {
        PropertyToken token = _deployTokenSetup();
        vm.prank(user1);
        vm.expectRevert();
        token.mint(user1, 100 ether);
    }

    function test_Token_burn() public {
        PropertyToken token = _deployTokenSetup();
        token.burn(100 ether);
        assertEq(token.totalSupply(), 900 ether);
    }

    // --- PropertyTokenFactory ---

    function _defaultParams()
        internal
        view
        returns (IPropertyTokenFactory.CreateTokenParams memory)
    {
        return
            IPropertyTokenFactory.CreateTokenParams({
                name: "RealToken - Apartemen Sudirman",
                symbol: "RTAPS",
                totalSupply: 1000 ether,
                propertyName: "Apartemen Sudirman Park",
                propertyAddress: "Jl. Jend. Sudirman No. 1, Jakarta",
                totalValue: 100 ether,
                ipfsDocumentURI: "ipfs://QmExamplePropertyDocHash",
                requiredKYCLevel: KYC_LEVEL_BASIC,
                tokenOwner: owner
            });
    }

    function test_Factory_createAndRegister() public {
        factory.createPropertyToken(_defaultParams());

        address[] memory tokens = factory.getDeployedTokens();
        assertEq(tokens.length, 1);

        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            1
        );
        assertEq(prop.propertyName, "Apartemen Sudirman Park");
        assertEq(prop.tokenAddress, tokens[0]);
        assertEq(prop.ipfsDocumentURI, "ipfs://QmExamplePropertyDocHash");
    }

    function test_Factory_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IPropertyTokenFactory.PropertyTokenCreated(
            1,
            address(0),
            "",
            "",
            0
        );
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
        p2.requiredKYCLevel = KYC_LEVEL_ENHANCED;
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

    function test_Factory_revertEmptyName() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.name = "";
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyTokenFactory.EmptyString.selector,
                "name"
            )
        );
        factory.createPropertyToken(p);
    }

    function test_Factory_revertZeroSupply() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.totalSupply = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyTokenFactory.ZeroValue.selector,
                "totalSupply"
            )
        );
        factory.createPropertyToken(p);
    }

    function test_Factory_revertZeroValue() public {
        IPropertyTokenFactory.CreateTokenParams memory p = _defaultParams();
        p.totalValue = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyTokenFactory.ZeroValue.selector,
                "totalValue"
            )
        );
        factory.createPropertyToken(p);
    }

    function test_Factory_revertNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        factory.createPropertyToken(_defaultParams());
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

    // --- ERC20Votes ---

    function _deployVotesToken() internal returns (PropertyToken) {
        kycRegistry.addUser(owner, KYC_LEVEL_ENHANCED);
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user2, KYC_LEVEL_BASIC);

        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "RealToken - Villa Bali",
                symbol: "RTVB",
                totalSupply: 1000 ether,
                propertyName: "Villa Bali Seminyak",
                propertyAddress: "Jl. Seminyak No. 10, Bali",
                totalValue: 1000 ether,
                ipfsDocumentURI: "ipfs://QmVillaBaliDocs",
                requiredKYCLevel: KYC_LEVEL_BASIC,
                tokenOwner: owner
            })
        );

        address tokenAddr = factory.getTokenByPropertyId(1);
        return PropertyToken(tokenAddr);
    }

    function test_Votes_zeroBeforeDelegation() public {
        PropertyToken token = _deployVotesToken();
        assertEq(token.getVotes(owner), 0);
    }

    function test_Votes_selfDelegation() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(owner);
        assertEq(token.getVotes(owner), 1000 ether);
    }

    function test_Votes_delegateToAnother() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(user1);
        assertEq(token.getVotes(user1), 1000 ether);
        assertEq(token.getVotes(owner), 0);
    }

    function test_Votes_updateAfterTransfer() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(owner);
        vm.prank(user1);
        token.delegate(user1);

        token.transfer(user1, 300 ether);

        assertEq(token.getVotes(owner), 700 ether);
        assertEq(token.getVotes(user1), 300 ether);
    }

    function test_Votes_pastVotesCheckpoint() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(owner);
        vm.prank(user1);
        token.delegate(user1);

        uint256 snapshotBlock = block.number;
        vm.roll(block.number + 1);

        token.transfer(user1, 400 ether);
        vm.roll(block.number + 1);

        assertEq(token.getPastVotes(owner, snapshotBlock), 1000 ether);
        assertEq(token.getPastVotes(user1, snapshotBlock), 0);

        assertEq(token.getVotes(owner), 600 ether);
        assertEq(token.getVotes(user1), 400 ether);
    }

    function test_Votes_pastTotalSupply() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(owner);

        uint256 snapshotBlock = block.number;
        vm.roll(block.number + 1);

        token.mint(owner, 500 ether);
        vm.roll(block.number + 1);

        assertEq(token.getPastTotalSupply(snapshotBlock), 1000 ether);
        assertEq(token.totalSupply(), 1500 ether);
    }

    // --- ERC20Permit ---

    function test_Permit_gaslessApproval() public {
        uint256 ownerPk = 0xA11CE;
        address ownerAddr = vm.addr(ownerPk);

        kycRegistry.addUser(ownerAddr, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);

        PropertyToken permitToken = _deployPermitToken(ownerAddr);

        uint256 deadline = block.timestamp + 3600;
        bytes32 digest = _buildPermitDigest(
            permitToken,
            ownerAddr,
            user1,
            100 ether,
            deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        vm.prank(user1);
        permitToken.permit(ownerAddr, user1, 100 ether, deadline, v, r, s);
        assertEq(permitToken.allowance(ownerAddr, user1), 100 ether);
    }

    function _deployPermitToken(
        address tokenOwner
    ) internal returns (PropertyToken) {
        PropertyToken impl = new PropertyToken();
        UpgradeableBeacon b = new UpgradeableBeacon(
            address(impl),
            address(this)
        );
        BeaconProxy proxy = new BeaconProxy(
            address(b),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "Permit Test Token",
                    "PTT",
                    1000 ether,
                    99,
                    address(kycRegistry),
                    KYC_LEVEL_BASIC,
                    tokenOwner
                )
            )
        );
        return PropertyToken(address(proxy));
    }

    function _buildPermitDigest(
        PropertyToken token,
        address permitOwner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                permitOwner,
                spender,
                value,
                token.nonces(permitOwner),
                deadline
            )
        );
        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    structHash
                )
            );
    }

    // --- Upgradeability ---

    function test_Upgrade_KYCRegistry_preservesState() public {
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user2, KYC_LEVEL_ENHANCED);

        // Upgrade to same implementation (simulates upgrade)
        KYCRegistry kycV2 = new KYCRegistry();
        kycRegistry.upgradeToAndCall(address(kycV2), "");

        // Verify state preserved
        assertTrue(kycRegistry.isVerified(user1));
        assertEq(kycRegistry.getKYCLevel(user1), KYC_LEVEL_BASIC);
        assertTrue(kycRegistry.isVerified(user2));
        assertEq(kycRegistry.getKYCLevel(user2), KYC_LEVEL_ENHANCED);
        assertEq(kycRegistry.getVerifiedUserCount(), 2);
    }

    function test_Upgrade_PropertyRegistry_preservesState() public {
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

    function test_Upgrade_KYCRegistry_revertNonAdmin() public {
        KYCRegistry kycV2 = new KYCRegistry();
        vm.prank(user1);
        vm.expectRevert();
        kycRegistry.upgradeToAndCall(address(kycV2), "");
    }

    function test_Upgrade_Factory_revertNonOwner() public {
        PropertyTokenFactory factoryV2 = new PropertyTokenFactory();
        vm.prank(user1);
        vm.expectRevert();
        factory.upgradeToAndCall(address(factoryV2), "");
    }

    // --- E2E ---

    function test_E2E_fullTokenizationFlow() public {
        // 1. Admin whitelists users via KYC
        kycRegistry.addUser(owner, KYC_LEVEL_ENHANCED);
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user2, KYC_LEVEL_BASIC);

        // 2. Create property token via factory
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "RealToken - Apartemen Sudirman Park Unit A",
                symbol: "RTASPA",
                totalSupply: 1000 ether,
                propertyName: "Apartemen Sudirman Park Unit A",
                propertyAddress: "Jl. Jend. Sudirman No. 1, Jakarta Selatan",
                totalValue: 500 ether,
                ipfsDocumentURI: "ipfs://QmPropertyDocumentHash12345",
                requiredKYCLevel: KYC_LEVEL_BASIC,
                tokenOwner: owner
            })
        );

        // 3. Verify property was registered
        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            1
        );
        assertEq(prop.propertyName, "Apartemen Sudirman Park Unit A");
        assertEq(prop.ipfsDocumentURI, "ipfs://QmPropertyDocumentHash12345");
        assertTrue(prop.isActive);

        // 4. Get the deployed token
        address tokenAddr = factory.getTokenByPropertyId(1);
        PropertyToken token = PropertyToken(tokenAddr);

        // 5. Owner distributes tokens to investors (KYC-verified)
        token.transfer(user1, 200 ether);
        token.transfer(user2, 300 ether);

        assertEq(token.balanceOf(user1), 200 ether);
        assertEq(token.balanceOf(user2), 300 ether);
        assertEq(token.balanceOf(owner), 500 ether);

        // 6. user1 transfers to user2 (both KYC verified)
        vm.prank(user1);
        token.transfer(user2, 50 ether);
        assertEq(token.balanceOf(user1), 150 ether);
        assertEq(token.balanceOf(user2), 350 ether);

        // 7. Non-KYC user3 cannot receive tokens
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.RecipientNotAuthorized.selector,
                user3
            )
        );
        token.transfer(user3, 10 ether);

        // 8. Update IPFS document
        propertyRegistry.updateIPFSDocument(
            1,
            "ipfs://QmUpdatedDocWithNewPhotos"
        );
        IPropertyRegistry.Property memory updatedProp = propertyRegistry
            .getProperty(1);
        assertEq(
            updatedProp.ipfsDocumentURI,
            "ipfs://QmUpdatedDocWithNewPhotos"
        );
    }

    // --- Functional ---

    function test_Functional_multiTokenIndependentKYC() public {
        kycRegistry.addUser(owner, KYC_LEVEL_ENHANCED);
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user2, KYC_LEVEL_ENHANCED);

        // Token A: Basic KYC required
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Token A",
                symbol: "TKA",
                totalSupply: 1000 ether,
                propertyName: "Property A",
                propertyAddress: "Jl. A No. 1",
                totalValue: 100 ether,
                ipfsDocumentURI: "ipfs://A",
                requiredKYCLevel: 1,
                tokenOwner: owner
            })
        );
        address tokenAAddr = factory.getTokenByPropertyId(1);
        PropertyToken tokenA = PropertyToken(tokenAAddr);

        // Token B: Enhanced KYC required
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Token B",
                symbol: "TKB",
                totalSupply: 500 ether,
                propertyName: "Property B",
                propertyAddress: "Jl. B No. 2",
                totalValue: 200 ether,
                ipfsDocumentURI: "ipfs://B",
                requiredKYCLevel: 2,
                tokenOwner: owner
            })
        );
        address tokenBAddr = factory.getTokenByPropertyId(2);
        PropertyToken tokenB = PropertyToken(tokenBAddr);

        // user1 (Basic) can receive token A but NOT token B
        tokenA.transfer(user1, 50 ether);
        assertEq(tokenA.balanceOf(user1), 50 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.InsufficientKYCLevel.selector,
                user1,
                2,
                1
            )
        );
        tokenB.transfer(user1, 50 ether);

        // user2 (Enhanced) can receive both
        tokenA.transfer(user2, 50 ether);
        tokenB.transfer(user2, 50 ether);
        assertEq(tokenA.balanceOf(user2), 50 ether);
        assertEq(tokenB.balanceOf(user2), 50 ether);

        // Different property IDs, different supplies
        assertEq(tokenA.propertyId(), 1);
        assertEq(tokenB.propertyId(), 2);
        assertEq(factory.getDeployedTokenCount(), 2);
    }

    function test_Functional_fullLifecycle() public {
        kycRegistry.addUser(owner, KYC_LEVEL_ENHANCED);
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);

        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Lifecycle Token",
                symbol: "LCT",
                totalSupply: 1000 ether,
                propertyName: "Lifecycle Property",
                propertyAddress: "Jl. Lifecycle No. 1",
                totalValue: 500 ether,
                ipfsDocumentURI: "ipfs://lifecycle",
                requiredKYCLevel: 1,
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

        // Upgrade beacon, data should survive
        PropertyToken tokenV2 = new PropertyToken();
        beacon.upgradeTo(address(tokenV2));

        // Transfer still works after upgrade
        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 120 ether);
        assertEq(token.name(), "Lifecycle Token");
        assertEq(token.propertyId(), 1);
        assertEq(token.totalSupply(), 1000 ether);
    }
}
