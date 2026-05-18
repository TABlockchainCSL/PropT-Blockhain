// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../../contracts/governance-upgrade/MultiSigWallet.sol";
import "../../contracts/core/KYCRegistry.sol";
import "../../contracts/core/PropertyRegistry.sol";
import "../../contracts/core/PropertyToken.sol";
import "../../contracts/core/PropertyTokenFactory.sol";
import "../../contracts/interfaces/IPropertyTokenFactory.sol";

/// @title TimelockMultiSigIntegrationTest
/// @notice Integration tests for MultiSig → TimelockController → Contract governance flow:
///         schedule, execute, cancel, and security (attacker cannot use Timelock).
contract TimelockMultiSigIntegrationTest is Test {
    address internal owner1;
    address internal owner2;
    address internal owner3;
    address internal nonOwner;

    MultiSigWallet internal multiSig;
    TimelockController internal timelockController;
    KYCRegistry internal kycRegistry;

    uint256 constant THRESHOLD = 2;
    uint256 constant MIN_DELAY = 3600; // 1 hour

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

        address[] memory proposers = new address[](1);
        proposers[0] = address(multiSig);
        address[] memory executors = new address[](1);
        executors[0] = address(multiSig);
        timelockController = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy =
            new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        kycRegistry = KYCRegistry(address(kycProxy));

        // Transfer admin roles to Timelock; revoke from deployer
        bytes32 DEFAULT_ADMIN_ROLE = kycRegistry.DEFAULT_ADMIN_ROLE();
        bytes32 KYC_ADMIN_ROLE = kycRegistry.KYC_ADMIN_ROLE();
        kycRegistry.grantRole(DEFAULT_ADMIN_ROLE, address(timelockController));
        kycRegistry.grantRole(KYC_ADMIN_ROLE, address(timelockController));
        kycRegistry.renounceRole(KYC_ADMIN_ROLE, owner1);
        kycRegistry.renounceRole(DEFAULT_ADMIN_ROLE, owner1);
    }

    function test_Integration_preventDirectAdmin() public {
        vm.expectRevert();
        kycRegistry.addUser(nonOwner);
    }

    function test_Integration_multiSigTimelockFlow() public {
        address timelockAddr = address(timelockController);
        address kycAddr = address(kycRegistry);

        bytes memory kycCalldata = abi.encodeCall(KYCRegistry.addUser, (nonOwner));
        bytes32 salt = keccak256("addUser-nonOwner");
        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (kycAddr, 0, kycCalldata, bytes32(0), salt, MIN_DELAY)
        );

        multiSig.submitTransaction(timelockAddr, 0, scheduleCalldata);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        vm.warp(block.timestamp + MIN_DELAY + 1);

        bytes memory executeCalldata = abi.encodeCall(
            TimelockController.execute, (kycAddr, 0, kycCalldata, bytes32(0), salt)
        );

        multiSig.submitTransaction(timelockAddr, 0, executeCalldata);
        multiSig.confirmTransaction(1);
        vm.prank(owner2);
        multiSig.confirmTransaction(1);
        multiSig.executeTransaction(1);

        assertTrue(kycRegistry.isVerified(nonOwner));
    }

    function test_Integration_revertEarlyExecution() public {
        address timelockAddr = address(timelockController);
        address kycAddr = address(kycRegistry);

        bytes memory kycCalldata = abi.encodeCall(KYCRegistry.addUser, (nonOwner));
        bytes32 salt = keccak256("early-execute-test");

        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (kycAddr, 0, kycCalldata, bytes32(0), salt, MIN_DELAY)
        );
        multiSig.submitTransaction(timelockAddr, 0, scheduleCalldata);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        // Try execute before delay — must fail
        bytes memory executeCalldata = abi.encodeCall(
            TimelockController.execute, (kycAddr, 0, kycCalldata, bytes32(0), salt)
        );
        multiSig.submitTransaction(timelockAddr, 0, executeCalldata);
        multiSig.confirmTransaction(1);
        vm.prank(owner2);
        multiSig.confirmTransaction(1);

        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        multiSig.executeTransaction(1);
    }

    function test_Integration_cancelScheduledOperation() public {
        address timelockAddr = address(timelockController);
        address kycAddr = address(kycRegistry);

        bytes memory kycCalldata = abi.encodeCall(KYCRegistry.addUser, (nonOwner));
        bytes32 salt = keccak256("cancel-test");

        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule,
            (kycAddr, 0, kycCalldata, bytes32(0), salt, MIN_DELAY)
        );
        multiSig.submitTransaction(timelockAddr, 0, scheduleCalldata);
        multiSig.confirmTransaction(0);
        vm.prank(owner2);
        multiSig.confirmTransaction(0);
        multiSig.executeTransaction(0);

        bytes32 operationId =
            keccak256(abi.encode(kycAddr, uint256(0), kycCalldata, bytes32(0), salt));

        bytes memory cancelCalldata =
            abi.encodeCall(TimelockController.cancel, (operationId));
        multiSig.submitTransaction(timelockAddr, 0, cancelCalldata);
        multiSig.confirmTransaction(1);
        vm.prank(owner2);
        multiSig.confirmTransaction(1);
        multiSig.executeTransaction(1);

        assertFalse(timelockController.isOperationPending(operationId));
    }

    /**
     * @notice Security tests ensuring that an attacker cannot bypass the TimelockController.
     */

    function test_TimelockSecurity_attackerCannotSchedule() public {
        address[] memory proposers = new address[](1);
        proposers[0] = owner1;
        address[] memory executors = new address[](1);
        executors[0] = owner1;
        TimelockController timelock =
            new TimelockController(3600, proposers, executors, address(0));

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        timelock.schedule(attacker, 0, "", bytes32(0), keccak256("hack"), 3600);
    }

    function test_TimelockSecurity_attackerCannotExecute() public {
        address[] memory proposers = new address[](1);
        proposers[0] = owner1;
        address[] memory executors = new address[](1);
        executors[0] = owner1;
        TimelockController timelock =
            new TimelockController(3600, proposers, executors, address(0));

        address attacker = makeAddr("attacker");
        bytes memory calldata_ = abi.encodeCall(KYCRegistry.addUser, (attacker));
        bytes32 salt = keccak256("test");
        timelock.schedule(address(kycRegistry), 0, calldata_, bytes32(0), salt, 3600);

        vm.prank(attacker);
        vm.expectRevert();
        timelock.execute(address(kycRegistry), 0, calldata_, bytes32(0), salt);
    }

    function test_TimelockSecurity_attackerCannotCancel() public {
        address[] memory proposers = new address[](1);
        proposers[0] = owner1;
        address[] memory executors = new address[](1);
        executors[0] = owner1;
        TimelockController timelock =
            new TimelockController(3600, proposers, executors, address(0));

        address attacker = makeAddr("attacker");
        bytes32 salt = keccak256("cancel-test");
        timelock.schedule(owner1, 0, "", bytes32(0), salt, 3600);

        bytes32 opId = keccak256(abi.encode(owner1, uint256(0), bytes(""), bytes32(0), salt));
        vm.prank(attacker);
        vm.expectRevert();
        timelock.cancel(opId);
    }
}

