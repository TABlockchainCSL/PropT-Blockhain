import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import type { MultiSigWallet } from "../typechain-types";

describe("Governance", function () {
    let owner1: HardhatEthersSigner;
    let owner2: HardhatEthersSigner;
    let owner3: HardhatEthersSigner;
    let nonOwner: HardhatEthersSigner;
    let multiSig: MultiSigWallet;

    const THRESHOLD = 2; // 2-of-3

    beforeEach(async function () {
        [owner1, owner2, owner3, nonOwner] = await ethers.getSigners();

        const MultiSigFactory = await ethers.getContractFactory("MultiSigWallet");
        multiSig = (await MultiSigFactory.deploy(
            [owner1.address, owner2.address, owner3.address],
            THRESHOLD
        )) as unknown as MultiSigWallet;
        await multiSig.waitForDeployment();
    });

    // ══════════════════════════════════════════════════════════════
    // MultiSigWallet Tests
    // ══════════════════════════════════════════════════════════════
    describe("MultiSigWallet", function () {
        describe("Deployment", function () {
            it("should set correct owners", async function () {
                const owners = await multiSig.getOwners();
                expect(owners.length).to.equal(3);
                expect(owners).to.include(owner1.address);
                expect(owners).to.include(owner2.address);
                expect(owners).to.include(owner3.address);
            });

            it("should set correct threshold", async function () {
                expect(await multiSig.threshold()).to.equal(THRESHOLD);
            });

            it("should revert on zero threshold", async function () {
                const Factory = await ethers.getContractFactory("MultiSigWallet");
                await expect(
                    Factory.deploy([owner1.address], 0)
                ).to.be.revertedWithCustomError(multiSig, "InvalidThreshold");
            });

            it("should revert on threshold > owners", async function () {
                const Factory = await ethers.getContractFactory("MultiSigWallet");
                await expect(
                    Factory.deploy([owner1.address], 2)
                ).to.be.revertedWithCustomError(multiSig, "InvalidThreshold");
            });

            it("should revert on empty owners", async function () {
                const Factory = await ethers.getContractFactory("MultiSigWallet");
                await expect(
                    Factory.deploy([], 1)
                ).to.be.revertedWithCustomError(multiSig, "OwnersRequired");
            });

            it("should revert on duplicate owners", async function () {
                const Factory = await ethers.getContractFactory("MultiSigWallet");
                await expect(
                    Factory.deploy([owner1.address, owner1.address], 1)
                ).to.be.revertedWithCustomError(multiSig, "DuplicateOwner");
            });

            it("should revert on zero address owner", async function () {
                const Factory = await ethers.getContractFactory("MultiSigWallet");
                await expect(
                    Factory.deploy([ethers.ZeroAddress], 1)
                ).to.be.revertedWithCustomError(multiSig, "ZeroAddress");
            });
        });

        describe("submitTransaction", function () {
            it("should submit a transaction", async function () {
                const data = multiSig.interface.encodeFunctionData("changeThreshold", [3]);
                await expect(
                    multiSig.submitTransaction(await multiSig.getAddress(), 0, data)
                )
                    .to.emit(multiSig, "TransactionSubmitted")
                    .withArgs(0, await multiSig.getAddress(), 0, data);

                expect(await multiSig.getTransactionCount()).to.equal(1);
            });

            it("should revert if called by non-owner", async function () {
                await expect(
                    multiSig.connect(nonOwner).submitTransaction(owner1.address, 0, "0x")
                ).to.be.revertedWithCustomError(multiSig, "NotOwner");
            });
        });

        describe("confirmTransaction", function () {
            beforeEach(async function () {
                await multiSig.submitTransaction(owner1.address, 0, "0x");
            });

            it("should confirm a transaction", async function () {
                await expect(multiSig.confirmTransaction(0))
                    .to.emit(multiSig, "TransactionConfirmed")
                    .withArgs(0, owner1.address);

                const tx = await multiSig.getTransaction(0);
                expect(tx.confirmationCount).to.equal(1);
            });

            it("should revert on double confirmation", async function () {
                await multiSig.confirmTransaction(0);
                await expect(multiSig.confirmTransaction(0))
                    .to.be.revertedWithCustomError(multiSig, "TxAlreadyConfirmed");
            });

            it("should revert on non-existent tx", async function () {
                await expect(multiSig.confirmTransaction(999))
                    .to.be.revertedWithCustomError(multiSig, "TxDoesNotExist");
            });
        });

        describe("executeTransaction", function () {
            it("should execute after reaching threshold", async function () {
                // Submit a self-call to changeThreshold(3)
                const data = multiSig.interface.encodeFunctionData("changeThreshold", [3]);
                await multiSig.submitTransaction(await multiSig.getAddress(), 0, data);

                // Confirm by 2 owners (threshold = 2)
                await multiSig.connect(owner1).confirmTransaction(0);
                await multiSig.connect(owner2).confirmTransaction(0);

                // Execute
                await expect(multiSig.executeTransaction(0))
                    .to.emit(multiSig, "TransactionExecuted")
                    .withArgs(0);

                // Verify the threshold was changed
                expect(await multiSig.threshold()).to.equal(3);
            });

            it("should revert if not enough confirmations", async function () {
                await multiSig.submitTransaction(owner1.address, 0, "0x");
                await multiSig.connect(owner1).confirmTransaction(0);
                // Only 1 confirmation, threshold is 2

                await expect(multiSig.executeTransaction(0))
                    .to.be.revertedWithCustomError(multiSig, "InsufficientConfirmations");
            });

            it("should revert on already executed tx", async function () {
                const data = multiSig.interface.encodeFunctionData("changeThreshold", [3]);
                await multiSig.submitTransaction(await multiSig.getAddress(), 0, data);
                await multiSig.connect(owner1).confirmTransaction(0);
                await multiSig.connect(owner2).confirmTransaction(0);
                await multiSig.executeTransaction(0);

                await expect(multiSig.executeTransaction(0))
                    .to.be.revertedWithCustomError(multiSig, "TxAlreadyExecuted");
            });
        });

        describe("revokeConfirmation", function () {
            beforeEach(async function () {
                await multiSig.submitTransaction(owner1.address, 0, "0x");
                await multiSig.connect(owner1).confirmTransaction(0);
            });

            it("should revoke a confirmation", async function () {
                await expect(multiSig.connect(owner1).revokeConfirmation(0))
                    .to.emit(multiSig, "TransactionRevoked")
                    .withArgs(0, owner1.address);

                const tx = await multiSig.getTransaction(0);
                expect(tx.confirmationCount).to.equal(0);
            });

            it("should revert if not previously confirmed", async function () {
                await expect(multiSig.connect(owner2).revokeConfirmation(0))
                    .to.be.revertedWithCustomError(multiSig, "TxNotConfirmed");
            });
        });

        describe("Owner Management", function () {
            it("should add owner via multisig tx", async function () {
                const data = multiSig.interface.encodeFunctionData("addOwner", [nonOwner.address]);
                await multiSig.submitTransaction(await multiSig.getAddress(), 0, data);
                await multiSig.connect(owner1).confirmTransaction(0);
                await multiSig.connect(owner2).confirmTransaction(0);
                await multiSig.executeTransaction(0);

                expect(await multiSig.isOwner(nonOwner.address)).to.be.true;
                expect(await multiSig.getOwnerCount()).to.equal(4);
            });

            it("should remove owner via multisig tx", async function () {
                const data = multiSig.interface.encodeFunctionData("removeOwner", [owner3.address]);
                await multiSig.submitTransaction(await multiSig.getAddress(), 0, data);
                await multiSig.connect(owner1).confirmTransaction(0);
                await multiSig.connect(owner2).confirmTransaction(0);
                await multiSig.executeTransaction(0);

                expect(await multiSig.isOwner(owner3.address)).to.be.false;
                expect(await multiSig.getOwnerCount()).to.equal(2);
                // Threshold auto-adjusted to 2 (owners.length)
                expect(await multiSig.threshold()).to.equal(2);
            });

            it("should revert addOwner if called directly", async function () {
                await expect(multiSig.addOwner(nonOwner.address))
                    .to.be.revertedWith("Must call via multisig tx");
            });
        });
    });

    // ══════════════════════════════════════════════════════════════
    // TimelockController Integration Tests
    // ══════════════════════════════════════════════════════════════
    describe("TimelockController + MultiSig Integration", function () {
        let timelockController: any;
        let kycRegistry: any;
        const MIN_DELAY = 3600; // 1 hour for testing

        beforeEach(async function () {
            // Deploy TimelockController
            const TimelockFactory = await ethers.getContractFactory("TimelockController");
            const multiSigAddr = await multiSig.getAddress();
            timelockController = await TimelockFactory.deploy(
                MIN_DELAY,
                [multiSigAddr],  // proposers
                [multiSigAddr],  // executors
                ethers.ZeroAddress // no separate admin (self-administered)
            );
            await timelockController.waitForDeployment();

            // Deploy KYCRegistry for integration testing
            const { upgrades } = require("hardhat");
            const KYCRegistryFactory = await ethers.getContractFactory("KYCRegistry");
            kycRegistry = await upgrades.deployProxy(KYCRegistryFactory, [], {
                kind: "uups",
            });
            await kycRegistry.waitForDeployment();

            // Transfer DEFAULT_ADMIN_ROLE to TimelockController
            const DEFAULT_ADMIN_ROLE = await kycRegistry.DEFAULT_ADMIN_ROLE();
            const KYC_ADMIN_ROLE = await kycRegistry.KYC_ADMIN_ROLE();

            // Grant roles to timelock
            await kycRegistry.grantRole(DEFAULT_ADMIN_ROLE, await timelockController.getAddress());
            await kycRegistry.grantRole(KYC_ADMIN_ROLE, await timelockController.getAddress());

            // Renounce own roles (now only timelock can manage)
            await kycRegistry.renounceRole(KYC_ADMIN_ROLE, owner1.address);
            await kycRegistry.renounceRole(DEFAULT_ADMIN_ROLE, owner1.address);
        });

        it("should prevent direct admin operations after role transfer", async function () {
            // owner1 no longer has KYC_ADMIN_ROLE
            await expect(
                kycRegistry.addUser(nonOwner.address, 1)
            ).to.be.reverted;
        });

        it("should execute admin operation via MultiSig → Timelock → Contract", async function () {
            const timelockAddr = await timelockController.getAddress();
            const kycAddr = await kycRegistry.getAddress();

            // 1. Encode the final operation: kycRegistry.addUser(nonOwner, 1)
            const kycCalldata = kycRegistry.interface.encodeFunctionData(
                "addUser", [nonOwner.address, 1]
            );

            // 2. Encode timelock.schedule() call
            const salt = ethers.id("addUser-nonOwner");
            const scheduleCalldata = timelockController.interface.encodeFunctionData(
                "schedule",
                [kycAddr, 0, kycCalldata, ethers.ZeroHash, salt, MIN_DELAY]
            );

            // 3. Submit schedule via MultiSig
            await multiSig.connect(owner1).submitTransaction(timelockAddr, 0, scheduleCalldata);
            await multiSig.connect(owner1).confirmTransaction(0);
            await multiSig.connect(owner2).confirmTransaction(0);
            await multiSig.connect(owner1).executeTransaction(0);

            // 4. Wait for timelock delay
            await time.increase(MIN_DELAY + 1);

            // 5. Encode timelock.execute() call
            const executeCalldata = timelockController.interface.encodeFunctionData(
                "execute",
                [kycAddr, 0, kycCalldata, ethers.ZeroHash, salt]
            );

            // 6. Execute via MultiSig
            await multiSig.connect(owner1).submitTransaction(timelockAddr, 0, executeCalldata);
            await multiSig.connect(owner1).confirmTransaction(1);
            await multiSig.connect(owner2).confirmTransaction(1);
            await multiSig.connect(owner1).executeTransaction(1);

            // 7. Verify: user was added via governance flow
            expect(await kycRegistry.isVerified(nonOwner.address)).to.be.true;
            expect(await kycRegistry.getKYCLevel(nonOwner.address)).to.equal(1);
        });

        it("should revert execution before timelock delay expires", async function () {
            const timelockAddr = await timelockController.getAddress();
            const kycAddr = await kycRegistry.getAddress();

            const kycCalldata = kycRegistry.interface.encodeFunctionData(
                "addUser", [nonOwner.address, 1]
            );

            const salt = ethers.id("early-execute-test");
            const scheduleCalldata = timelockController.interface.encodeFunctionData(
                "schedule",
                [kycAddr, 0, kycCalldata, ethers.ZeroHash, salt, MIN_DELAY]
            );

            // Schedule via MultiSig
            await multiSig.connect(owner1).submitTransaction(timelockAddr, 0, scheduleCalldata);
            await multiSig.connect(owner1).confirmTransaction(0);
            await multiSig.connect(owner2).confirmTransaction(0);
            await multiSig.connect(owner1).executeTransaction(0);

            // Try to execute immediately (should fail — delay not passed)
            const executeCalldata = timelockController.interface.encodeFunctionData(
                "execute",
                [kycAddr, 0, kycCalldata, ethers.ZeroHash, salt]
            );

            await multiSig.connect(owner1).submitTransaction(timelockAddr, 0, executeCalldata);
            await multiSig.connect(owner1).confirmTransaction(1);
            await multiSig.connect(owner2).confirmTransaction(1);

            // This should revert because the multisig forwards to timelock which reverts
            await expect(
                multiSig.connect(owner1).executeTransaction(1)
            ).to.be.revertedWithCustomError(multiSig, "TxExecutionFailed");
        });

        it("should allow cancelling a scheduled operation via MultiSig", async function () {
            const timelockAddr = await timelockController.getAddress();
            const kycAddr = await kycRegistry.getAddress();

            const kycCalldata = kycRegistry.interface.encodeFunctionData(
                "addUser", [nonOwner.address, 1]
            );

            const salt = ethers.id("cancel-test");

            // Schedule
            const scheduleCalldata = timelockController.interface.encodeFunctionData(
                "schedule",
                [kycAddr, 0, kycCalldata, ethers.ZeroHash, salt, MIN_DELAY]
            );
            await multiSig.connect(owner1).submitTransaction(timelockAddr, 0, scheduleCalldata);
            await multiSig.connect(owner1).confirmTransaction(0);
            await multiSig.connect(owner2).confirmTransaction(0);
            await multiSig.connect(owner1).executeTransaction(0);

            // Compute the operation ID the same way TimelockController does
            const operationId = ethers.keccak256(
                ethers.AbiCoder.defaultAbiCoder().encode(
                    ["address", "uint256", "bytes", "bytes32", "bytes32"],
                    [kycAddr, 0, kycCalldata, ethers.ZeroHash, salt]
                )
            );

            // Cancel via MultiSig
            const cancelCalldata = timelockController.interface.encodeFunctionData(
                "cancel", [operationId]
            );
            await multiSig.connect(owner1).submitTransaction(timelockAddr, 0, cancelCalldata);
            await multiSig.connect(owner1).confirmTransaction(1);
            await multiSig.connect(owner2).confirmTransaction(1);
            await multiSig.connect(owner1).executeTransaction(1);

            // Verify the operation is no longer pending
            expect(await timelockController.isOperationPending(operationId)).to.be.false;
        });
    });
});
