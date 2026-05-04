// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../contracts/governance/MultiSigWallet.sol";
import "../contracts/core/KYCRegistry.sol";
import "../contracts/core/PropertyRegistry.sol";
import "../contracts/core/PropertyToken.sol";
import "../contracts/core/PropertyTokenFactory.sol";
import "../contracts/interfaces/IPropertyTokenFactory.sol";

/// @title GovernanceTest
/// @notice Tests for MultiSigWallet: deployment, submit, confirm,
///         execute, revoke, and owner management.
contract GovernanceTest is Test {
    address owner1;
    address owner2;
    address owner3;
    address nonOwner;

    MultiSigWallet multiSig;

    uint256 constant THRESHOLD = 2; // 2-of-3

    function setUp() public {
        owner1 = address(this);
        owner2 = makeAddr("owner2");
        owner3 = makeAddr("owner3");
        nonOwner = makeAddr("nonOwner");

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        multiSig = new MultiSigWallet(owners, THRESHOLD);
    }

    function test_Deployment_correctOwners() public {
        address[] memory owners = multiSig.getOwners();
        assertEq(owners.length, 3);
        assertTrue(multiSig.isOwner(owner1));
        assertTrue(multiSig.isOwner(owner2));
        assertTrue(multiSig.isOwner(owner3));
    }

    function test_Deployment_correctThreshold() public {
        assertEq(multiSig.threshold(), THRESHOLD);
    }

    function test_Deployment_revertZeroThreshold() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSigWallet.InvalidThreshold.selector,
                0,
                1
            )
        );
        new MultiSigWallet(owners, 0);
    }

    function test_Deployment_revertThresholdTooHigh() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSigWallet.InvalidThreshold.selector,
                2,
                1
            )
        );
        new MultiSigWallet(owners, 2);
    }

    function test_Deployment_revertEmptyOwners() public {
        address[] memory owners = new address[](0);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.OwnersRequired.selector)
        );
        new MultiSigWallet(owners, 1);
    }

    function test_Deployment_revertDuplicateOwners() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner1;
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSigWallet.DuplicateOwner.selector,
                owner1
            )
        );
        new MultiSigWallet(owners, 1);
    }

    function test_Deployment_revertZeroAddressOwner() public {
        address[] memory owners = new address[](1);
        owners[0] = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.ZeroAddress.selector)
        );
        new MultiSigWallet(owners, 1);
    }

    function test_Submit_transaction() public {
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (3));
        vm.expectEmit(true, true, false, true);
        emit MultiSigWallet.TransactionSubmitted(0, address(multiSig), 0, data);
        multiSig.submitTransaction(address(multiSig), 0, data);
        assertEq(multiSig.getTransactionCount(), 1);
    }

    function test_Submit_revertNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.NotOwner.selector)
        );
        multiSig.submitTransaction(owner1, 0, "");
    }

    function test_Confirm_transaction() public {
        multiSig.submitTransaction(owner1, 0, "");

        vm.expectEmit(true, true, false, true);
        emit MultiSigWallet.TransactionConfirmed(0, owner1);
        multiSig.confirmTransaction(0);

        (, , , bool executed, uint256 confirmCount) = multiSig.getTransaction(
            0
        );
        assertEq(confirmCount, 1);
        assertFalse(executed);
    }

    function test_Confirm_revertDoubleConfirm() public {
        multiSig.submitTransaction(owner1, 0, "");
        multiSig.confirmTransaction(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSigWallet.TxAlreadyConfirmed.selector,
                0
            )
        );
        multiSig.confirmTransaction(0);
    }

    function test_Confirm_revertNonExistentTx() public {
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.TxDoesNotExist.selector, 999)
        );
        multiSig.confirmTransaction(999);
    }

    function test_Execute_afterThreshold() public {
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (3));
        multiSig.submitTransaction(address(multiSig), 0, data);

        // Confirm by 2 owners (threshold = 2)
        multiSig.confirmTransaction(0); // owner1
        vm.prank(owner2);
        multiSig.confirmTransaction(0);

        vm.expectEmit(true, false, false, true);
        emit MultiSigWallet.TransactionExecuted(0);
        multiSig.executeTransaction(0);

        assertEq(multiSig.threshold(), 3);
    }

    function test_Execute_revertInsufficientConfirmations() public {
        multiSig.submitTransaction(owner1, 0, "");
        multiSig.confirmTransaction(0);
        // Only 1 confirmation, threshold is 2
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSigWallet.InsufficientConfirmations.selector,
                1,
                2
            )
        );
        multiSig.executeTransaction(0);
    }

    function test_Execute_revertAlreadyExecuted() public {
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (3));
        multiSig.submitTransaction(address(multiSig), 0, data);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.TxAlreadyExecuted.selector, 0)
        );
        multiSig.executeTransaction(0);
    }

    function test_Revoke_confirmation() public {
        multiSig.submitTransaction(owner1, 0, "");
        multiSig.confirmTransaction(0);

        vm.expectEmit(true, true, false, true);
        emit MultiSigWallet.TransactionRevoked(0, owner1);
        multiSig.revokeConfirmation(0);

        (, , , , uint256 confirmCount) = multiSig.getTransaction(0);
        assertEq(confirmCount, 0);
    }

    function test_Revoke_revertNotConfirmed() public {
        multiSig.submitTransaction(owner1, 0, "");
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.TxNotConfirmed.selector, 0)
        );
        multiSig.revokeConfirmation(0);
    }

    function test_OwnerMgmt_addOwner() public {
        bytes memory data = abi.encodeCall(MultiSigWallet.addOwner, (nonOwner));
        multiSig.submitTransaction(address(multiSig), 0, data);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        assertTrue(multiSig.isOwner(nonOwner));
        assertEq(multiSig.getOwnerCount(), 4);
    }

    function test_OwnerMgmt_removeOwner() public {
        bytes memory data = abi.encodeCall(
            MultiSigWallet.removeOwner,
            (owner3)
        );
        multiSig.submitTransaction(address(multiSig), 0, data);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        assertFalse(multiSig.isOwner(owner3));
        assertEq(multiSig.getOwnerCount(), 2);
        assertEq(multiSig.threshold(), 2);
    }

    function test_OwnerMgmt_revertDirectAddOwner() public {
        vm.expectRevert("Must call via multisig tx");
        multiSig.addOwner(nonOwner);
    }
}