/// @title OperatorDirectFlowTest
/// @notice Integration tests for the 3-tier governance architecture:
///         operator EOAs can perform day-to-day ops directly (Tier 1);
///         critical ops (upgrade, role grant) require Timelock (Tier 2).
contract OperatorDirectFlowTest is Test {
    address internal deployer;
    address internal timelock; // simulated — no real TimelockController needed
    address internal kycOperator;
    address internal registryOperator;
    address internal factoryOperator;
    address internal investor1;
    address internal investor2;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyTokenFactory internal factory;
    UpgradeableBeacon internal beacon;

    function setUp() public {
        deployer = address(this);
        timelock = makeAddr("timelock");
        kycOperator = makeAddr("kycOperator");
        registryOperator = makeAddr("registryOperator");
        factoryOperator = makeAddr("factoryOperator");
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");

        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry = KYCRegistry(
            address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ())))
        );

        PropertyRegistry regImpl = new PropertyRegistry();
        propertyRegistry = PropertyRegistry(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(PropertyRegistry.initialize, ())))
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
        propertyRegistry.grantRole(propertyRegistry.REGISTRY_ADMIN_ROLE(), address(factory));

        // Replicate DeployCore.s.sol role partitioning
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

    /**
     * @notice Tier 1 operations: EOA operators can perform routine tasks directly without delay.
     */

    function test_Tier1_kycOperator_addUserDirect() public {
        vm.prank(kycOperator);
        kycRegistry.addUser(investor1);
        assertTrue(kycRegistry.isVerified(investor1));
    }

    function test_Tier1_kycOperator_removeUserDirect() public {
        vm.prank(kycOperator);
        kycRegistry.addUser(investor1);
        vm.prank(kycOperator);
        kycRegistry.removeUser(investor1);
        assertFalse(kycRegistry.isVerified(investor1));
    }

    function test_Tier1_registryOperator_updateIPFSDirect() public {
        vm.prank(registryOperator);
        propertyRegistry.registerProperty(
            "Prop", "Jl. A", 100 ether, "ipfs://old", makeAddr("tokenA")
        );
        vm.prank(registryOperator);
        propertyRegistry.updateIPFSDocument(1, "ipfs://new");
        assertEq(propertyRegistry.getProperty(1).ipfsDocumentURI, "ipfs://new");
    }

    function test_Tier1_registryOperator_deactivateDirect() public {
        vm.prank(registryOperator);
        propertyRegistry.registerProperty(
            "Prop", "Jl. A", 100 ether, "ipfs://doc", makeAddr("tokenB")
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
                tokenOwner: timelock
            })
        );
        assertTrue(tokenAddr != address(0));
        assertEq(propertyId, 1);
        assertEq(factory.getDeployedTokenCount(), 1);
    }

    /**
     * @notice Tier 2 operations: Critical tasks are blocked at the operator level and require Timelock.
     */

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
        kycRegistry.addUser(investor1);
        assertTrue(kycRegistry.isVerified(investor1));
    }

    function test_Tier2_timelock_cannotAddUserDirectly() public {
        // Timelock has DEFAULT_ADMIN_ROLE but NOT KYC_ADMIN_ROLE
        vm.prank(timelock);
        vm.expectRevert();
        kycRegistry.addUser(investor1);
    }

    /**
     * @notice Access control checks to ensure unauthorized actors are restricted.
     */

    function test_Acl_randomActorCannotAddKYC() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        kycRegistry.addUser(investor1);
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
                tokenOwner: makeAddr("random")
            })
        );
    }
}
