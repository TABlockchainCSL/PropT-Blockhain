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

    error InvalidKYCLevel(uint8 level);
    error UserAlreadyVerified(address user);
    error UserNotVerified(address user);
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
}
