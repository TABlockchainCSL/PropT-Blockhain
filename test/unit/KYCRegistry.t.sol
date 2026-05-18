// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../contracts/core/KYCRegistry.sol";
import "../../contracts/interfaces/IKYCRegistry.sol";

/// @title KYCRegistryTest
/// @notice Unit tests for KYCRegistry: happy path, negative path, edge case,
///         upgradeability, and access-control security tests.
contract KYCRegistryTest is Test {
    address internal owner;
    address internal attacker;
    address internal user1;
    address internal user2;
    address internal user3;

    KYCRegistry internal kycRegistry;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy =
            new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        kycRegistry = KYCRegistry(address(kycProxy));
    }

    /**
     * @notice addUser — happy path
     */

    function test_KYC_addUser() public {
        vm.expectEmit(true, true, false, true);
        emit IKYCRegistry.UserApproved(user1, owner);
        kycRegistry.addUser(user1);
        assertTrue(kycRegistry.isVerified(user1));
    }

    function test_KYC_getVerifiedUsers() public {
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);
        address[] memory users = kycRegistry.getVerifiedUsers();
        assertEq(users.length, 2);
    }

    /**
     * @notice addUser — negative path
     */

    function test_KYC_addUser_revertAlreadyVerified() public {
        kycRegistry.addUser(user1);
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.UserAlreadyVerified.selector, user1));
        kycRegistry.addUser(user1);
    }

    function test_KYC_addUser_revertZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.ZeroAddress.selector));
        kycRegistry.addUser(address(0));
    }

    function test_KYC_addUser_revertNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        kycRegistry.addUser(user2);
    }

    /**
     * @notice removeUser — happy path
     */

    function test_KYC_removeUser() public {
        kycRegistry.addUser(user1);
        vm.expectEmit(true, true, false, true);
        emit IKYCRegistry.UserRemoved(user1, owner);
        kycRegistry.removeUser(user1);
        assertFalse(kycRegistry.isVerified(user1));
    }

    function test_KYC_removeUser_decreasesCount() public {
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);
        assertEq(kycRegistry.getVerifiedUserCount(), 2);
        kycRegistry.removeUser(user1);
        assertEq(kycRegistry.getVerifiedUserCount(), 1);
    }

    /**
     * @notice removeUser — negative path
     */

    function test_KYC_removeUser_revertNotVerified() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.UserNotVerified.selector, user2));
        kycRegistry.removeUser(user2);
    }

    function test_KYC_removeUser_revertZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.ZeroAddress.selector));
        kycRegistry.removeUser(address(0));
    }

    /**
     * @notice removeUser — edge case: swap-and-pop paths
     */

    function test_KYC_removeUser_lastElement() public {
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);
        // Remove user2 (last element) → only pop, no swap
        kycRegistry.removeUser(user2);
        assertFalse(kycRegistry.isVerified(user2));
        assertTrue(kycRegistry.isVerified(user1));
        assertEq(kycRegistry.getVerifiedUserCount(), 1);
        kycRegistry.removeUser(user1);
        assertEq(kycRegistry.getVerifiedUserCount(), 0);
    }

    function test_KYC_removeUser_nonLastElement_swapAndPop() public {
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);
        kycRegistry.addUser(user3);
        // Remove user1 (first) → user3 swapped into its slot
        kycRegistry.removeUser(user1);
        assertFalse(kycRegistry.isVerified(user1));
        assertTrue(kycRegistry.isVerified(user2));
        assertTrue(kycRegistry.isVerified(user3));
        assertEq(kycRegistry.getVerifiedUserCount(), 2);
        kycRegistry.removeUser(user3);
        kycRegistry.removeUser(user2);
        assertEq(kycRegistry.getVerifiedUserCount(), 0);
    }

    /**
     * @notice addApprovedContract / removeApprovedContract
     */

    function test_KYC_addApprovedContract_revertEOA() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.NotAContract.selector, user1));
        kycRegistry.addApprovedContract(user1);
    }

    function test_KYC_addApprovedContract_revertDuplicate() public {
        address contractAddr = address(kycRegistry); // has code
        kycRegistry.addApprovedContract(contractAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IKYCRegistry.ContractAlreadyApproved.selector, contractAddr)
        );
        kycRegistry.addApprovedContract(contractAddr);
    }

    function test_KYC_addApprovedContract_revertNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        kycRegistry.addApprovedContract(address(kycRegistry));
    }

    function test_KYC_removeApprovedContract() public {
        address contractAddr = address(kycRegistry);
        kycRegistry.addApprovedContract(contractAddr);
        assertTrue(kycRegistry.isApprovedContract(contractAddr));
        kycRegistry.removeApprovedContract(contractAddr);
        assertFalse(kycRegistry.isApprovedContract(contractAddr));
    }

    function test_KYC_removeApprovedContract_revertNotApproved() public {
        vm.expectRevert(
            abi.encodeWithSelector(IKYCRegistry.ContractNotApproved.selector, address(kycRegistry))
        );
        kycRegistry.removeApprovedContract(address(kycRegistry));
    }

    function test_KYC_removeApprovedContract_revertZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IKYCRegistry.ZeroAddress.selector));
        kycRegistry.removeApprovedContract(address(0));
    }

    /**
     * @notice Upgradeability
     */

    function test_KYC_upgrade_preservesState() public {
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);

        KYCRegistry kycV2 = new KYCRegistry();
        kycRegistry.upgradeToAndCall(address(kycV2), "");

        assertTrue(kycRegistry.isVerified(user1));
        assertTrue(kycRegistry.isVerified(user2));
        assertEq(kycRegistry.getVerifiedUserCount(), 2);
    }

    function test_KYC_upgrade_revertNonAdmin() public {
        KYCRegistry kycV2 = new KYCRegistry();
        vm.prank(attacker);
        vm.expectRevert();
        kycRegistry.upgradeToAndCall(address(kycV2), "");
    }

    function test_KYC_reInit_reverts() public {
        vm.expectRevert();
        kycRegistry.initialize();
    }

    /**
     * @notice Security: ACL negative path
     */

    function test_ACL_attackerCannotGrantAdminRole() public {
        bytes32 DEFAULT_ADMIN_ROLE = kycRegistry.DEFAULT_ADMIN_ROLE();
        vm.prank(attacker);
        vm.expectRevert();
        kycRegistry.grantRole(DEFAULT_ADMIN_ROLE, attacker);
    }

    function test_UpgradeHijack_attackerCannotUpgradeKYCRegistry() public {
        KYCRegistry kycV2 = new KYCRegistry();
        vm.prank(attacker);
        vm.expectRevert();
        kycRegistry.upgradeToAndCall(address(kycV2), "");
    }
}
