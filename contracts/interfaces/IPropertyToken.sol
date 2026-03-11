// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "./IKYCRegistry.sol";

/**
 * @title IPropertyToken
 * @notice Interface for interacting with property tokens.
 *         Extends IERC20, IVotes (for snapshots/voting), and IERC20Permit (gasless approve).
 *
 * Example — dividend distribution:
 *   uint256 share = token.getPastVotes(user, snapshotBlock);
 *   uint256 total = token.getPastTotalSupply(snapshotBlock);
 *   uint256 payout = totalDividend * share / total;
 *
 * Example — AMM trade:
 *   token.transferFrom(seller, buyer, amount); // KYC is enforced automatically
 */
interface IPropertyToken is IERC20, IVotes, IERC20Permit {
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);

    error SenderNotKYCVerified(address sender);
    error RecipientNotKYCVerified(address recipient);
    error InsufficientKYCLevel(address user, uint8 required, uint8 actual);

    /// @notice KYCRegistry address used by this token
    function kycRegistry() external view returns (IKYCRegistry);

    /// @notice Property ID in the PropertyRegistry
    function propertyId() external view returns (uint256);

    /// @notice Minimum KYC level required to transfer (1 = Basic, 2 = Enhanced)
    function requiredKYCLevel() external view returns (uint8);

    /// @notice Mint additional tokens (owner only)
    function mint(address to, uint256 amount) external;

    /// @notice Pause all transfers
    function pause() external;

    /// @notice Resume transfers
    function unpause() external;
}
