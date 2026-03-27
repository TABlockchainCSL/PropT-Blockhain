// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

import "../contracts/dividend/DividendDistribution.sol";
import "../contracts/dividend/PropertyGovernor.sol";

/**
 * @title DeployDividend
 * @notice Deploy script for Person 2's contracts (DividendDistribution + PropertyGovernor).
 *         Reads Person 1's deployed addresses from environment variables.
 *
 * Usage:
 *   forge script script/DeployDividend.s.sol --rpc-url <RPC_URL> --broadcast
 */
contract DeployDividend is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");

        // ── Read addresses from Person 1's deployment ─────────────────
        address propertyTokenAddr = vm.envAddress("PROPERTY_TOKEN_ADDRESS");
        address kycRegistryAddr   = vm.envAddress("KYC_REGISTRY_ADDRESS");
        address timelockAddr      = vm.envAddress("TIMELOCK_ADDRESS");
        address stablecoinAddr    = vm.envAddress("STABLECOIN_ADDRESS");

        console.log("=== Deploying Person 2 Contracts ===");
        console.log("PropertyToken:", propertyTokenAddr);
        console.log("KYCRegistry:", kycRegistryAddr);
        console.log("Timelock:", timelockAddr);
        console.log("Stablecoin:", stablecoinAddr);

        vm.startBroadcast(deployerPk);

        // ── 1. Deploy DividendDistribution ────────────────────────────
        DividendDistribution dividend = new DividendDistribution(
            propertyTokenAddr,
            stablecoinAddr,
            kycRegistryAddr,
            timelockAddr  // admin = TimelockController from Person 1
        );
        console.log("DividendDistribution:", address(dividend));

        // ── 2. Deploy PropertyGovernor ────────────────────────────────
        address multisigAddr = vm.envAddress("MULTISIG_ADDRESS");
        PropertyGovernor governor = new PropertyGovernor(
            IVotes(propertyTokenAddr),
            TimelockController(payable(timelockAddr)),
            multisigAddr  // proposerAdmin = MultiSig (hanya admin yang bisa propose)
        );
        console.log("PropertyGovernor:", address(governor));
        console.log("ProposerAdmin (MultiSig):", multisigAddr);

        vm.stopBroadcast();

        // ── 3. Post-deploy instructions ──────────────────────────────
        console.log("\n=== POST-DEPLOY: Manual Steps Required ===");
        console.log("Run these via MultiSig -> Timelock:");
        console.log("1. Timelock.grantRole(PROPOSER_ROLE, governor)");
        console.log("2. DividendDistribution.grantRole(DEPOSITOR_ROLE, <spv-addr>)");
    }
}
