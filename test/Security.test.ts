import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import type {
    KYCRegistry,
    PropertyToken,
    PropertyRegistry,
    PropertyTokenFactory,
} from "../typechain-types";

describe("Security Testing", function () {
    let owner: HardhatEthersSigner;
    let admin: HardhatEthersSigner;
    let attacker: HardhatEthersSigner;
    let user1: HardhatEthersSigner;
    let kycRegistry: KYCRegistry;
    let propertyRegistry: PropertyRegistry;
    let factory: PropertyTokenFactory;
    let token: PropertyToken;
    let beacon: any;

    beforeEach(async function () {
        [owner, admin, attacker, user1] = await ethers.getSigners();

        const KYCRegistryFactory = await ethers.getContractFactory("KYCRegistry");
        kycRegistry = (await upgrades.deployProxy(KYCRegistryFactory, [], {
            kind: "uups",
        })) as unknown as KYCRegistry;
        await kycRegistry.waitForDeployment();

        const PropertyRegistryFactory = await ethers.getContractFactory("PropertyRegistry");
        propertyRegistry = (await upgrades.deployProxy(PropertyRegistryFactory, [], {
            kind: "uups",
        })) as unknown as PropertyRegistry;
        await propertyRegistry.waitForDeployment();

        const PropertyTokenFactory = await ethers.getContractFactory("PropertyToken");
        beacon = await upgrades.deployBeacon(PropertyTokenFactory, {
            unsafeAllow: ["constructor"],
        });
        await beacon.waitForDeployment();

        const FactoryContract = await ethers.getContractFactory("PropertyTokenFactory");
        factory = (await upgrades.deployProxy(
            FactoryContract,
            [
                await kycRegistry.getAddress(),
                await propertyRegistry.getAddress(),
                await beacon.getAddress(),
            ],
            { kind: "uups", unsafeAllow: ["constructor"] }
        )) as unknown as PropertyTokenFactory;
        await factory.waitForDeployment();

        const REGISTRY_ADMIN_ROLE = await propertyRegistry.REGISTRY_ADMIN_ROLE();
        await propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, await factory.getAddress());
        const KYC_ADMIN_ROLE = await kycRegistry.KYC_ADMIN_ROLE();
        await kycRegistry.grantRole(KYC_ADMIN_ROLE, admin.address);

        await kycRegistry.connect(admin).addUser(owner.address, 2);
        await kycRegistry.connect(admin).addUser(user1.address, 1);

        const createTx = await factory.createPropertyToken({
            name: "Test Token",
            symbol: "TST",
            totalSupply: ethers.parseEther("1000"),
            propertyName: "Test Property",
            propertyAddress: "Jl. Test No. 1",
            totalValue: ethers.parseEther("100"),
            ipfsDocumentURI: "ipfs://test",
            requiredKYCLevel: 1,
        });
        const receipt = await createTx.wait();
        const events = await factory.queryFilter(
            factory.filters.PropertyTokenCreated(),
            receipt!.blockNumber
        );
        const tokenAddress = events[0].args.tokenAddress;
        token = await ethers.getContractAt("PropertyToken", tokenAddress) as unknown as PropertyToken;
    });

    describe("Access Control Bypass", function () {
        it("attacker cannot add KYC users", async function () {
            await expect(
                kycRegistry.connect(attacker).addUser(attacker.address, 1)
            ).to.be.reverted;
        });

        it("attacker cannot batch add KYC users", async function () {
            await expect(
                kycRegistry.connect(attacker).batchAddUsers([attacker.address], [1])
            ).to.be.reverted;
        });

        it("attacker cannot remove KYC users", async function () {
            await expect(
                kycRegistry.connect(attacker).removeUser(user1.address)
            ).to.be.reverted;
        });

        it("attacker cannot register property", async function () {
            await expect(
                propertyRegistry.connect(attacker).registerProperty(
                    "Fake", "Jl. Fake", ethers.parseEther("1"), "ipfs://fake", attacker.address
                )
            ).to.be.reverted;
        });

        it("attacker cannot create token via factory", async function () {
            await expect(
                factory.connect(attacker).createPropertyToken({
                    name: "Fake",
                    symbol: "FAKE",
                    totalSupply: ethers.parseEther("100"),
                    propertyName: "Fake Property",
                    propertyAddress: "Jl. Fake No. 1",
                    totalValue: ethers.parseEther("10"),
                    ipfsDocumentURI: "ipfs://fake",
                    requiredKYCLevel: 1,
                })
            ).to.be.reverted;
        });

        it("attacker cannot mint tokens", async function () {
            await expect(
                token.connect(attacker).mint(attacker.address, ethers.parseEther("1000"))
            ).to.be.reverted;
        });

        it("attacker cannot pause token", async function () {
            await expect(token.connect(attacker).pause()).to.be.reverted;
        });

        it("attacker cannot unpause token", async function () {
            await token.pause();
            await expect(token.connect(attacker).unpause()).to.be.reverted;
        });

        it("attacker cannot grant admin role to self", async function () {
            const DEFAULT_ADMIN_ROLE = await kycRegistry.DEFAULT_ADMIN_ROLE();
            await expect(
                kycRegistry.connect(attacker).grantRole(DEFAULT_ADMIN_ROLE, attacker.address)
            ).to.be.reverted;
        });

        it("attacker cannot deactivate property", async function () {
            await expect(
                propertyRegistry.connect(attacker).deactivateProperty(1)
            ).to.be.reverted;
        });
    });

    describe("KYC Bypass", function () {
        it("non-KYC user cannot receive tokens", async function () {
            await expect(
                token.transfer(attacker.address, ethers.parseEther("10"))
            ).to.be.revertedWithCustomError(token, "RecipientNotKYCVerified");
        });

        it("transfer fails if sender KYC is revoked", async function () {
            await token.transfer(user1.address, ethers.parseEther("10"));
            await kycRegistry.connect(admin).removeUser(user1.address);

            await expect(
                token.connect(user1).transfer(owner.address, ethers.parseEther("5"))
            ).to.be.revertedWithCustomError(token, "SenderNotKYCVerified");
        });

        it("token with KYC level 2 rejects level 1 user", async function () {
            const createTx = await factory.createPropertyToken({
                name: "Premium Token",
                symbol: "PREM",
                totalSupply: ethers.parseEther("500"),
                propertyName: "Premium Property",
                propertyAddress: "Jl. Premium No. 1",
                totalValue: ethers.parseEther("200"),
                ipfsDocumentURI: "ipfs://premium",
                requiredKYCLevel: 2,
            });
            const receipt = await createTx.wait();
            const events = await factory.queryFilter(
                factory.filters.PropertyTokenCreated(),
                receipt!.blockNumber
            );
            const premiumToken = await ethers.getContractAt(
                "PropertyToken", events[0].args.tokenAddress
            ) as unknown as PropertyToken;

            await expect(
                premiumToken.transfer(user1.address, ethers.parseEther("10"))
            ).to.be.revertedWithCustomError(premiumToken, "InsufficientKYCLevel");
        });
    });

    describe("Upgrade Hijack", function () {
        it("attacker cannot upgrade KYCRegistry", async function () {
            const KYCRegistryV2 = await ethers.getContractFactory("KYCRegistry", attacker);
            await expect(
                upgrades.upgradeProxy(await kycRegistry.getAddress(), KYCRegistryV2, {
                    kind: "uups",
                })
            ).to.be.reverted;
        });

        it("attacker cannot upgrade PropertyRegistry", async function () {
            const PropertyRegistryV2 = await ethers.getContractFactory("PropertyRegistry", attacker);
            await expect(
                upgrades.upgradeProxy(await propertyRegistry.getAddress(), PropertyRegistryV2, {
                    kind: "uups",
                })
            ).to.be.reverted;
        });

        it("attacker cannot upgrade PropertyTokenFactory", async function () {
            const FactoryV2 = await ethers.getContractFactory("PropertyTokenFactory", attacker);
            await expect(
                upgrades.upgradeProxy(await factory.getAddress(), FactoryV2, {
                    kind: "uups",
                    unsafeAllow: ["constructor"],
                })
            ).to.be.reverted;
        });

        it("attacker cannot upgrade beacon", async function () {
            const FakeImpl = await ethers.getContractFactory("PropertyToken", attacker);
            const fakeImpl = await FakeImpl.deploy();
            await fakeImpl.waitForDeployment();

            await expect(
                beacon.connect(attacker).upgradeTo(await fakeImpl.getAddress())
            ).to.be.reverted;
        });
    });

    describe("Re-initialization Attack", function () {
        it("cannot re-initialize KYCRegistry", async function () {
            await expect(kycRegistry.initialize()).to.be.reverted;
        });

        it("cannot re-initialize PropertyRegistry", async function () {
            await expect(propertyRegistry.initialize()).to.be.reverted;
        });

        it("cannot re-initialize PropertyTokenFactory", async function () {
            await expect(
                factory.initialize(
                    await kycRegistry.getAddress(),
                    await propertyRegistry.getAddress(),
                    await beacon.getAddress()
                )
            ).to.be.reverted;
        });

        it("cannot re-initialize PropertyToken", async function () {
            await expect(
                token.initialize(
                    "Hack", "HACK", ethers.parseEther("100"), 99,
                    await kycRegistry.getAddress(), 1, attacker.address
                )
            ).to.be.reverted;
        });
    });

    describe("Storage Collision on Upgrade", function () {
        it("KYCRegistry preserves data after upgrade", async function () {
            const userCount = await kycRegistry.getVerifiedUserCount();
            const isVerified = await kycRegistry.isVerified(user1.address);

            const KYCRegistryV2 = await ethers.getContractFactory("KYCRegistry");
            const upgraded = await upgrades.upgradeProxy(
                await kycRegistry.getAddress(), KYCRegistryV2, { kind: "uups" }
            );

            expect(await upgraded.getVerifiedUserCount()).to.equal(userCount);
            expect(await upgraded.isVerified(user1.address)).to.equal(isVerified);
        });

        it("PropertyRegistry preserves data after upgrade", async function () {
            const count = await propertyRegistry.getPropertyCount();

            const PropertyRegistryV2 = await ethers.getContractFactory("PropertyRegistry");
            const upgraded = await upgrades.upgradeProxy(
                await propertyRegistry.getAddress(), PropertyRegistryV2, { kind: "uups" }
            );

            expect(await upgraded.getPropertyCount()).to.equal(count);
        });
    });

    describe("Emergency Pause", function () {
        it("paused token blocks all transfers", async function () {
            await token.pause();
            await expect(
                token.transfer(user1.address, ethers.parseEther("10"))
            ).to.be.reverted;
        });

        it("paused token blocks minting", async function () {
            await token.pause();
            await expect(
                token.mint(owner.address, ethers.parseEther("100"))
            ).to.be.reverted;
        });

        it("unpausing restores transfers", async function () {
            await token.pause();
            await token.unpause();

            await expect(
                token.transfer(user1.address, ethers.parseEther("10"))
            ).to.not.be.reverted;
        });
    });

    describe("MultiSig Security", function () {
        let multiSig: any;

        beforeEach(async function () {
            const MultiSigFactory = await ethers.getContractFactory("MultiSigWallet");
            multiSig = await MultiSigFactory.deploy(
                [owner.address, admin.address, user1.address], 2
            );
            await multiSig.waitForDeployment();
        });

        it("non-owner cannot submit transaction", async function () {
            await expect(
                multiSig.connect(attacker).submitTransaction(attacker.address, 0, "0x")
            ).to.be.revertedWithCustomError(multiSig, "NotOwner");
        });

        it("non-owner cannot confirm transaction", async function () {
            await multiSig.submitTransaction(owner.address, 0, "0x");
            await expect(
                multiSig.connect(attacker).confirmTransaction(0)
            ).to.be.revertedWithCustomError(multiSig, "NotOwner");
        });

        it("cannot execute below threshold", async function () {
            await multiSig.submitTransaction(owner.address, 0, "0x");
            await multiSig.connect(owner).confirmTransaction(0);

            await expect(
                multiSig.executeTransaction(0)
            ).to.be.revertedWithCustomError(multiSig, "InsufficientConfirmations");
        });

        it("cannot directly call owner management functions", async function () {
            await expect(
                multiSig.addOwner(attacker.address)
            ).to.be.revertedWith("Must call via multisig tx");

            await expect(
                multiSig.removeOwner(owner.address)
            ).to.be.revertedWith("Must call via multisig tx");

            await expect(
                multiSig.changeThreshold(1)
            ).to.be.revertedWith("Must call via multisig tx");
        });
    });

    describe("Timelock Security", function () {
        let timelock: any;

        beforeEach(async function () {
            const TimelockFactory = await ethers.getContractFactory("TimelockController");
            timelock = await TimelockFactory.deploy(
                3600, [owner.address], [owner.address], ethers.ZeroAddress
            );
            await timelock.waitForDeployment();
        });

        it("attacker cannot schedule operations", async function () {
            await expect(
                timelock.connect(attacker).schedule(
                    attacker.address, 0, "0x", ethers.ZeroHash, ethers.id("hack"), 3600
                )
            ).to.be.reverted;
        });

        it("attacker cannot execute operations", async function () {
            const calldata = kycRegistry.interface.encodeFunctionData("addUser", [attacker.address, 1]);
            const salt = ethers.id("test");
            await timelock.schedule(
                await kycRegistry.getAddress(), 0, calldata, ethers.ZeroHash, salt, 3600
            );

            await expect(
                timelock.connect(attacker).execute(
                    await kycRegistry.getAddress(), 0, calldata, ethers.ZeroHash, salt
                )
            ).to.be.reverted;
        });

        it("attacker cannot cancel operations", async function () {
            const salt = ethers.id("cancel-test");
            await timelock.schedule(
                owner.address, 0, "0x", ethers.ZeroHash, salt, 3600
            );

            const opId = ethers.keccak256(
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint256", "bytes", "bytes32", "bytes32"],
                    [owner.address, 0, "0x", ethers.ZeroHash, salt]
                )
            );

            await expect(
                timelock.connect(attacker).cancel(opId)
            ).to.be.reverted;
        });
    });
});
