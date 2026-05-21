// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Lightweight KYC registry for AMM testnet deployments.
contract TestnetKYCRegistry {
    mapping(address => bool) public isVerified;
    mapping(address => bool) public isApprovedContract;

    event UserVerificationUpdated(address indexed user, bool verified);
    event ContractApprovalUpdated(address indexed account, bool approved);

    function setVerified(address user, bool verified) external {
        isVerified[user] = verified;
        emit UserVerificationUpdated(user, verified);
    }

    function setApprovedContract(address account, bool approved) external {
        isApprovedContract[account] = approved;
        emit ContractApprovalUpdated(account, approved);
    }
}
