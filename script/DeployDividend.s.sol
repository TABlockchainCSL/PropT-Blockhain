// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

import "../src/dividend/DividendDistribution.sol";
import "../src/dividend/PropertyGovernor.sol";

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
        address stablecoinAddr    = vm.envAddress("STABLECOIN_ADDRESS");

        console.log("=== Deploying Person 2 Contracts ===");
        console.log("PropertyToken:", propertyTokenAddr);
        console.log("KYCRegistry:", kycRegistryAddr);
        console.log("Stablecoin:", stablecoinAddr);

        vm.startBroadcast(deployerPk);

        // ── 1. Deploy TimelockController (Milik Modul 2) ──────────────
        address[] memory empty = new address[](0);
        TimelockController daoTimelock = new TimelockController(
            172800, // minDelay 2 hari
            empty,
            empty,
            vm.addr(deployerPk) // deployer sebagai admin sementara
        );
        console.log("DAOTimelock:", address(daoTimelock));

        // ── 2. Deploy DividendDistribution ────────────────────────────
        DividendDistribution dividend = new DividendDistribution(
            propertyTokenAddr,
            stablecoinAddr,
            kycRegistryAddr,
            vm.addr(deployerPk)  // admin sementara = deployer (agar bisa grantRole)
        );
        console.log("DividendDistribution:", address(dividend));

        // Otomatis grant DEPOSITOR_ROLE ke SPV_ADDRESS
        address spvAddr = vm.envAddress("SPV_ADDRESS");
        dividend.grantRole(dividend.DEPOSITOR_ROLE(), spvAddr);
        console.log("DepositorRole granted to SPV:", spvAddr);

        // Pindahkan hak akses admin dan depositor DividendDistribution ke DAOTimelock
        dividend.grantRole(dividend.DEFAULT_ADMIN_ROLE(), address(daoTimelock));
        dividend.grantRole(dividend.DEPOSITOR_ROLE(), address(daoTimelock));
        dividend.renounceRole(dividend.DEFAULT_ADMIN_ROLE(), vm.addr(deployerPk));
        dividend.renounceRole(dividend.DEPOSITOR_ROLE(), vm.addr(deployerPk));

        // ── 3. Deploy PropertyGovernor ────────────────────────────────
        // Menggunakan SPV_ADDRESS sebagai proposerAdmin
        PropertyGovernor governor = new PropertyGovernor(
            IVotes(propertyTokenAddr),
            daoTimelock,
            spvAddr  // proposerAdmin
        );
        console.log("PropertyGovernor:", address(governor));
        console.log("ProposerAdmin:", spvAddr);

        // Setup role untuk Governor di Timelock Modul 2
        daoTimelock.grantRole(daoTimelock.PROPOSER_ROLE(), address(governor));
        daoTimelock.grantRole(daoTimelock.EXECUTOR_ROLE(), address(governor));
        daoTimelock.grantRole(daoTimelock.CANCELLER_ROLE(), address(governor));

        // Hapus akses admin Timelock dari deployer (Timelock kini dikontrol penuh oleh Governor)
        daoTimelock.renounceRole(daoTimelock.DEFAULT_ADMIN_ROLE(), vm.addr(deployerPk));

        vm.stopBroadcast();
    }
}
