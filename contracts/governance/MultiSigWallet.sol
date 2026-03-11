// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MultiSigWallet
 * @notice Multi-signature wallet — requires `threshold` out of N owners
 *         to confirm before any transaction can be executed.
 *         Used together with TimelockController for governance.
 * @dev Flow: submit → confirm (×threshold) → execute.
 *      Owner management (add/remove/changeThreshold) is done via
 *      multisig tx to itself (onlySelf modifier).
 */
contract MultiSigWallet {
    event TransactionSubmitted(
        uint256 indexed txIndex,
        address indexed to,
        uint256 value,
        bytes data
    );
    event TransactionConfirmed(uint256 indexed txIndex, address indexed owner);
    event TransactionRevoked(uint256 indexed txIndex, address indexed owner);
    event TransactionExecuted(uint256 indexed txIndex);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);

    error NotOwner();
    error ZeroAddress();
    error DuplicateOwner(address owner);
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);
    error TxDoesNotExist(uint256 txIndex);
    error TxAlreadyExecuted(uint256 txIndex);
    error TxAlreadyConfirmed(uint256 txIndex);
    error TxNotConfirmed(uint256 txIndex);
    error InsufficientConfirmations(uint256 have, uint256 need);
    error TxExecutionFailed();
    error OwnersRequired();

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmationCount;
    }

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public threshold;

    Transaction[] public transactions;
    // txIndex => owner => confirmed
    mapping(uint256 => mapping(address => bool)) public isConfirmed;

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "Must call via multisig tx");
        _;
    }

    modifier txExists(uint256 _txIndex) {
        if (_txIndex >= transactions.length) revert TxDoesNotExist(_txIndex);
        _;
    }

    modifier notExecuted(uint256 _txIndex) {
        if (transactions[_txIndex].executed) revert TxAlreadyExecuted(_txIndex);
        _;
    }

    /// @param _owners Initial list of signer addresses
    /// @param _threshold Min confirmations needed to execute
    constructor(address[] memory _owners, uint256 _threshold) {
        if (_owners.length == 0) revert OwnersRequired();
        if (_threshold == 0 || _threshold > _owners.length) {
            revert InvalidThreshold(_threshold, _owners.length);
        }

        for (uint256 i = 0; i < _owners.length; ) {
            address owner = _owners[i];
            if (owner == address(0)) revert ZeroAddress();
            if (isOwner[owner]) revert DuplicateOwner(owner);

            isOwner[owner] = true;
            owners.push(owner);

            unchecked {
                ++i;
            }
        }

        threshold = _threshold;
    }

    /// @notice Propose a new transaction
    /// @param _to Target address
    /// @param _value ETH to send (usually 0 for contract calls)
    /// @param _data Encoded function call (abi.encodeCall)
    function submitTransaction(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyOwner returns (uint256 txIndex) {
        txIndex = transactions.length;

        transactions.push(
            Transaction({
                to: _to,
                value: _value,
                data: _data,
                executed: false,
                confirmationCount: 0
            })
        );

        emit TransactionSubmitted(txIndex, _to, _value, _data);
    }

    /// @notice Approve a pending transaction
    function confirmTransaction(
        uint256 _txIndex
    ) external onlyOwner txExists(_txIndex) notExecuted(_txIndex) {
        if (isConfirmed[_txIndex][msg.sender])
            revert TxAlreadyConfirmed(_txIndex);

        isConfirmed[_txIndex][msg.sender] = true;
        transactions[_txIndex].confirmationCount += 1;

        emit TransactionConfirmed(_txIndex, msg.sender);
    }

    /// @notice Execute after threshold confirmations reached
    function executeTransaction(
        uint256 _txIndex
    ) external onlyOwner txExists(_txIndex) notExecuted(_txIndex) {
        Transaction storage txn = transactions[_txIndex];

        if (txn.confirmationCount < threshold) {
            revert InsufficientConfirmations(txn.confirmationCount, threshold);
        }

        txn.executed = true;

        (bool success, ) = txn.to.call{value: txn.value}(txn.data);
        if (!success) revert TxExecutionFailed();

        emit TransactionExecuted(_txIndex);
    }

    /// @notice Take back a confirmation
    function revokeConfirmation(
        uint256 _txIndex
    ) external onlyOwner txExists(_txIndex) notExecuted(_txIndex) {
        if (!isConfirmed[_txIndex][msg.sender]) revert TxNotConfirmed(_txIndex);

        isConfirmed[_txIndex][msg.sender] = false;
        transactions[_txIndex].confirmationCount -= 1;

        emit TransactionRevoked(_txIndex, msg.sender);
    }

    /// @notice Add a new signer
    function addOwner(address _owner) external onlySelf {
        if (_owner == address(0)) revert ZeroAddress();
        if (isOwner[_owner]) revert DuplicateOwner(_owner);

        isOwner[_owner] = true;
        owners.push(_owner);

        emit OwnerAdded(_owner);
    }

    /// @notice Remove a signer. Threshold auto-adjusts if needed.
    function removeOwner(address _owner) external onlySelf {
        if (!isOwner[_owner]) revert NotOwner();
        if (owners.length - 1 == 0) revert OwnersRequired();

        isOwner[_owner] = false;

        // Swap and pop
        for (uint256 i = 0; i < owners.length; ) {
            if (owners[i] == _owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        // shrink threshold if it now exceeds owner count
        if (threshold > owners.length) {
            uint256 oldThreshold = threshold;
            threshold = owners.length;
            emit ThresholdChanged(oldThreshold, threshold);
        }

        emit OwnerRemoved(_owner);
    }

    /// @notice Update the confirmation threshold
    function changeThreshold(uint256 _threshold) external onlySelf {
        if (_threshold == 0 || _threshold > owners.length) {
            revert InvalidThreshold(_threshold, owners.length);
        }

        uint256 oldThreshold = threshold;
        threshold = _threshold;

        emit ThresholdChanged(oldThreshold, _threshold);
    }

    /// @notice Total submitted transactions
    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    /// @notice Transaction details by index
    function getTransaction(
        uint256 _txIndex
    )
        external
        view
        txExists(_txIndex)
        returns (
            address to,
            uint256 value,
            bytes memory data,
            bool executed,
            uint256 confirmationCount
        )
    {
        Transaction storage txn = transactions[_txIndex];
        return (
            txn.to,
            txn.value,
            txn.data,
            txn.executed,
            txn.confirmationCount
        );
    }

    /// @notice All current signers
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /// @notice Number of signers
    function getOwnerCount() external view returns (uint256) {
        return owners.length;
    }

    /// @dev Accept ETH so we can forward value if needed
    receive() external payable {}
}
