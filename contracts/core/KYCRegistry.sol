// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IKYCRegistry.sol";

/**
 * @title KYCRegistry
 * @notice Stores KYC verification status for users on-chain.
 *         The actual KYC process happens off-chain (e.g. SumSub, Synaps),
 *         then admins whitelist addresses that passed here.
 * @dev Upgradeable via UUPS proxy pattern.
 */
contract KYCRegistry is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IKYCRegistry
{
    bytes32 public constant KYC_ADMIN_ROLE = keccak256("KYC_ADMIN_ROLE");

    // Available KYC levels
    uint8 public constant KYC_LEVEL_NONE = 0; // not verified
    uint8 public constant KYC_LEVEL_BASIC = 1; // basic identity check
    uint8 public constant KYC_LEVEL_ENHANCED = 2; // extended due diligence

    // Max users per batch to avoid hitting block gas limit
    uint256 public constant MAX_BATCH_SIZE = 100;

    mapping(address => uint8) private _kycLevel;
    mapping(address => bool) private _isVerified;

    // Keep track of all verified addresses
    address[] private _verifiedAddresses;
    mapping(address => uint256) private _verifiedIndex; // 1-indexed, 0 means not in the array

    // Approved contract addresses (DEX pools, marketplaces, etc.)
    mapping(address => bool) private _approvedContracts;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (replaces constructor for proxies)
    function initialize() external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KYC_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Approve a user and set their KYC level.
     * @param user Wallet address
     * @param kycLevel 1 = Basic, 2 = Enhanced
     */
    function addUser(
        address user,
        uint8 kycLevel
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (kycLevel == KYC_LEVEL_NONE || kycLevel > KYC_LEVEL_ENHANCED) {
            revert InvalidKYCLevel(kycLevel);
        }
        if (_isVerified[user]) revert UserAlreadyVerified(user);

        _isVerified[user] = true;
        _kycLevel[user] = kycLevel;

        _verifiedAddresses.push(user);
        _verifiedIndex[user] = _verifiedAddresses.length;

        emit UserApproved(user, kycLevel, msg.sender);
    }

    /**
     * @notice Revoke a user's KYC status.
     * @param user Wallet address
     */
    function removeUser(address user) external onlyRole(KYC_ADMIN_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (!_isVerified[user]) revert UserNotVerified(user);

        _isVerified[user] = false;
        _kycLevel[user] = KYC_LEVEL_NONE;

        // Remove from array using swap-and-pop to save gas
        uint256 idx = _verifiedIndex[user];
        if (idx > 0) {
            uint256 lastIdx = _verifiedAddresses.length;
            if (idx != lastIdx) {
                address lastUser = _verifiedAddresses[lastIdx - 1];
                _verifiedAddresses[idx - 1] = lastUser;
                _verifiedIndex[lastUser] = idx;
            }
            _verifiedAddresses.pop();
            _verifiedIndex[user] = 0;
        }

        emit UserRemoved(user, msg.sender);
    }

    /**
     * @notice Approve multiple users at once (max 100 per call).
     * @param users List of wallet addresses
     * @param kycLevels Corresponding KYC level for each user
     */
    function batchAddUsers(
        address[] calldata users,
        uint8[] calldata kycLevels
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (users.length != kycLevels.length) revert ArrayLengthMismatch();
        if (users.length > MAX_BATCH_SIZE)
            revert BatchTooLarge(users.length, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < users.length; ) {
            address user = users[i];
            uint8 kycLevel = kycLevels[i];

            if (user == address(0)) revert ZeroAddress();
            if (kycLevel == KYC_LEVEL_NONE || kycLevel > KYC_LEVEL_ENHANCED) {
                revert InvalidKYCLevel(kycLevel);
            }
            if (_isVerified[user]) revert UserAlreadyVerified(user);

            _isVerified[user] = true;
            _kycLevel[user] = kycLevel;

            _verifiedAddresses.push(user);
            _verifiedIndex[user] = _verifiedAddresses.length;

            emit UserApproved(user, kycLevel, msg.sender);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Change the KYC level of an already verified user.
     * @param user Wallet address
     * @param newLevel New KYC level (1 or 2)
     */
    function updateKYCLevel(
        address user,
        uint8 newLevel
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (!_isVerified[user]) revert UserNotVerified(user);
        if (newLevel == KYC_LEVEL_NONE || newLevel > KYC_LEVEL_ENHANCED) {
            revert InvalidKYCLevel(newLevel);
        }

        uint8 oldLevel = _kycLevel[user];
        _kycLevel[user] = newLevel;

        emit KYCLevelUpdated(user, oldLevel, newLevel);
    }

    /// @notice Check if a user has passed KYC
    function isVerified(address user) external view returns (bool) {
        return _isVerified[user];
    }

    /// @notice Get a user's KYC level (0 = none, 1 = basic, 2 = enhanced)
    function getKYCLevel(address user) external view returns (uint8) {
        return _kycLevel[user];
    }

    /// @notice Total number of verified users
    function getVerifiedUserCount() external view returns (uint256) {
        return _verifiedAddresses.length;
    }

    /// @notice Get all verified addresses. Be careful if the list is large.
    function getVerifiedUsers() external view returns (address[] memory) {
        return _verifiedAddresses;
    }

    // --- Approved Contracts (DEX, marketplace, etc.) ---

    /**
     * @notice Approve a contract address for token transfers.
     *         Used for DEX pools, marketplaces, and other smart contracts
     *         that need to hold/transfer tokens but cannot undergo KYC
     *         (they are not natural or legal persons).
     * @param contractAddr Address of the contract to approve
     */
    function addApprovedContract(
        address contractAddr
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (contractAddr == address(0)) revert ZeroAddress();
        if (contractAddr.code.length == 0) revert NotAContract(contractAddr);
        if (_approvedContracts[contractAddr])
            revert ContractAlreadyApproved(contractAddr);

        _approvedContracts[contractAddr] = true;

        emit ContractApproved(contractAddr, msg.sender);
    }

    /**
     * @notice Revoke approval for a contract address.
     * @param contractAddr Address of the contract to revoke
     */
    function removeApprovedContract(
        address contractAddr
    ) external onlyRole(KYC_ADMIN_ROLE) {
        if (contractAddr == address(0)) revert ZeroAddress();
        if (!_approvedContracts[contractAddr])
            revert ContractNotApproved(contractAddr);

        _approvedContracts[contractAddr] = false;

        emit ContractRemoved(contractAddr, msg.sender);
    }

    /// @notice Check if a contract address is approved
    function isApprovedContract(address addr) external view returns (bool) {
        return _approvedContracts[addr];
    }

    /// @dev Only DEFAULT_ADMIN_ROLE can authorize upgrades
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev Reserved storage gap for future upgrades
    uint256[44] private __gap;
}

