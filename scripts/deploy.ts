import { ethers, upgrades, network, run } from "hardhat";
import fs from "fs";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    // 1. Core contracts (proxied)
    const KYCRegistry = await ethers.getContractFactory("KYCRegistry");
    const kycRegistry = await upgrades.deployProxy(KYCRegistry, [], { kind: "uups" });
    await kycRegistry.waitForDeployment();
    console.log("KYCRegistry:", await kycRegistry.getAddress());

    const PropertyRegistry = await ethers.getContractFactory("PropertyRegistry");
    const propertyRegistry = await upgrades.deployProxy(PropertyRegistry, [], { kind: "uups" });
    await propertyRegistry.waitForDeployment();
    console.log("PropertyRegistry:", await propertyRegistry.getAddress());

    const PropertyToken = await ethers.getContractFactory("PropertyToken");
    const beacon = await upgrades.deployBeacon(PropertyToken, {
        unsafeAllow: ["constructor"],
    });
    await beacon.waitForDeployment();
    console.log("PropertyToken Beacon:", await beacon.getAddress());

    const PropertyTokenFactory = await ethers.getContractFactory("PropertyTokenFactory");
    const factory = await upgrades.deployProxy(
        PropertyTokenFactory,
        [await kycRegistry.getAddress(), await propertyRegistry.getAddress(), await beacon.getAddress()],
        { kind: "uups", unsafeAllow: ["constructor"] }
    );
    await factory.waitForDeployment();
    console.log("PropertyTokenFactory:", await factory.getAddress());

    // 2. Grant factory the right to register properties
    const REGISTRY_ADMIN_ROLE = await propertyRegistry.REGISTRY_ADMIN_ROLE();
    await (await propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, await factory.getAddress())).wait();

    // 3. Governance
    const multisigOwners = [deployer.address]; // production: tambah signer lain
    const threshold = 1; // production: minimal 2-of-3
    if (network.name === "mainnet" && threshold < 2) {
        throw new Error("Threshold terlalu rendah untuk mainnet!");
    }

    const MultiSigWallet = await ethers.getContractFactory("MultiSigWallet");
    const multiSig = await MultiSigWallet.deploy(multisigOwners, threshold);
    await multiSig.waitForDeployment();
    const multiSigAddress = await multiSig.getAddress();
    console.log("MultiSigWallet:", multiSigAddress);

    const MIN_DELAY = 172800; // 48 jam
    const TimelockController = await ethers.getContractFactory("TimelockController");
    const timelock = await TimelockController.deploy(
        MIN_DELAY,
        [multiSigAddress], // proposers
        [multiSigAddress], // executors
        ethers.ZeroAddress  // self-administered
    );
    await timelock.waitForDeployment();
    const timelockAddress = await timelock.getAddress();
    console.log("TimelockController:", timelockAddress);

    // 4. Transfer semua admin roles ke timelock, lalu renounce deployer
    const DEFAULT_ADMIN_ROLE = await kycRegistry.DEFAULT_ADMIN_ROLE();
    const KYC_ADMIN_ROLE = await kycRegistry.KYC_ADMIN_ROLE();

    await (await kycRegistry.grantRole(DEFAULT_ADMIN_ROLE, timelockAddress)).wait();
    await (await kycRegistry.grantRole(KYC_ADMIN_ROLE, timelockAddress)).wait();
    await (await kycRegistry.renounceRole(KYC_ADMIN_ROLE, deployer.address)).wait();
    await (await kycRegistry.renounceRole(DEFAULT_ADMIN_ROLE, deployer.address)).wait();

    await (await propertyRegistry.grantRole(DEFAULT_ADMIN_ROLE, timelockAddress)).wait();
    await (await propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, timelockAddress)).wait();
    await (await propertyRegistry.renounceRole(REGISTRY_ADMIN_ROLE, deployer.address)).wait();
    await (await propertyRegistry.renounceRole(DEFAULT_ADMIN_ROLE, deployer.address)).wait();

    await (await factory.transferOwnership(timelockAddress)).wait();

    const beaconContract = await ethers.getContractAt("UpgradeableBeacon", await beacon.getAddress());
    await (await beaconContract.transferOwnership(timelockAddress)).wait();

    console.log("\nAll admin roles transferred to TimelockController.");
    console.log("Operations now require: MultiSig -> Timelock -> Contract");

    // 5. Save deployment addresses
    const deployments = {
        network: network.name,
        deployer: deployer.address,
        contracts: {
            KYCRegistry: await kycRegistry.getAddress(),
            PropertyRegistry: await propertyRegistry.getAddress(),
            PropertyTokenBeacon: await beacon.getAddress(),
            PropertyTokenFactory: await factory.getAddress(),
            MultiSigWallet: multiSigAddress,
            TimelockController: timelockAddress,
        },
        governance: {
            timelockDelay: MIN_DELAY,
            multisigThreshold: threshold,
            multisigOwners: multisigOwners,
        },
    };

    const filename = `deployments-${network.name}.json`;
    fs.writeFileSync(filename, JSON.stringify(deployments, null, 2));
    console.log(`\nDeployment addresses saved to ${filename}`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