/// @title TimelockMultiSigIntegrationTest
/// @notice Integration tests for MultiSig → TimelockController → Contract
///         governance flow: schedule, execute, cancel.
contract TimelockMultiSigIntegrationTest is Test {
    address owner1;
    address owner2;
    address owner3;
    address nonOwner;

    MultiSigWallet multiSig;
    TimelockController timelockController;
    KYCRegistry kycRegistry;

    uint256 constant THRESHOLD = 2;
    uint256 constant MIN_DELAY = 3600; // 1 hour

    function setUp() public {
        owner1 = address(this);
        owner2 = makeAddr("owner2");
        owner3 = makeAddr("owner3");
        nonOwner = makeAddr("nonOwner");

        // Deploy MultiSig
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;
        multiSig = new MultiSigWallet(owners, THRESHOLD);

        // Deploy TimelockController
        address[] memory proposers = new address[](1);
        proposers[0] = address(multiSig);
        address[] memory executors = new address[](1);
        executors[0] = address(multiSig);
        timelockController = new TimelockController(
            MIN_DELAY,
            proposers,
            executors,
            address(0)
        );

        // Deploy KYCRegistry via proxy
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(
            address(kycImpl),
            abi.encodeCall(KYCRegistry.initialize, ())
        );
        kycRegistry = KYCRegistry(address(kycProxy));

        // Transfer roles to timelock
        bytes32 DEFAULT_ADMIN_ROLE = kycRegistry.DEFAULT_ADMIN_ROLE();
        bytes32 KYC_ADMIN_ROLE = kycRegistry.KYC_ADMIN_ROLE();

        kycRegistry.grantRole(DEFAULT_ADMIN_ROLE, address(timelockController));
        kycRegistry.grantRole(KYC_ADMIN_ROLE, address(timelockController));
        kycRegistry.renounceRole(KYC_ADMIN_ROLE, owner1);
        kycRegistry.renounceRole(DEFAULT_ADMIN_ROLE, owner1);
    }

    function test_Integration_preventDirectAdmin() public {
        vm.expectRevert();
        kycRegistry.addUser(nonOwner, 1);
    }

    function test_Integration_multiSigTimelockFlow() public {
        address timelockAddr = address(timelockController);
        address kycAddr = address(kycRegistry);

        // 1. Encode final operation: kycRegistry.addUser(nonOwner, 1)
        bytes memory kycCalldata = abi.encodeCall(
            KYCRegistry.addUser,
            (nonOwner, 1)
        );

        // 2. Encode timelock.schedule() call
        bytes32 salt = keccak256("addUser-nonOwner");
        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (kycAddr, 0, kycCalldata, bytes32(0), salt, MIN_DELAY)
        );

        // 3. Submit schedule via MultiSig
        multiSig.submitTransaction(timelockAddr, 0, scheduleCalldata);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        // 4. Wait for timelock delay
        vm.warp(block.timestamp + MIN_DELAY + 1);

        // 5. Encode timelock.execute() call
        bytes memory executeCalldata = abi.encodeCall(
            TimelockController.execute,
            (kycAddr, 0, kycCalldata, bytes32(0), salt)
        );

        // 6. Execute via MultiSig
        multiSig.submitTransaction(timelockAddr, 0, executeCalldata);
        multiSig.confirmTransaction(1);
        vm.prank(owner2);
        multiSig.confirmTransaction(1);
        multiSig.executeTransaction(1);

        // 7. Verify user was added via governance flow
        assertTrue(kycRegistry.isVerified(nonOwner));
        assertEq(kycRegistry.getKYCLevel(nonOwner), 1);
    }

    function test_Integration_revertEarlyExecution() public {
        address timelockAddr = address(timelockController);
        address kycAddr = address(kycRegistry);

        bytes memory kycCalldata = abi.encodeCall(
            KYCRegistry.addUser,
            (nonOwner, 1)
        );
        bytes32 salt = keccak256("early-execute-test");

        // Schedule
        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (kycAddr, 0, kycCalldata, bytes32(0), salt, MIN_DELAY)
        );
        multiSig.submitTransaction(timelockAddr, 0, scheduleCalldata);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        // Try to execute immediately (should fail — delay not passed)
        bytes memory executeCalldata = abi.encodeCall(
            TimelockController.execute,
            (kycAddr, 0, kycCalldata, bytes32(0), salt)
        );
        multiSig.submitTransaction(timelockAddr, 0, executeCalldata);
        multiSig.confirmTransaction(1);
        vm.prank(owner2);
        multiSig.confirmTransaction(1);

        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector)
        );
        multiSig.executeTransaction(1);
    }

    function test_Integration_cancelScheduledOperation() public {
        address timelockAddr = address(timelockController);
        address kycAddr = address(kycRegistry);

        bytes memory kycCalldata = abi.encodeCall(
            KYCRegistry.addUser,
            (nonOwner, 1)
        );
        bytes32 salt = keccak256("cancel-test");

        // Schedule
        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (kycAddr, 0, kycCalldata, bytes32(0), salt, MIN_DELAY)
        );
        multiSig.submitTransaction(timelockAddr, 0, scheduleCalldata);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        // Compute operation ID
        bytes32 operationId = keccak256(
            abi.encode(kycAddr, uint256(0), kycCalldata, bytes32(0), salt)
        );

        // Cancel via MultiSig
        bytes memory cancelCalldata = abi.encodeCall(
            TimelockController.cancel,
            (operationId)
        );
        multiSig.submitTransaction(timelockAddr, 0, cancelCalldata);
        multiSig.confirmTransaction(1);
        vm.prank(owner2);
        multiSig.confirmTransaction(1);
        multiSig.executeTransaction(1);

        // Verify the operation is no longer pending
        assertFalse(timelockController.isOperationPending(operationId));
    }
}

