// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Force Hardhat to compile TimelockController so the artifact is available
// for deployment in tests and scripts. No custom logic needed — we use
// OpenZeppelin's implementation as-is.
import "@openzeppelin/contracts/governance/TimelockController.sol";
