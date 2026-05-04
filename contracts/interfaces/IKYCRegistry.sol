// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IKYCRegistry
 * @notice Interface for checking user KYC status.
 *         Used by other contracts that need to validate whether a user is KYC-verified.
 */
interface IKYCRegistry {
    event UserApproved(
        address indexed user,
        uint8 kycLevel,
        address indexed approvedBy
    );
    event UserRemoved(address indexed user, address indexed removedBy);
    event KYCLevelUpdated(address indexed user, uint8 oldLevel, uint8 newLevel);
    event ContractApproved(
        address indexed contractAddr,
        address indexed approvedBy
    );
    event ContractRemoved(
        address indexed contractAddr,
        address indexed removedBy
    );

    error InvalidKYCLevel(uint8 level);
    error UserAlreadyVerified(address user);
    error UserNotVerified(address user);
    error ContractAlreadyApproved(address contractAddr);
    error ContractNotApproved(address contractAddr);
    error NotAContract(address addr);
    error ZeroAddress();
    error ArrayLengthMismatch();
    error BatchTooLarge(uint256 size, uint256 maxSize);

    /// @notice Check if a user has passed KYC
    function isVerified(address user) external view returns (bool);

    /// @notice Get KYC level (0 = none, 1 = basic, 2 = enhanced)
    function getKYCLevel(address user) external view returns (uint8);

    /// @notice Total number of verified users
    function getVerifiedUserCount() external view returns (uint256);

    /// @notice Get all verified addresses
    function getVerifiedUsers() external view returns (address[] memory);

    /// @notice Approve a contract address (e.g. DEX pool, marketplace)
    function addApprovedContract(address contractAddr) external;

    /// @notice Revoke approval for a contract address
    function removeApprovedContract(address contractAddr) external;

    /// @notice Check if a contract address is approved
    function isApprovedContract(address addr) external view returns (bool);
}