/// @title OperatorDirectFlowTest
/// @notice Integration tests that prove the new tiered-governance architecture:
///         operator EOAs holding KYC_ADMIN_ROLE / REGISTRY_ADMIN_ROLE /
///         OPERATOR_ROLE can perform day-to-day operations without going
///         through MultiSig or Timelock. The Timelock remains the sole holder
///         of DEFAULT_ADMIN_ROLE and contract ownership (for upgrades).
contract OperatorDirectFlowTest is Test {
    address deployer;
    address timelock; // simulated timelock address (no real TimelockController needed)
    address kycOperator;
    address registryOperator;
    address factoryOperator;
    address investor1;
    address investor2;

    KYCRegistry kycRegistry;
    PropertyRegistry propertyRegistry;
    PropertyTokenFactory factory;
    UpgradeableBeacon beacon;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr("timelock");
        kycOperator = makeAddr("kycOperator");
        registryOperator = makeAddr("registryOperator");
        factoryOperator = makeAddr("factoryOperator");
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");

        // --- Deploy core contracts ---
        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry = KYCRegistry(
            address(
                new ERC1967Proxy(
                    address(kycImpl),
                    abi.encodeCall(KYCRegistry.initialize, ())
                )
            )
        );

        PropertyRegistry regImpl = new PropertyRegistry();
        propertyRegistry = PropertyRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(PropertyRegistry.initialize, ())
                )
            )
        );

        PropertyToken tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), deployer);

        PropertyTokenFactory factoryImpl = new PropertyTokenFactory();
        factory = PropertyTokenFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl),
                    abi.encodeCall(
                        PropertyTokenFactory.initialize,
                        (address(kycRegistry), address(propertyRegistry), address(beacon))
                    )
                )
            )
        );

        // Factory needs REGISTRY_ADMIN_ROLE so createPropertyToken can auto-register
        propertyRegistry.grantRole(
            propertyRegistry.REGISTRY_ADMIN_ROLE(),
            address(factory)
        );

        // --- Replicate Deploy.s.sol role partitioning ---
        bytes32 kycAdmin = kycRegistry.KYC_ADMIN_ROLE();
        bytes32 kycDefaultAdmin = kycRegistry.DEFAULT_ADMIN_ROLE();
        kycRegistry.grantRole(kycDefaultAdmin, timelock);
        kycRegistry.grantRole(kycAdmin, kycOperator);
        kycRegistry.renounceRole(kycAdmin, deployer);
        kycRegistry.renounceRole(kycDefaultAdmin, deployer);

        bytes32 regAdmin = propertyRegistry.REGISTRY_ADMIN_ROLE();
        bytes32 regDefaultAdmin = propertyRegistry.DEFAULT_ADMIN_ROLE();
        propertyRegistry.grantRole(regDefaultAdmin, timelock);
        propertyRegistry.grantRole(regAdmin, registryOperator);
        propertyRegistry.renounceRole(regAdmin, deployer);
        propertyRegistry.renounceRole(regDefaultAdmin, deployer);

        bytes32 facAdmin = factory.DEFAULT_ADMIN_ROLE();
        bytes32 facOp = factory.OPERATOR_ROLE();
        factory.grantRole(facAdmin, timelock);
        factory.grantRole(facOp, factoryOperator);
        factory.renounceRole(facOp, deployer);
        factory.renounceRole(facAdmin, deployer);

        beacon.transferOwnership(timelock);
    }

    // -------------------------------------------------------------------
    //  Tier 1 — operator EOAs execute without governance delay
    // -------------------------------------------------------------------

    function test_Tier1_kycOperator_addUserDirect() public {
        vm.prank(kycOperator);
        kycRegistry.addUser(investor1, 1);

        assertTrue(kycRegistry.isVerified(investor1));
        assertEq(kycRegistry.getKYCLevel(investor1), 1);
    }

    function test_Tier1_kycOperator_batchAddUsersDirect() public {
        address[] memory users = new address[](3);
        users[0] = investor1;
        users[1] = investor2;
        users[2] = makeAddr("investor3");

        uint8[] memory levels = new uint8[](3);
        levels[0] = 1;
        levels[1] = 2;
        levels[2] = 1;

        vm.prank(kycOperator);
        kycRegistry.batchAddUsers(users, levels);

        assertEq(kycRegistry.getVerifiedUserCount(), 3);
    }

    function test_Tier1_kycOperator_removeUserDirect() public {
        vm.prank(kycOperator);
        kycRegistry.addUser(investor1, 1);

        vm.prank(kycOperator);
        kycRegistry.removeUser(investor1);

        assertFalse(kycRegistry.isVerified(investor1));
    }

    function test_Tier1_kycOperator_updateKYCLevelDirect() public {
        vm.prank(kycOperator);
        kycRegistry.addUser(investor1, 1);

        vm.prank(kycOperator);
        kycRegistry.updateKYCLevel(investor1, 2);

        assertEq(kycRegistry.getKYCLevel(investor1), 2);
    }

    function test_Tier1_registryOperator_updateIPFSDirect() public {
        vm.prank(registryOperator);
        propertyRegistry.registerProperty(
            "Prop",
            "Jl. A",
            100 ether,
            "ipfs://old",
            makeAddr("tokenA")
        );

        vm.prank(registryOperator);
        propertyRegistry.updateIPFSDocument(1, "ipfs://new");

        assertEq(propertyRegistry.getProperty(1).ipfsDocumentURI, "ipfs://new");
    }

    function test_Tier1_registryOperator_deactivateDirect() public {
        vm.prank(registryOperator);
        propertyRegistry.registerProperty(
            "Prop",
            "Jl. A",
            100 ether,
            "ipfs://doc",
            makeAddr("tokenB")
        );

        vm.prank(registryOperator);
        propertyRegistry.deactivateProperty(1);

        assertFalse(propertyRegistry.getProperty(1).isActive);
    }

    function test_Tier1_factoryOperator_createTokenDirect() public {
        vm.prank(factoryOperator);
        (address tokenAddr, uint256 propertyId) = factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "RT-T1",
                symbol: "RTT1",
                totalSupply: 1000 ether,
                propertyName: "Tier1 Property",
                propertyAddress: "Jl. Tier1",
                totalValue: 100 ether,
                ipfsDocumentURI: "ipfs://tier1",
                requiredKYCLevel: 1,
                tokenOwner: timelock
            })
        );

        assertTrue(tokenAddr != address(0));
        assertEq(propertyId, 1);
        assertEq(factory.getDeployedTokenCount(), 1);
    }

    // -------------------------------------------------------------------
    //  Tier 2 — critical ops blocked at operator level, require governance
    // -------------------------------------------------------------------

    function test_Tier2_kycOperator_cannotUpgradeKYCRegistry() public {
        KYCRegistry v2 = new KYCRegistry();
        vm.prank(kycOperator);
        vm.expectRevert();
        kycRegistry.upgradeToAndCall(address(v2), "");
    }

    function test_Tier2_registryOperator_cannotUpgradePropertyRegistry() public {
        PropertyRegistry v2 = new PropertyRegistry();
        vm.prank(registryOperator);
        vm.expectRevert();
        propertyRegistry.upgradeToAndCall(address(v2), "");
    }

    function test_Tier2_factoryOperator_cannotUpgradeFactory() public {
        PropertyTokenFactory v2 = new PropertyTokenFactory();
        vm.prank(factoryOperator);
        vm.expectRevert();
        factory.upgradeToAndCall(address(v2), "");
    }

    function test_Tier2_factoryOperator_cannotUpgradeBeacon() public {
        PropertyToken v2 = new PropertyToken();
        vm.prank(factoryOperator);
        vm.expectRevert();
        beacon.upgradeTo(address(v2));
    }

    function test_Tier2_kycOperator_cannotGrantRoles() public {
        bytes32 role = kycRegistry.KYC_ADMIN_ROLE();
        vm.prank(kycOperator);
        vm.expectRevert();
        kycRegistry.grantRole(role, kycOperator);
    }

    function test_Tier2_timelock_canGrantRoles() public {
        address newOperator = makeAddr("newKycOperator");
        bytes32 role = kycRegistry.KYC_ADMIN_ROLE();

        vm.prank(timelock);
        kycRegistry.grantRole(role, newOperator);

        vm.prank(newOperator);
        kycRegistry.addUser(investor1, 1);
        assertTrue(kycRegistry.isVerified(investor1));
    }

    function test_Tier2_timelock_cannotAddUserDirectly() public {
        // Timelock holds DEFAULT_ADMIN_ROLE but NOT KYC_ADMIN_ROLE.
        // Daily ops still require the operator role.
        vm.prank(timelock);
        vm.expectRevert();
        kycRegistry.addUser(investor1, 1);
    }

    // -------------------------------------------------------------------
    //  Cross-cutting — random actors locked out
    // -------------------------------------------------------------------

    function test_Acl_randomActorCannotAddKYC() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        kycRegistry.addUser(investor1, 1);
    }

    function test_Acl_randomActorCannotCreateToken() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        factory.createPropertyToken(
            IPropertyTokenFactory.CreateTokenParams({
                name: "Nope",
                symbol: "NO",
                totalSupply: 1,
                propertyName: "Nope",
                propertyAddress: "Nope",
                totalValue: 1,
                ipfsDocumentURI: "ipfs://nope",
                requiredKYCLevel: 1,
                tokenOwner: makeAddr("random")
            })
        );
    }
}
