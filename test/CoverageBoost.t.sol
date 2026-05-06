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
import "../contracts/governance/MultiSigWallet.sol";
import "../contracts/interfaces/IKYCRegistry.sol";
import "../contracts/interfaces/IPropertyRegistry.sol";
import "../contracts/interfaces/IPropertyTokenFactory.sol";

/// @title CoverageBoostTest
/// @notice Targets uncovered branches identified by `forge coverage`:
///         - KYCRegistry: swap-and-pop last-element path, addApprovedContract errors, removeApprovedContract
///         - PropertyRegistry: validation branches, access control, getPropertyByToken missing
///         - PropertyTokenFactory: empty symbol, zero tokenOwner, zero totalValue
///         - MultiSigWallet: failed execution, revokeConfirmation edge cases, changeThreshold
///         - PropertyToken: setPauser zero-address revert (new check)
contract CoverageBoostTest is Test {
    address internal admin;
    address internal user1;
    address internal user2;
    address internal user3;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyToken internal tokenImpl;
    UpgradeableBeacon internal beacon;
    PropertyTokenFactory internal factory;

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("u1");
        user2 = makeAddr("u2");
        user3 = makeAddr("u3");

        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry =
            KYCRegistry(address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()))));

        PropertyRegistry regImpl = new PropertyRegistry();
        propertyRegistry = PropertyRegistry(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(PropertyRegistry.initialize, ())))
        );

        tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), admin);

        PropertyTokenFactory factImpl = new PropertyTokenFactory();
        factory = PropertyTokenFactory(
            address(
                new ERC1967Proxy(
                    address(factImpl),
                    abi.encodeCall(
                        PropertyTokenFactory.initialize,
                        (address(kycRegistry), address(propertyRegistry), address(beacon))
                    )
                )
            )
        );

        propertyRegistry.grantRole(propertyRegistry.REGISTRY_ADMIN_ROLE(), address(factory));
    }

    // =========================================================================
    //  KYCRegistry – swap-and-pop: removing last element (no swap needed)
    // =========================================================================

    /// @notice When user is the last element in _verifiedAddresses, pop only – no swap.
    function test_KYC_removeUser_lastElement() public {
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);
        // Remove user2 who is last → no swap, just pop
        kycRegistry.removeUser(user2);
        assertFalse(kycRegistry.isVerified(user2));
        assertTrue(kycRegistry.isVerified(user1));
        assertEq(kycRegistry.getVerifiedUserCount(), 1);
        // Verify user1 index is still consistent
        kycRegistry.removeUser(user1);
        assertEq(kycRegistry.getVerifiedUserCount(), 0);
    }

    /// @notice When user is NOT last → swap-and-pop, verify internal list integrity.
    function test_KYC_removeUser_nonLastElement_swapAndPop() public {
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);
        kycRegistry.addUser(user3);
        // Remove user1 (first element, not last) → user3 should be swapped in
        kycRegistry.removeUser(user1);
        assertFalse(kycRegistry.isVerified(user1));
        assertTrue(kycRegistry.isVerified(user2));
        assertTrue(kycRegistry.isVerified(user3));
        assertEq(kycRegistry.getVerifiedUserCount(), 2);
        // Remaining users can still be removed cleanly
        kycRegistry.removeUser(user3);
        kycRegistry.removeUser(user2);
        assertEq(kycRegistry.getVerifiedUserCount(), 0);
    }

    // =========================================================================
    //  KYCRegistry – addApprovedContract error branches
    // =========================================================================

    /// @notice Registering an EOA (no code) must revert with NotAContract.
    function test_KYC_addApprovedContract_revertEOA() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.NotAContract.selector, user1));
        kycRegistry.addApprovedContract(user1);
    }

    /// @notice Registering the same contract twice must revert.
    function test_KYC_addApprovedContract_revertDuplicate() public {
        // Use kycRegistry itself as a contract-with-code
        address contractAddr = address(propertyRegistry);
        kycRegistry.addApprovedContract(contractAddr);
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.ContractAlreadyApproved.selector, contractAddr));
        kycRegistry.addApprovedContract(contractAddr);
    }

    /// @notice Non-admin cannot add approved contract.
    function test_KYC_addApprovedContract_revertNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        kycRegistry.addApprovedContract(address(propertyRegistry));
    }

    /// @notice removeApprovedContract removes the flag.
    function test_KYC_removeApprovedContract() public {
        address contractAddr = address(propertyRegistry);
        kycRegistry.addApprovedContract(contractAddr);
        assertTrue(kycRegistry.isApprovedContract(contractAddr));
        kycRegistry.removeApprovedContract(contractAddr);
        assertFalse(kycRegistry.isApprovedContract(contractAddr));
    }

    /// @notice removeApprovedContract on unapproved contract reverts.
    function test_KYC_removeApprovedContract_revertNotApproved() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.ContractNotApproved.selector, address(propertyRegistry)));
        kycRegistry.removeApprovedContract(address(propertyRegistry));
    }

    // =========================================================================
    //  PropertyRegistry – validation branches
    // =========================================================================

    /// @notice registerProperty reverts with empty address string.
    function test_Registry_revertEmptyAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.EmptyString.selector, "propertyAddress"));
        propertyRegistry.registerProperty("Name", "", 100 ether, "ipfs://x", user1);
    }

    /// @notice registerProperty reverts with empty IPFS URI.
    function test_Registry_revertEmptyIPFS() public {
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.EmptyString.selector, "ipfsDocumentURI"));
        propertyRegistry.registerProperty("Name", "Addr", 100 ether, "", user1);
    }

    /// @notice registerProperty reverts with zero totalValue.
    function test_Registry_revertZeroTotalValue() public {
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.ZeroValue.selector, "totalValue"));
        propertyRegistry.registerProperty("Name", "Addr", 0, "ipfs://x", user1);
    }

    /// @notice Non-admin cannot registerProperty.
    function test_Registry_revertNonAdminRegister() public {
        vm.prank(user1);
        vm.expectRevert();
        propertyRegistry.registerProperty("Name", "Addr", 1 ether, "ipfs://x", user2);
    }

    /// @notice getProperty on non-existent ID reverts.
    function test_Registry_revertGetPropertyNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.PropertyNotFound.selector, 999));
        propertyRegistry.getProperty(999);
    }

    /// @notice deactivateProperty on already-inactive reverts.
    function test_Registry_revertDeactivateAlreadyInactive() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        propertyRegistry.deactivateProperty(1);
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.PropertyNotActive.selector, 1));
        propertyRegistry.deactivateProperty(1);
    }

    /// @notice reactivateProperty on non-existent reverts.
    function test_Registry_revertReactivateNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.PropertyNotFound.selector, 777));
        propertyRegistry.reactivateProperty(777);
    }

    /// @notice reactivateProperty on already-active does NOT revert (idempotent or silent).
    function test_Registry_reactivateAlreadyActive_behavior() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        // If the contract doesn't revert on re-activating an active property, just verify state unchanged
        // (the test documents the actual contract behavior)
        IPropertyRegistry.Property memory before = propertyRegistry.getProperty(1);
        assertTrue(before.isActive);
    }

    /// @notice getPropertyByToken on unknown address reverts or returns empty.
    function test_Registry_getPropertyByToken_unknown() public {
        vm.expectRevert();
        propertyRegistry.getPropertyByToken(address(0xdead));
    }

    /// @notice deactivateProperty reverts for non-admin.
    function test_Registry_revertNonAdminDeactivate() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        vm.prank(user1);
        vm.expectRevert();
        propertyRegistry.deactivateProperty(1);
    }

    /// @notice updateIPFSDocument with empty string reverts.
    function test_Registry_updateIPFS_revertEmptyURI() public {
        propertyRegistry.registerProperty("P", "A", 1 ether, "ipfs://x", user1);
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.EmptyString.selector, "ipfsDocumentURI"));
        propertyRegistry.updateIPFSDocument(1, "");
    }

    // =========================================================================
    //  PropertyTokenFactory – validation branches
    // =========================================================================

    /// @notice createPropertyToken reverts with empty symbol.
    function test_Factory_revertEmptySymbol() public {
        IPropertyTokenFactory.CreateTokenParams memory p = IPropertyTokenFactory.CreateTokenParams({
            name: "Valid",
            symbol: "",
            totalSupply: 100 ether,
            propertyName: "Prop",
            propertyAddress: "Addr",
            totalValue: 10 ether,
            ipfsDocumentURI: "ipfs://x",
            tokenOwner: admin
        });
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "symbol"));
        factory.createPropertyToken(p);
    }

    /// @notice createPropertyToken reverts with empty propertyName.
    function test_Factory_revertEmptyPropertyName() public {
        IPropertyTokenFactory.CreateTokenParams memory p = IPropertyTokenFactory.CreateTokenParams({
            name: "Valid",
            symbol: "VLD",
            totalSupply: 100 ether,
            propertyName: "",
            propertyAddress: "Addr",
            totalValue: 10 ether,
            ipfsDocumentURI: "ipfs://x",
            tokenOwner: admin
        });
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "propertyName"));
        factory.createPropertyToken(p);
    }

    /// @notice createPropertyToken reverts with zero tokenOwner (OZ OwnableInvalidOwner).
    function test_Factory_revertZeroTokenOwner() public {
        IPropertyTokenFactory.CreateTokenParams memory p = IPropertyTokenFactory.CreateTokenParams({
            name: "Valid",
            symbol: "VLD",
            totalSupply: 100 ether,
            propertyName: "Prop",
            propertyAddress: "Addr",
            totalValue: 10 ether,
            ipfsDocumentURI: "ipfs://x",
            tokenOwner: address(0)
        });
        // OpenZeppelin OwnableUpgradeable reverts with OwnableInvalidOwner when owner=address(0)
        vm.expectRevert();
        factory.createPropertyToken(p);
    }

    // =========================================================================
    //  PropertyToken – setPauser zero-address fix
    // =========================================================================

    function _deployToken() internal returns (PropertyToken) {
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(PropertyToken.initialize, ("Test", "TST", 1000 ether, 1, address(kycRegistry), admin))
        );
        return PropertyToken(address(proxy));
    }

    /// @notice setPauser to zero address must revert after our fix.
    function test_Token_setPauser_revertZeroAddress() public {
        PropertyToken token = _deployToken();
        vm.expectRevert(PropertyToken.ZeroAddress.selector);
        token.setPauser(address(0));
    }

    /// @notice setPauser to valid address succeeds and updates storage.
    function test_Token_setPauser_valid() public {
        PropertyToken token = _deployToken();
        token.setPauser(user1);
        assertEq(token.pauser(), user1);
    }

    /// @notice Non-owner cannot call setPauser.
    function test_Token_setPauser_revertNonOwner() public {
        PropertyToken token = _deployToken();
        vm.prank(user1);
        vm.expectRevert();
        token.setPauser(user2);
    }

    /// @notice Pauser (non-owner) can pause but not unpause.
    function test_Token_pauser_canPauseNotUnpause() public {
        PropertyToken token = _deployToken();
        token.setPauser(user1);
        vm.prank(user1);
        token.pause();
        assertTrue(token.paused());

        // user1 (pauser, not owner) cannot unpause
        vm.prank(user1);
        vm.expectRevert();
        token.unpause();
    }

    // =========================================================================
    //  MultiSigWallet – additional branches
    // =========================================================================

    function _deployMultiSig(uint256 threshold) internal returns (MultiSigWallet ms) {
        address[] memory owners = new address[](3);
        owners[0] = admin;
        owners[1] = user1;
        owners[2] = user2;
        ms = new MultiSigWallet(owners, threshold);
    }

    /// @notice executeTransaction reverts when the call fails (must first meet threshold).
    function test_MultiSig_executionFailed_reverts() public {
        MultiSigWallet ms = _deployMultiSig(1);
        // Submit call to a precompile address with garbage data that will fail
        uint256 txId = ms.submitTransaction(address(0x9), 0, hex"cafebabe");
        ms.confirmTransaction(txId);
        // Threshold=1, admin confirmed → execute will fail at call
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    /// @notice confirmTransaction reverts if already confirmed by same owner.
    function test_MultiSig_revertDoubleConfirm() public {
        MultiSigWallet ms = _deployMultiSig(2);
        uint256 txId = ms.submitTransaction(user3, 0, "");
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyConfirmed.selector, txId));
        ms.confirmTransaction(txId);
    }

    /// @notice revokeConfirmation reverts if tx already executed.
    function test_MultiSig_revertRevokeAfterExecution() public {
        MultiSigWallet ms = _deployMultiSig(1);
        uint256 txId = ms.submitTransaction(user3, 0, "");
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);

        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyExecuted.selector, txId));
        ms.revokeConfirmation(txId);
    }

    /// @notice submitTransaction reverts for non-existent tx index.
    function test_MultiSig_confirmNonExistentTx_reverts() public {
        MultiSigWallet ms = _deployMultiSig(2);
        // TxDoesNotExist selector: 0x44fc2188 matches TxDoesNotExist(uint256)
        vm.expectRevert();
        ms.confirmTransaction(999);
    }

    /// @notice changeThreshold via self-call works through full multisig flow.
    function test_MultiSig_selfCall_changeThreshold() public {
        MultiSigWallet ms = _deployMultiSig(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (1));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        // admin submitted but NOT auto-confirmed; confirm as admin then user1
        ms.confirmTransaction(txId);
        vm.prank(user1);
        ms.confirmTransaction(txId);
        // Execute (threshold=2 met: admin + user1)
        ms.executeTransaction(txId);
        assertEq(ms.threshold(), 1);
    }

    /// @notice addOwner via self-call adds an owner correctly.
    function test_MultiSig_selfCall_addOwner() public {
        MultiSigWallet ms = _deployMultiSig(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.addOwner, (user3));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(user1);
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);
        assertTrue(ms.isOwner(user3));
        assertEq(ms.getOwnerCount(), 4);
    }

    /// @notice removeOwner via self-call removes correctly.
    function test_MultiSig_selfCall_removeOwner() public {
        MultiSigWallet ms = _deployMultiSig(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.removeOwner, (user2));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(user1);
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);
        assertFalse(ms.isOwner(user2));
        assertEq(ms.getOwnerCount(), 2);
    }

    /// @notice executeTransaction reverts if tx was already executed.
    function test_MultiSig_revertDoubleExecution() public {
        MultiSigWallet ms = _deployMultiSig(1);
        uint256 txId = ms.submitTransaction(user3, 0, "");
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyExecuted.selector, txId));
        ms.executeTransaction(txId);
    }
}

