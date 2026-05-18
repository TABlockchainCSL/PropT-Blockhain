// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../../src/governance-upgrade/MultiSigWallet.sol";

/// @title MultiSigWalletTest
/// @notice Unit tests for MultiSigWallet: deployment, submit, confirm, execute,
///         revoke, owner management, self-governance, and security paths.
contract MultiSigWalletTest is Test {
    address internal owner1;
    address internal owner2;
    address internal owner3;
    address internal nonOwner;

    MultiSigWallet internal multiSig;

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

    // --- Helpers ---

    function _deployMs(uint256 threshold) internal returns (MultiSigWallet ms) {
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;
        ms = new MultiSigWallet(owners, threshold);
    }

    /**
     * @notice Deployment — happy path
     */

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

    /**
     * @notice Deployment — negative path
     */

    function test_Deployment_revertZeroThreshold() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.InvalidThreshold.selector, 0, 1)
        );
        new MultiSigWallet(owners, 0);
    }

    function test_Deployment_revertThresholdTooHigh() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.InvalidThreshold.selector, 2, 1)
        );
        new MultiSigWallet(owners, 2);
    }

    function test_Deployment_revertEmptyOwners() public {
        address[] memory owners = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.OwnersRequired.selector));
        new MultiSigWallet(owners, 1);
    }

    function test_Deployment_revertDuplicateOwners() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner1;
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.DuplicateOwner.selector, owner1)
        );
        new MultiSigWallet(owners, 1);
    }

    function test_Deployment_revertZeroAddressOwner() public {
        address[] memory owners = new address[](1);
        owners[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.ZeroAddress.selector));
        new MultiSigWallet(owners, 1);
    }

    /**
     * @notice submitTransaction
     */

    function test_Submit_transaction() public {
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (3));
        vm.expectEmit(true, true, false, true);
        emit MultiSigWallet.TransactionSubmitted(0, address(multiSig), 0, data);
        multiSig.submitTransaction(address(multiSig), 0, data);
        assertEq(multiSig.getTransactionCount(), 1);
    }

    function test_Submit_revertNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector));
        multiSig.submitTransaction(owner1, 0, "");
    }

    /**
     * @notice confirmTransaction
     */

    function test_Confirm_transaction() public {
        multiSig.submitTransaction(owner1, 0, "");
        vm.expectEmit(true, true, false, true);
        emit MultiSigWallet.TransactionConfirmed(0, owner1);
        multiSig.confirmTransaction(0);
        (,,, bool executed, uint256 confirmCount) = multiSig.getTransaction(0);
        assertEq(confirmCount, 1);
        assertFalse(executed);
    }

    function test_Confirm_revertDoubleConfirm() public {
        multiSig.submitTransaction(owner1, 0, "");
        multiSig.confirmTransaction(0);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyConfirmed.selector, 0));
        multiSig.confirmTransaction(0);
    }

    function test_Confirm_revertNonExistentTx() public {
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxDoesNotExist.selector, 999));
        multiSig.confirmTransaction(999);
    }

    function test_MultiSig_confirmNonExistentTx_reverts() public {
        vm.expectRevert();
        multiSig.confirmTransaction(999);
    }

    /**
     * @notice executeTransaction
     */

    function test_Execute_afterThreshold() public {
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (3));
        multiSig.submitTransaction(address(multiSig), 0, data);
        multiSig.confirmTransaction(0);
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
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.InsufficientConfirmations.selector, 1, 2)
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

        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyExecuted.selector, 0));
        multiSig.executeTransaction(0);
    }

    function test_MultiSig_executionFailed_reverts() public {
        MultiSigWallet ms = _deployMs(1);
        uint256 txId = ms.submitTransaction(address(0x9), 0, hex"cafebabe");
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    function test_MultiSig_revertDoubleExecution() public {
        MultiSigWallet ms = _deployMs(1);
        uint256 txId = ms.submitTransaction(nonOwner, 0, "");
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyExecuted.selector, txId));
        ms.executeTransaction(txId);
    }

    function test_MultiSig_executeTransaction_revertNonOwner() public {
        MultiSigWallet ms = _deployMs(1);
        uint256 txId = ms.submitTransaction(nonOwner, 0, "");
        ms.confirmTransaction(txId);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector));
        ms.executeTransaction(txId);
    }

    /**
     * @notice revokeConfirmation
     */

    function test_Revoke_confirmation() public {
        multiSig.submitTransaction(owner1, 0, "");
        multiSig.confirmTransaction(0);
        vm.expectEmit(true, true, false, true);
        emit MultiSigWallet.TransactionRevoked(0, owner1);
        multiSig.revokeConfirmation(0);
        (,,,, uint256 confirmCount) = multiSig.getTransaction(0);
        assertEq(confirmCount, 0);
    }

    function test_Revoke_revertNotConfirmed() public {
        multiSig.submitTransaction(owner1, 0, "");
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxNotConfirmed.selector, 0));
        multiSig.revokeConfirmation(0);
    }

    function test_MultiSig_revertRevokeAfterExecution() public {
        MultiSigWallet ms = _deployMs(1);
        uint256 txId = ms.submitTransaction(nonOwner, 0, "");
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxAlreadyExecuted.selector, txId));
        ms.revokeConfirmation(txId);
    }

    function test_MultiSig_revoke_revertNotConfirmed() public {
        MultiSigWallet ms = _deployMs(2);
        uint256 txId = ms.submitTransaction(nonOwner, 0, "");
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxNotConfirmed.selector, txId));
        ms.revokeConfirmation(txId);
    }

    /**
     * @notice Owner management — self-call governance
     */

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
        bytes memory data = abi.encodeCall(MultiSigWallet.removeOwner, (owner3));
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

    function test_MultiSig_selfCall_changeThreshold() public {
        MultiSigWallet ms = _deployMs(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (1));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);
        assertEq(ms.threshold(), 1);
    }

    function test_MultiSig_selfCall_addOwner() public {
        MultiSigWallet ms = _deployMs(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.addOwner, (nonOwner));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);
        assertTrue(ms.isOwner(nonOwner));
        assertEq(ms.getOwnerCount(), 4);
    }

    function test_MultiSig_selfCall_removeOwner() public {
        MultiSigWallet ms = _deployMs(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.removeOwner, (owner3));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);
        assertFalse(ms.isOwner(owner3));
        assertEq(ms.getOwnerCount(), 2);
    }

    /**
     * @notice Self-call edge cases
     */

    function test_MultiSig_addOwner_revertZeroAddress() public {
        MultiSigWallet ms = _deployMs(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.addOwner, (address(0)));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    function test_MultiSig_addOwner_revertDuplicate() public {
        MultiSigWallet ms = _deployMs(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.addOwner, (owner2));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    function test_MultiSig_removeOwner_shrinksThreshold() public {
        address[] memory own = new address[](3);
        own[0] = owner1;
        own[1] = owner2;
        own[2] = owner3;
        MultiSigWallet ms = new MultiSigWallet(own, 3);

        bytes memory data = abi.encodeCall(MultiSigWallet.removeOwner, (owner3));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        vm.prank(owner3);
        ms.confirmTransaction(txId);
        ms.executeTransaction(txId);

        assertEq(ms.getOwnerCount(), 2);
        assertEq(ms.threshold(), 2);
    }

    function test_MultiSig_changeThreshold_revertInvalid() public {
        MultiSigWallet ms = _deployMs(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.changeThreshold, (99));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    function test_MultiSig_removeOwner_revertNotOwner() public {
        MultiSigWallet ms = _deployMs(2);
        bytes memory data = abi.encodeCall(MultiSigWallet.removeOwner, (nonOwner));
        uint256 txId = ms.submitTransaction(address(ms), 0, data);
        ms.confirmTransaction(txId);
        vm.prank(owner2);
        ms.confirmTransaction(txId);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.TxExecutionFailed.selector));
        ms.executeTransaction(txId);
    }

    /**
     * @notice Security: attacker cannot use multisig
     */

    function test_MultiSigSecurity_nonOwnerCannotSubmit() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector));
        multiSig.submitTransaction(nonOwner, 0, "");
    }

    function test_MultiSigSecurity_nonOwnerCannotConfirm() public {
        multiSig.submitTransaction(owner1, 0, "");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotOwner.selector));
        multiSig.confirmTransaction(0);
    }

    function test_MultiSigSecurity_cannotExecuteBelowThreshold() public {
        multiSig.submitTransaction(owner1, 0, "");
        multiSig.confirmTransaction(0);
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet.InsufficientConfirmations.selector, 1, 2)
        );
        multiSig.executeTransaction(0);
    }

    function test_MultiSigSecurity_cannotDirectCallOwnerMgmt() public {
        vm.expectRevert("Must call via multisig tx");
        multiSig.addOwner(nonOwner);

        vm.expectRevert("Must call via multisig tx");
        multiSig.removeOwner(owner1);

        vm.expectRevert("Must call via multisig tx");
        multiSig.changeThreshold(1);
    }
}