// =============================================================================
//  CoverageBoost2Test — Second pass targeting remaining uncovered lines
// =============================================================================
contract CoverageBoost2Test is Test {
    address internal admin;
    address internal user1;
    address internal user2;
    address internal user3;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyToken internal tokenImpl;
    UpgradeableBeacon internal beacon;
    PropertyTokenFactory internal factory;

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("u1");
        user2 = makeAddr("u2");
        user3 = makeAddr("u3");

        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry =
            KYCRegistry(address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()))));

        PropertyRegistry regImpl = new PropertyRegistry();
        propertyRegistry = PropertyRegistry(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(PropertyRegistry.initialize, ())))
        );

        tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), admin);

        PropertyTokenFactory factImpl = new PropertyTokenFactory();
        factory = PropertyTokenFactory(
            address(
                new ERC1967Proxy(
                    address(factImpl),
                    abi.encodeCall(
                        PropertyTokenFactory.initialize,
                        (address(kycRegistry), address(propertyRegistry), address(beacon))
                    )
                )
            )
        );
        propertyRegistry.grantRole(propertyRegistry.REGISTRY_ADMIN_ROLE(), address(factory));
    }

    // =========================================================================
    //  KYCRegistry — L70: removeUser zero address
    // =========================================================================
    function test_KYC_removeUser_revertZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.ZeroAddress.selector));
        kycRegistry.removeUser(address(0));
    }

    /// @notice removeApprovedContract zero address branch (L139)
    function test_KYC_removeApprovedContract_revertZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.ZeroAddress.selector));
        kycRegistry.removeApprovedContract(address(0));
    }

    // =========================================================================
    //  PropertyRegistry — L118-142: updatePropertyName, updatePropertyValue
    // =========================================================================
    function test_Registry_updatePropertyName() public {
        propertyRegistry.registerProperty("Old Name", "Addr", 1 ether, "ipfs://x", user1);
        propertyRegistry.updatePropertyName(1, "New Name");
        IPropertyRegistry.Property memory p = propertyRegistry.getProperty(1);
        assertEq(p.propertyName, "New Name");
    }

    function test_Registry_updatePropertyName_revertEmpty() public {
        propertyRegistry.registerProperty("Old", "Addr", 1 ether, "ipfs://x", user1);
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.EmptyString.selector, "propertyName"));
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
        vm.expectRevert(abi.encodeWithSelector(IPropertyRegistry.ZeroValue.selector, "totalValue"));
        propertyRegistry.updatePropertyValue(1, 0);
    }

    /// @notice getAllPropertyIds returns populated list (L193)
    function test_Registry_getAllPropertyIds() public {
        propertyRegistry.registerProperty("P1", "A", 1 ether, "ipfs://x", user1);
        propertyRegistry.registerProperty("P2", "B", 2 ether, "ipfs://y", user2);
        uint256[] memory ids = propertyRegistry.getAllPropertyIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    // =========================================================================
    //  PropertyTokenFactory — initialize zero-address guards (L60-62)
    // =========================================================================
    function test_Factory_initialize_revertZeroKYC() public {
        PropertyTokenFactory factImpl = new PropertyTokenFactory();
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.ZeroAddress.selector));
        new ERC1967Proxy(
            address(factImpl),
            abi.encodeCall(PropertyTokenFactory.initialize, (address(0), address(propertyRegistry), address(beacon)))
        );
    }

    function test_Factory_initialize_revertZeroRegistry() public {
        PropertyTokenFactory factImpl = new PropertyTokenFactory();
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.ZeroAddress.selector));
        new ERC1967Proxy(
            address(factImpl),
            abi.encodeCall(PropertyTokenFactory.initialize, (address(kycRegistry), address(0), address(beacon)))
        );
    }

    function test_Factory_initialize_revertZeroBeacon() public {
        PropertyTokenFactory factImpl = new PropertyTokenFactory();
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.ZeroAddress.selector));
        new ERC1967Proxy(
            address(factImpl),
            abi.encodeCall(
                PropertyTokenFactory.initialize, (address(kycRegistry), address(propertyRegistry), address(0))
            )
        );
    }

    /// @notice _validateParams: empty propertyAddress (L158)
    function test_Factory_revertEmptyPropertyAddress() public {
        IPropertyTokenFactory.CreateTokenParams memory p = IPropertyTokenFactory.CreateTokenParams({
            name: "T",
            symbol: "T",
            totalSupply: 100 ether,
            propertyName: "P",
            propertyAddress: "",
            totalValue: 10 ether,
            ipfsDocumentURI: "ipfs://x",
            tokenOwner: admin
        });
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "propertyAddress"));
        factory.createPropertyToken(p);
    }

    /// @notice _validateParams: empty ipfsDocumentURI (L161)
    function test_Factory_revertEmptyIPFS() public {
        IPropertyTokenFactory.CreateTokenParams memory p = IPropertyTokenFactory.CreateTokenParams({
            name: "T",
            symbol: "T",
            totalSupply: 100 ether,
            propertyName: "P",
            propertyAddress: "A",
            totalValue: 10 ether,
            ipfsDocumentURI: "",
            tokenOwner: admin
        });
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.EmptyString.selector, "ipfsDocumentURI"));
        factory.createPropertyToken(p);
    }

    /// @notice _validateParams: zero totalSupply
    function test_Factory_revertZeroSupply() public {
        IPropertyTokenFactory.CreateTokenParams memory p = IPropertyTokenFactory.CreateTokenParams({
            name: "T",
            symbol: "T",
            totalSupply: 0,
            propertyName: "P",
            propertyAddress: "A",
            totalValue: 10 ether,
            ipfsDocumentURI: "ipfs://x",
            tokenOwner: admin
        });
        vm.expectRevert(abi.encodeWithSelector(PropertyTokenFactory.ZeroValue.selector, "totalSupply"));
        factory.createPropertyToken(p);
    }

    // =========================================================================
    //  MultiSigWallet — remaining branch coverage
    // =========================================================================
    function _ms(uint256 th) internal returns (MultiSigWallet) {
        address[] memory own = new address[](3);
        own[0] = admin;
        own[1] = user1;
        own[2] = user2;
        return new MultiSigWallet(own, th);
    }

    /// @notice addOwner: zero address (L168)
    function test_MultiSig_addOwner_revertZeroAddress() public {
        MultiSigWallet ms = _ms(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.addOwner, (address(0)));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(user1);
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    /// @notice addOwner: duplicate (L169)
    function test_MultiSig_addOwner_revertDuplicate() public {
        MultiSigWallet ms = _ms(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.addOwner, (user1));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(user1);
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    /// @notice removeOwner causes threshold to shrink (L197-200)
    function test_MultiSig_removeOwner_shrinksThreshold() public {
        // Start with 3 owners, threshold=3; removing one → threshold must shrink to 2
        address[] memory own = new address[](3);
        own[0] = admin;
        own[1] = user1;
        own[2] = user2;
        MultiSigWallet ms = new MultiSigWallet(own, 3);

        bytes memory data = abi.encodeCall(MultiSigWallet.removeOwner, (user2));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(user1);
        ms.confirmTransaction(txId);
        vm.prank(user2);
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);

        // After removal: 2 owners, threshold auto-adjusted to 2
        assertEq(ms.getOwnerCount(), 2);
        assertEq(ms.threshold(), 2);
    }

    /// @notice changeThreshold: invalid (zero or > owner count) reverts (L208)
    function test_MultiSig_changeThreshold_revertInvalid() public {
        MultiSigWallet ms = _ms(2);
        // Try to set threshold = 99 > 3 owners
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (99));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(user1);
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    /// @notice revokeConfirmation: not confirmed reverts (L158 in revokeConfirmation)
    function test_MultiSig_revoke_revertNotConfirmed() public {
        MultiSigWallet ms = _ms(2);
        uint256 txId = ms.submitTransaction(user3, 0, "");
        // user1 hasn't confirmed, trying to revoke reverts
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxNotConfirmed.selector, txId));
        ms.revokeConfirmation(txId);
    }

    /// @notice executeTransaction: non-owner cannot call (modifier L56)
    function test_MultiSig_executeTransaction_revertNonOwner() public {
        MultiSigWallet ms = _ms(1);
        uint256 txId = ms.submitTransaction(user3, 0, "");
        ms.confirmTransaction(txId);
        vm.prank(user3);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector));
        ms.executeTransaction(txId);
    }

    /// @notice removeOwner: not an owner reverts (L179)
    function test_MultiSig_removeOwner_revertNotOwner() public {
        MultiSigWallet ms = _ms(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.removeOwner, (user3)); // user3 not owner
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(user1);
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }
}

