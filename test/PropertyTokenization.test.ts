import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import type {
    KYCRegistry,
    PropertyToken,
    PropertyRegistry,
    PropertyTokenFactory,
} from "../typechain-types";

describe("Real Estate Tokenization", function () {
    let owner: HardhatEthersSigner;
    let admin: HardhatEthersSigner;
    let user1: HardhatEthersSigner;
    let user2: HardhatEthersSigner;
    let user3: HardhatEthersSigner;
    let kycRegistry: KYCRegistry;
    let propertyRegistry: PropertyRegistry;
    let factory: PropertyTokenFactory;

    const KYC_LEVEL_BASIC = 1;
    const KYC_LEVEL_ENHANCED = 2;

    beforeEach(async function () {
        [owner, admin, user1, user2, user3] = await ethers.getSigners();

        // Deploy KYCRegistry via UUPS proxy
        const KYCRegistryFactory = await ethers.getContractFactory("KYCRegistry");
        kycRegistry = (await upgrades.deployProxy(KYCRegistryFactory, [], {
            kind: "uups",
        })) as unknown as KYCRegistry;
        await kycRegistry.waitForDeployment();

        // Deploy PropertyRegistry via UUPS proxy
        const PropertyRegistryFactory = await ethers.getContractFactory("PropertyRegistry");
        propertyRegistry = (await upgrades.deployProxy(PropertyRegistryFactory, [], {
            kind: "uups",
        })) as unknown as PropertyRegistry;
        await propertyRegistry.waitForDeployment();

        // Deploy PropertyToken implementation (for the beacon)
        const PropertyTokenFactory = await ethers.getContractFactory("PropertyToken");
        const beacon = await upgrades.deployBeacon(PropertyTokenFactory);
        await beacon.waitForDeployment();

        // Deploy PropertyTokenFactory via UUPS proxy
        const FactoryContract = await ethers.getContractFactory("PropertyTokenFactory");
        factory = (await upgrades.deployProxy(
            FactoryContract,
            [
                await kycRegistry.getAddress(),
                await propertyRegistry.getAddress(),
                await beacon.getAddress(),
            ],
            {
                kind: "uups",
                unsafeAllow: ["constructor"],
            }
        )) as unknown as PropertyTokenFactory;
        await factory.waitForDeployment();

        // Grant REGISTRY_ADMIN_ROLE to factory
        const REGISTRY_ADMIN_ROLE = await propertyRegistry.REGISTRY_ADMIN_ROLE();
        await propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, await factory.getAddress());
    });

    // ══════════════════════════════════════════════════════════════
    // KYCRegistry Tests
    // ══════════════════════════════════════════════════════════════
    describe("KYCRegistry", function () {
        describe("addUser", function () {
            it("should add a user with Basic KYC level", async function () {
                await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);

                expect(await kycRegistry.isVerified(user1.address)).to.be.true;
                expect(await kycRegistry.getKYCLevel(user1.address)).to.equal(KYC_LEVEL_BASIC);
            });

            it("should add a user with Enhanced KYC level", async function () {
                await kycRegistry.addUser(user1.address, KYC_LEVEL_ENHANCED);

                expect(await kycRegistry.isVerified(user1.address)).to.be.true;
                expect(await kycRegistry.getKYCLevel(user1.address)).to.equal(KYC_LEVEL_ENHANCED);
            });

            it("should emit UserApproved event", async function () {
                await expect(kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC))
                    .to.emit(kycRegistry, "UserApproved")
                    .withArgs(user1.address, KYC_LEVEL_BASIC, owner.address);
            });

            it("should revert if user already verified", async function () {
                await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);
                await expect(kycRegistry.addUser(user1.address, KYC_LEVEL_ENHANCED))
                    .to.be.revertedWithCustomError(kycRegistry, "UserAlreadyVerified");
            });

            it("should revert if KYC level is 0 (NONE)", async function () {
                await expect(kycRegistry.addUser(user1.address, 0))
                    .to.be.revertedWithCustomError(kycRegistry, "InvalidKYCLevel");
            });

            it("should revert if KYC level > 2", async function () {
                await expect(kycRegistry.addUser(user1.address, 3))
                    .to.be.revertedWithCustomError(kycRegistry, "InvalidKYCLevel");
            });

            it("should revert if zero address", async function () {
                await expect(kycRegistry.addUser(ethers.ZeroAddress, KYC_LEVEL_BASIC))
                    .to.be.revertedWithCustomError(kycRegistry, "ZeroAddress");
            });

            it("should revert if called by non-admin", async function () {
                await expect(kycRegistry.connect(user1).addUser(user2.address, KYC_LEVEL_BASIC))
                    .to.be.reverted;
            });
        });

        describe("removeUser", function () {
            beforeEach(async function () {
                await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);
            });

            it("should remove a verified user", async function () {
                await kycRegistry.removeUser(user1.address);

                expect(await kycRegistry.isVerified(user1.address)).to.be.false;
                expect(await kycRegistry.getKYCLevel(user1.address)).to.equal(0);
            });

            it("should emit UserRemoved event", async function () {
                await expect(kycRegistry.removeUser(user1.address))
                    .to.emit(kycRegistry, "UserRemoved")
                    .withArgs(user1.address, owner.address);
            });

            it("should revert if user not verified", async function () {
                await expect(kycRegistry.removeUser(user2.address))
                    .to.be.revertedWithCustomError(kycRegistry, "UserNotVerified");
            });

            it("should decrease verified user count", async function () {
                await kycRegistry.addUser(user2.address, KYC_LEVEL_BASIC);
                expect(await kycRegistry.getVerifiedUserCount()).to.equal(2);

                await kycRegistry.removeUser(user1.address);
                expect(await kycRegistry.getVerifiedUserCount()).to.equal(1);
            });
        });

        describe("batchAddUsers", function () {
            it("should batch add multiple users", async function () {
                await kycRegistry.batchAddUsers(
                    [user1.address, user2.address, user3.address],
                    [KYC_LEVEL_BASIC, KYC_LEVEL_ENHANCED, KYC_LEVEL_BASIC]
                );

                expect(await kycRegistry.isVerified(user1.address)).to.be.true;
                expect(await kycRegistry.isVerified(user2.address)).to.be.true;
                expect(await kycRegistry.isVerified(user3.address)).to.be.true;
                expect(await kycRegistry.getKYCLevel(user2.address)).to.equal(KYC_LEVEL_ENHANCED);
                expect(await kycRegistry.getVerifiedUserCount()).to.equal(3);
            });

            it("should revert if array lengths mismatch", async function () {
                await expect(
                    kycRegistry.batchAddUsers([user1.address, user2.address], [KYC_LEVEL_BASIC])
                ).to.be.revertedWithCustomError(kycRegistry, "ArrayLengthMismatch");
            });
        });

        describe("updateKYCLevel", function () {
            beforeEach(async function () {
                await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);
            });

            it("should update KYC level", async function () {
                await kycRegistry.updateKYCLevel(user1.address, KYC_LEVEL_ENHANCED);
                expect(await kycRegistry.getKYCLevel(user1.address)).to.equal(KYC_LEVEL_ENHANCED);
            });

            it("should emit KYCLevelUpdated event", async function () {
                await expect(kycRegistry.updateKYCLevel(user1.address, KYC_LEVEL_ENHANCED))
                    .to.emit(kycRegistry, "KYCLevelUpdated")
                    .withArgs(user1.address, KYC_LEVEL_BASIC, KYC_LEVEL_ENHANCED);
            });

            it("should revert if user not verified", async function () {
                await expect(kycRegistry.updateKYCLevel(user2.address, KYC_LEVEL_ENHANCED))
                    .to.be.revertedWithCustomError(kycRegistry, "UserNotVerified");
            });
        });

        describe("getVerifiedUsers", function () {
            it("should return all verified addresses", async function () {
                await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);
                await kycRegistry.addUser(user2.address, KYC_LEVEL_ENHANCED);

                const users = await kycRegistry.getVerifiedUsers();
                expect(users.length).to.equal(2);
                expect(users).to.include(user1.address);
                expect(users).to.include(user2.address);
            });
        });
    });

    // ══════════════════════════════════════════════════════════════
    // PropertyRegistry Tests
    // ══════════════════════════════════════════════════════════════
    describe("PropertyRegistry", function () {
        const sampleProperty = {
            name: "Apartemen Sudirman Park",
            address: "Jl. Jend. Sudirman No. 1, Jakarta",
            value: ethers.parseEther("100"),
            ipfsURI: "ipfs://QmExampleHash123456789",
        };

        describe("registerProperty", function () {
            it("should register a new property", async function () {
                const tokenAddr = user1.address;
                await propertyRegistry.registerProperty(
                    sampleProperty.name,
                    sampleProperty.address,
                    sampleProperty.value,
                    sampleProperty.ipfsURI,
                    tokenAddr
                );

                const prop = await propertyRegistry.getProperty(1);
                expect(prop.propertyName).to.equal(sampleProperty.name);
                expect(prop.propertyAddress).to.equal(sampleProperty.address);
                expect(prop.totalValue).to.equal(sampleProperty.value);
                expect(prop.ipfsDocumentURI).to.equal(sampleProperty.ipfsURI);
                expect(prop.tokenAddress).to.equal(tokenAddr);
                expect(prop.isActive).to.be.true;
            });

            it("should emit PropertyRegistered event", async function () {
                await expect(
                    propertyRegistry.registerProperty(
                        sampleProperty.name,
                        sampleProperty.address,
                        sampleProperty.value,
                        sampleProperty.ipfsURI,
                        user1.address
                    )
                )
                    .to.emit(propertyRegistry, "PropertyRegistered")
                    .withArgs(1, sampleProperty.name, user1.address, sampleProperty.ipfsURI);
            });

            it("should increment property count", async function () {
                await propertyRegistry.registerProperty(
                    sampleProperty.name, sampleProperty.address, sampleProperty.value,
                    sampleProperty.ipfsURI, user1.address
                );
                await propertyRegistry.registerProperty(
                    "Apartemen 2", "Jl. Thamrin", ethers.parseEther("50"),
                    "ipfs://QmSecondHash", user2.address
                );
                expect(await propertyRegistry.getPropertyCount()).to.equal(2);
            });

            it("should revert on empty property name", async function () {
                await expect(
                    propertyRegistry.registerProperty(
                        "", sampleProperty.address, sampleProperty.value,
                        sampleProperty.ipfsURI, user1.address
                    )
                ).to.be.revertedWithCustomError(propertyRegistry, "EmptyString");
            });

            it("should revert on zero token address", async function () {
                await expect(
                    propertyRegistry.registerProperty(
                        sampleProperty.name, sampleProperty.address, sampleProperty.value,
                        sampleProperty.ipfsURI, ethers.ZeroAddress
                    )
                ).to.be.revertedWithCustomError(propertyRegistry, "ZeroAddress");
            });

            it("should revert if token already registered", async function () {
                await propertyRegistry.registerProperty(
                    sampleProperty.name, sampleProperty.address, sampleProperty.value,
                    sampleProperty.ipfsURI, user1.address
                );
                await expect(
                    propertyRegistry.registerProperty(
                        "Prop 2", "Alamat 2", ethers.parseEther("50"),
                        "ipfs://QmHash2", user1.address
                    )
                ).to.be.revertedWithCustomError(propertyRegistry, "TokenAlreadyRegistered");
            });
        });

        describe("updateIPFSDocument", function () {
            beforeEach(async function () {
                await propertyRegistry.registerProperty(
                    sampleProperty.name, sampleProperty.address, sampleProperty.value,
                    sampleProperty.ipfsURI, user1.address
                );
            });

            it("should update IPFS URI", async function () {
                const newURI = "ipfs://QmNewHashUpdated";
                await propertyRegistry.updateIPFSDocument(1, newURI);
                const prop = await propertyRegistry.getProperty(1);
                expect(prop.ipfsDocumentURI).to.equal(newURI);
            });

            it("should emit IPFSDocumentUpdated event", async function () {
                const newURI = "ipfs://QmNewHashUpdated";
                await expect(propertyRegistry.updateIPFSDocument(1, newURI))
                    .to.emit(propertyRegistry, "IPFSDocumentUpdated")
                    .withArgs(1, sampleProperty.ipfsURI, newURI);
            });

            it("should revert on non-existent property", async function () {
                await expect(propertyRegistry.updateIPFSDocument(999, "ipfs://QmHash"))
                    .to.be.revertedWithCustomError(propertyRegistry, "PropertyNotFound");
            });
        });

        describe("deactivateProperty / reactivateProperty", function () {
            beforeEach(async function () {
                await propertyRegistry.registerProperty(
                    sampleProperty.name, sampleProperty.address, sampleProperty.value,
                    sampleProperty.ipfsURI, user1.address
                );
            });

            it("should deactivate a property", async function () {
                await propertyRegistry.deactivateProperty(1);
                const prop = await propertyRegistry.getProperty(1);
                expect(prop.isActive).to.be.false;
            });

            it("should reactivate a deactivated property", async function () {
                await propertyRegistry.deactivateProperty(1);
                await propertyRegistry.reactivateProperty(1);
                const prop = await propertyRegistry.getProperty(1);
                expect(prop.isActive).to.be.true;
            });

            it("should revert update on deactivated property", async function () {
                await propertyRegistry.deactivateProperty(1);
                await expect(propertyRegistry.updateIPFSDocument(1, "ipfs://QmNew"))
                    .to.be.revertedWithCustomError(propertyRegistry, "PropertyNotActive");
            });
        });

        describe("getPropertyByToken", function () {
            it("should return property by token address", async function () {
                await propertyRegistry.registerProperty(
                    sampleProperty.name, sampleProperty.address, sampleProperty.value,
                    sampleProperty.ipfsURI, user1.address
                );
                const prop = await propertyRegistry.getPropertyByToken(user1.address);
                expect(prop.propertyName).to.equal(sampleProperty.name);
            });
        });
    });

    // ══════════════════════════════════════════════════════════════
    // PropertyToken Tests
    // ══════════════════════════════════════════════════════════════
    describe("PropertyToken", function () {
        let propertyToken: PropertyToken;
        const TOKEN_NAME = "RealToken - Jl. Sudirman No. 1";
        const TOKEN_SYMBOL = "RTJKS1";
        const TOTAL_SUPPLY = ethers.parseEther("1000");

        beforeEach(async function () {
            // Deploy a standalone PropertyToken via BeaconProxy for direct testing
            const PropertyTokenFactory = await ethers.getContractFactory("PropertyToken");
            const beacon = await upgrades.deployBeacon(PropertyTokenFactory);
            await beacon.waitForDeployment();

            propertyToken = (await upgrades.deployBeaconProxy(
                beacon,
                PropertyTokenFactory,
                [
                    TOKEN_NAME, TOKEN_SYMBOL, TOTAL_SUPPLY,
                    1, await kycRegistry.getAddress(), KYC_LEVEL_BASIC, owner.address
                ]
            )) as unknown as PropertyToken;
            await propertyToken.waitForDeployment();

            await kycRegistry.addUser(owner.address, KYC_LEVEL_BASIC);
            await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);
            await kycRegistry.addUser(user2.address, KYC_LEVEL_ENHANCED);
        });

        describe("Deployment", function () {
            it("should set correct name and symbol", async function () {
                expect(await propertyToken.name()).to.equal(TOKEN_NAME);
                expect(await propertyToken.symbol()).to.equal(TOKEN_SYMBOL);
            });

            it("should mint total supply to owner", async function () {
                expect(await propertyToken.balanceOf(owner.address)).to.equal(TOTAL_SUPPLY);
                expect(await propertyToken.totalSupply()).to.equal(TOTAL_SUPPLY);
            });

            it("should set correct propertyId", async function () {
                expect(await propertyToken.propertyId()).to.equal(1);
            });

            it("should set correct KYC registry", async function () {
                expect(await propertyToken.kycRegistry()).to.equal(await kycRegistry.getAddress());
            });
        });

        describe("KYC-gated Transfer", function () {
            it("should allow transfer between KYC-verified users", async function () {
                const amount = ethers.parseEther("100");
                await propertyToken.transfer(user1.address, amount);
                expect(await propertyToken.balanceOf(user1.address)).to.equal(amount);
            });

            it("should allow transfer from user1 to user2 (both KYC)", async function () {
                await propertyToken.transfer(user1.address, ethers.parseEther("100"));
                await propertyToken.connect(user1).transfer(user2.address, ethers.parseEther("50"));
                expect(await propertyToken.balanceOf(user2.address)).to.equal(ethers.parseEther("50"));
            });

            it("should revert transfer to non-KYC user", async function () {
                await expect(propertyToken.transfer(user3.address, ethers.parseEther("100")))
                    .to.be.revertedWithCustomError(propertyToken, "RecipientNotKYCVerified");
            });

            it("should revert transfer from non-KYC user", async function () {
                await kycRegistry.addUser(user3.address, KYC_LEVEL_BASIC);
                await propertyToken.transfer(user3.address, ethers.parseEther("100"));
                await kycRegistry.removeUser(user3.address);

                await expect(
                    propertyToken.connect(user3).transfer(user1.address, ethers.parseEther("10"))
                ).to.be.revertedWithCustomError(propertyToken, "SenderNotKYCVerified");
            });

            it("should revert if KYC level insufficient", async function () {
                // Deploy an Enhanced-level token
                const PTFactory = await ethers.getContractFactory("PropertyToken");
                const enhancedBeacon = await upgrades.deployBeacon(PTFactory);
                const enhancedToken = (await upgrades.deployBeaconProxy(
                    enhancedBeacon,
                    PTFactory,
                    [
                        "Enhanced Token", "ENH", ethers.parseEther("1000"),
                        2, await kycRegistry.getAddress(), KYC_LEVEL_ENHANCED, owner.address
                    ]
                )) as unknown as PropertyToken;
                await enhancedToken.waitForDeployment();

                // owner is KYC level 1 (Basic), token requires level 2 → should fail
                await expect(
                    enhancedToken.transfer(user2.address, ethers.parseEther("100"))
                ).to.be.revertedWithCustomError(enhancedToken, "InsufficientKYCLevel");
            });
        });

        describe("Pause / Unpause", function () {
            it("should pause transfers", async function () {
                await propertyToken.pause();
                await expect(propertyToken.transfer(user1.address, ethers.parseEther("10")))
                    .to.be.reverted;
            });

            it("should unpause transfers", async function () {
                await propertyToken.pause();
                await propertyToken.unpause();
                await expect(propertyToken.transfer(user1.address, ethers.parseEther("10")))
                    .to.not.be.reverted;
            });

            it("should revert if non-owner tries to pause", async function () {
                await expect(propertyToken.connect(user1).pause()).to.be.reverted;
            });
        });

        describe("Mint additional tokens", function () {
            it("should allow owner to mint more tokens", async function () {
                const mintAmount = ethers.parseEther("500");
                await propertyToken.mint(owner.address, mintAmount);
                expect(await propertyToken.totalSupply()).to.equal(TOTAL_SUPPLY + mintAmount);
            });

            it("should revert if non-owner tries to mint", async function () {
                await expect(
                    propertyToken.connect(user1).mint(user1.address, ethers.parseEther("100"))
                ).to.be.reverted;
            });
        });

        describe("Burn tokens", function () {
            it("should allow token holder to burn", async function () {
                const burnAmount = ethers.parseEther("100");
                await propertyToken.burn(burnAmount);
                expect(await propertyToken.totalSupply()).to.equal(TOTAL_SUPPLY - burnAmount);
            });
        });
    });

    // ══════════════════════════════════════════════════════════════
    // PropertyTokenFactory Tests (using struct params)
    // ══════════════════════════════════════════════════════════════
    describe("PropertyTokenFactory", function () {
        // Helper to build CreateTokenParams
        function createParams(overrides: Partial<{
            name: string; symbol: string; totalSupply: bigint;
            propertyName: string; propertyAddress: string;
            totalValue: bigint; ipfsDocumentURI: string; requiredKYCLevel: number;
        }> = {}) {
            return {
                name: overrides.name ?? "RealToken - Apartemen Sudirman",
                symbol: overrides.symbol ?? "RTAPS",
                totalSupply: overrides.totalSupply ?? ethers.parseEther("1000"),
                propertyName: overrides.propertyName ?? "Apartemen Sudirman Park",
                propertyAddress: overrides.propertyAddress ?? "Jl. Jend. Sudirman No. 1, Jakarta",
                totalValue: overrides.totalValue ?? ethers.parseEther("100"),
                ipfsDocumentURI: overrides.ipfsDocumentURI ?? "ipfs://QmExamplePropertyDocHash",
                requiredKYCLevel: overrides.requiredKYCLevel ?? KYC_LEVEL_BASIC,
            };
        }

        describe("createPropertyToken", function () {
            it("should create a new property token and register it", async function () {
                await factory.createPropertyToken(createParams());

                const deployedTokens = await factory.getDeployedTokens();
                expect(deployedTokens.length).to.equal(1);

                const prop = await propertyRegistry.getProperty(1);
                expect(prop.propertyName).to.equal("Apartemen Sudirman Park");
                expect(prop.tokenAddress).to.equal(deployedTokens[0]);
                expect(prop.ipfsDocumentURI).to.equal("ipfs://QmExamplePropertyDocHash");
            });

            it("should emit PropertyTokenCreated event", async function () {
                await expect(factory.createPropertyToken(createParams({
                    name: "RealToken - Test", symbol: "RTT",
                    totalSupply: ethers.parseEther("500"),
                    propertyName: "Test Property", propertyAddress: "Jl. Test No. 1",
                    totalValue: ethers.parseEther("50"), ipfsDocumentURI: "ipfs://QmTestHash",
                }))).to.emit(factory, "PropertyTokenCreated");
            });

            it("should create multiple tokens for different properties", async function () {
                await factory.createPropertyToken(createParams({
                    name: "Token A", symbol: "TKA",
                    propertyName: "Property A", propertyAddress: "Address A",
                    ipfsDocumentURI: "ipfs://QmHashA",
                }));
                await factory.createPropertyToken(createParams({
                    name: "Token B", symbol: "TKB",
                    totalSupply: ethers.parseEther("2000"),
                    propertyName: "Property B", propertyAddress: "Address B",
                    totalValue: ethers.parseEther("200"), ipfsDocumentURI: "ipfs://QmHashB",
                    requiredKYCLevel: KYC_LEVEL_ENHANCED,
                }));

                expect(await factory.getDeployedTokenCount()).to.equal(2);
                expect(await propertyRegistry.getPropertyCount()).to.equal(2);
            });

            it("should mint all tokens to the caller (owner)", async function () {
                await factory.createPropertyToken(createParams({
                    name: "Token C", symbol: "TKC",
                    propertyName: "Property C", propertyAddress: "Address C",
                    ipfsDocumentURI: "ipfs://QmHashC",
                }));

                const tokenAddr = await factory.getTokenByPropertyId(1);
                const token = (await ethers.getContractAt("PropertyToken", tokenAddr)) as unknown as PropertyToken;
                expect(await token.balanceOf(owner.address)).to.equal(ethers.parseEther("1000"));
            });

            it("should revert on empty name", async function () {
                await expect(
                    factory.createPropertyToken(createParams({ name: "" }))
                ).to.be.revertedWithCustomError(factory, "EmptyString");
            });

            it("should revert on zero total supply", async function () {
                await expect(
                    factory.createPropertyToken(createParams({ totalSupply: 0n }))
                ).to.be.revertedWithCustomError(factory, "ZeroValue");
            });

            it("should revert on zero total value", async function () {
                await expect(
                    factory.createPropertyToken(createParams({ totalValue: 0n }))
                ).to.be.revertedWithCustomError(factory, "ZeroValue");
            });

            it("should revert if non-owner tries to create", async function () {
                await expect(
                    factory.connect(user1).createPropertyToken(createParams())
                ).to.be.reverted;
            });
        });

        describe("View Functions", function () {
            it("should return token address by property ID", async function () {
                await factory.createPropertyToken(createParams({
                    name: "Token D", symbol: "TKD",
                    propertyName: "Property D", propertyAddress: "Address D",
                    ipfsDocumentURI: "ipfs://QmHashD",
                }));
                const tokenAddr = await factory.getTokenByPropertyId(1);
                expect(tokenAddr).to.not.equal(ethers.ZeroAddress);
            });

            it("should return zero address for non-existent property", async function () {
                const tokenAddr = await factory.getTokenByPropertyId(999);
                expect(tokenAddr).to.equal(ethers.ZeroAddress);
            });
        });
    });

    // ══════════════════════════════════════════════════════════════
    // ERC20Votes & ERC20Permit (for dividends, voting, and AMM)
    // ══════════════════════════════════════════════════════════════
    describe("ERC20Votes - Delegation & Checkpointing", function () {
        let token: PropertyToken;

        beforeEach(async function () {
            await kycRegistry.addUser(owner.address, KYC_LEVEL_ENHANCED);
            await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);
            await kycRegistry.addUser(user2.address, KYC_LEVEL_BASIC);

            await factory.createPropertyToken({
                name: "RealToken - Villa Bali",
                symbol: "RTVB",
                totalSupply: ethers.parseEther("1000"),
                propertyName: "Villa Bali Seminyak",
                propertyAddress: "Jl. Seminyak No. 10, Bali",
                totalValue: ethers.parseEther("1000"),
                ipfsDocumentURI: "ipfs://QmVillaBaliDocs",
                requiredKYCLevel: KYC_LEVEL_BASIC,
            });

            const tokenAddr = await factory.getTokenByPropertyId(1);
            token = (await ethers.getContractAt("PropertyToken", tokenAddr)) as unknown as PropertyToken;
        });

        it("should have zero voting power before delegation", async function () {
            expect(await token.getVotes(owner.address)).to.equal(0);
        });

        it("should activate voting power via self-delegation", async function () {
            await token.connect(owner).delegate(owner.address);
            expect(await token.getVotes(owner.address)).to.equal(ethers.parseEther("1000"));
        });

        it("should allow delegating voting power to another user", async function () {
            await token.connect(owner).delegate(user1.address);
            expect(await token.getVotes(user1.address)).to.equal(ethers.parseEther("1000"));
            expect(await token.getVotes(owner.address)).to.equal(0);
        });

        it("should update voting power after token transfer", async function () {
            await token.connect(owner).delegate(owner.address);
            await token.connect(user1).delegate(user1.address);

            await token.transfer(user1.address, ethers.parseEther("300"));

            expect(await token.getVotes(owner.address)).to.equal(ethers.parseEther("700"));
            expect(await token.getVotes(user1.address)).to.equal(ethers.parseEther("300"));
        });

        it("should track past votes via checkpointing (for dividend snapshots)", async function () {
            await token.connect(owner).delegate(owner.address);
            await token.connect(user1).delegate(user1.address);

            const snapshotBlock = await ethers.provider.getBlockNumber();

            await token.transfer(user1.address, ethers.parseEther("400"));
            await ethers.provider.send("evm_mine", []);

            // getPastVotes at snapshot → balance before transfer
            expect(await token.getPastVotes(owner.address, snapshotBlock))
                .to.equal(ethers.parseEther("1000"));
            expect(await token.getPastVotes(user1.address, snapshotBlock))
                .to.equal(ethers.parseEther("0"));

            // Current balance → after transfer
            expect(await token.getVotes(owner.address)).to.equal(ethers.parseEther("600"));
            expect(await token.getVotes(user1.address)).to.equal(ethers.parseEther("400"));
        });

        it("should track past total supply (for proportional dividend calculation)", async function () {
            await token.connect(owner).delegate(owner.address);

            const snapshotBlock = await ethers.provider.getBlockNumber();

            await token.mint(owner.address, ethers.parseEther("500"));
            await ethers.provider.send("evm_mine", []);

            expect(await token.getPastTotalSupply(snapshotBlock))
                .to.equal(ethers.parseEther("1000"));
            expect(await token.totalSupply()).to.equal(ethers.parseEther("1500"));
        });
    });

    describe("ERC20Permit - Gasless Approval", function () {
        let token: PropertyToken;

        beforeEach(async function () {
            await kycRegistry.addUser(owner.address, KYC_LEVEL_ENHANCED);
            await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);

            await factory.createPropertyToken({
                name: "RealToken - Villa Bali",
                symbol: "RTVB",
                totalSupply: ethers.parseEther("1000"),
                propertyName: "Villa Bali Seminyak",
                propertyAddress: "Jl. Seminyak No. 10, Bali",
                totalValue: ethers.parseEther("1000"),
                ipfsDocumentURI: "ipfs://QmVillaBaliDocs",
                requiredKYCLevel: KYC_LEVEL_BASIC,
            });

            const tokenAddr = await factory.getTokenByPropertyId(1);
            token = (await ethers.getContractAt("PropertyToken", tokenAddr)) as unknown as PropertyToken;
        });

        it("should allow gasless approval via permit signature", async function () {
            const spender = user1.address;
            const value = ethers.parseEther("100");
            const nonce = await token.nonces(owner.address);
            const block = await ethers.provider.getBlock("latest");
            const deadline = block!.timestamp + 3600;

            const domain = {
                name: await token.name(),
                version: "1",
                chainId: (await ethers.provider.getNetwork()).chainId,
                verifyingContract: await token.getAddress(),
            };

            const types = {
                Permit: [
                    { name: "owner", type: "address" },
                    { name: "spender", type: "address" },
                    { name: "value", type: "uint256" },
                    { name: "nonce", type: "uint256" },
                    { name: "deadline", type: "uint256" },
                ],
            };

            const message = {
                owner: owner.address,
                spender: spender,
                value: value,
                nonce: nonce,
                deadline: deadline,
            };

            const sig = await owner.signTypedData(domain, types, message);
            const { v, r, s } = ethers.Signature.from(sig);

            await token.connect(user1).permit(owner.address, spender, value, deadline, v, r, s);
            expect(await token.allowance(owner.address, spender)).to.equal(value);
        });
    });

    // ══════════════════════════════════════════════════════════════
    // Upgradeability Tests
    // ══════════════════════════════════════════════════════════════
    describe("Upgradeability", function () {
        it("should preserve KYCRegistry state after upgrade", async function () {
            // Add users before upgrade
            await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);
            await kycRegistry.addUser(user2.address, KYC_LEVEL_ENHANCED);

            // Upgrade to same implementation (simulates upgrade)
            const KYCRegistryV2 = await ethers.getContractFactory("KYCRegistry");
            const upgraded = await upgrades.upgradeProxy(
                await kycRegistry.getAddress(),
                KYCRegistryV2,
                { kind: "uups" }
            );

            // Verify state preserved
            expect(await upgraded.isVerified(user1.address)).to.be.true;
            expect(await upgraded.getKYCLevel(user1.address)).to.equal(KYC_LEVEL_BASIC);
            expect(await upgraded.isVerified(user2.address)).to.be.true;
            expect(await upgraded.getKYCLevel(user2.address)).to.equal(KYC_LEVEL_ENHANCED);
            expect(await upgraded.getVerifiedUserCount()).to.equal(2);
        });

        it("should preserve PropertyRegistry state after upgrade", async function () {
            await propertyRegistry.registerProperty(
                "Test Property", "Test Address", ethers.parseEther("100"),
                "ipfs://QmTest", user1.address
            );

            const PropertyRegistryV2 = await ethers.getContractFactory("PropertyRegistry");
            const upgraded = await upgrades.upgradeProxy(
                await propertyRegistry.getAddress(),
                PropertyRegistryV2,
                { kind: "uups" }
            );

            const prop = await upgraded.getProperty(1);
            expect(prop.propertyName).to.equal("Test Property");
            expect(prop.tokenAddress).to.equal(user1.address);
            expect(await upgraded.getPropertyCount()).to.equal(1);
        });

        it("should only allow admin to upgrade KYCRegistry", async function () {
            const KYCRegistryV2 = await ethers.getContractFactory("KYCRegistry", user1);
            await expect(
                upgrades.upgradeProxy(
                    await kycRegistry.getAddress(),
                    KYCRegistryV2,
                    { kind: "uups" }
                )
            ).to.be.reverted;
        });

        it("should only allow owner to upgrade PropertyTokenFactory", async function () {
            const FactoryV2 = await ethers.getContractFactory("PropertyTokenFactory", user1);
            await expect(
                upgrades.upgradeProxy(
                    await factory.getAddress(),
                    FactoryV2,
                    { kind: "uups", unsafeAllow: ["constructor"] }
                )
            ).to.be.reverted;
        });
    });

    // ══════════════════════════════════════════════════════════════
    // Integration / End-to-End Tests
    // ══════════════════════════════════════════════════════════════
    describe("End-to-End Flow", function () {
        it("should complete the full tokenization flow", async function () {
            // 1. Admin whitelists users via KYC
            await kycRegistry.addUser(owner.address, KYC_LEVEL_ENHANCED);
            await kycRegistry.addUser(user1.address, KYC_LEVEL_BASIC);
            await kycRegistry.addUser(user2.address, KYC_LEVEL_BASIC);

            // 2. Create property token via factory
            await factory.createPropertyToken({
                name: "RealToken - Apartemen Sudirman Park Unit A",
                symbol: "RTASPA",
                totalSupply: ethers.parseEther("1000"),
                propertyName: "Apartemen Sudirman Park Unit A",
                propertyAddress: "Jl. Jend. Sudirman No. 1, Jakarta Selatan",
                totalValue: ethers.parseEther("500"),
                ipfsDocumentURI: "ipfs://QmPropertyDocumentHash12345",
                requiredKYCLevel: KYC_LEVEL_BASIC,
            });

            // 3. Verify property was registered
            const prop = await propertyRegistry.getProperty(1);
            expect(prop.propertyName).to.equal("Apartemen Sudirman Park Unit A");
            expect(prop.ipfsDocumentURI).to.equal("ipfs://QmPropertyDocumentHash12345");
            expect(prop.isActive).to.be.true;

            // 4. Get the deployed token
            const tokenAddr = await factory.getTokenByPropertyId(1);
            const token = (await ethers.getContractAt("PropertyToken", tokenAddr)) as unknown as PropertyToken;

            // 5. Owner distributes tokens to investors (KYC-verified)
            await token.transfer(user1.address, ethers.parseEther("200"));
            await token.transfer(user2.address, ethers.parseEther("300"));

            expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("200"));
            expect(await token.balanceOf(user2.address)).to.equal(ethers.parseEther("300"));
            expect(await token.balanceOf(owner.address)).to.equal(ethers.parseEther("500"));

            // 6. user1 transfers to user2 (both KYC verified)
            await token.connect(user1).transfer(user2.address, ethers.parseEther("50"));
            expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("150"));
            expect(await token.balanceOf(user2.address)).to.equal(ethers.parseEther("350"));

            // 7. Non-KYC user3 cannot receive tokens
            await expect(
                token.connect(user1).transfer(user3.address, ethers.parseEther("10"))
            ).to.be.revertedWithCustomError(token, "RecipientNotKYCVerified");

            // 8. Update IPFS document (add new photos)
            await propertyRegistry.updateIPFSDocument(1, "ipfs://QmUpdatedDocWithNewPhotos");
            const updatedProp = await propertyRegistry.getProperty(1);
            expect(updatedProp.ipfsDocumentURI).to.equal("ipfs://QmUpdatedDocWithNewPhotos");
        });
    });

    describe("Functional Tests", function () {
        it("multi-token scenario: 2 tokens with independent KYC checks", async function () {
            await kycRegistry.addUser(owner.address, 2);
            await kycRegistry.addUser(user1.address, 1);
            await kycRegistry.addUser(user2.address, 2);

            // Token A: Basic KYC required
            await factory.createPropertyToken({
                name: "Token A",
                symbol: "TKA",
                totalSupply: ethers.parseEther("1000"),
                propertyName: "Property A",
                propertyAddress: "Jl. A No. 1",
                totalValue: ethers.parseEther("100"),
                ipfsDocumentURI: "ipfs://A",
                requiredKYCLevel: 1,
            });
            const tokenAAddr = await factory.getTokenByPropertyId(1);
            const tokenA = (await ethers.getContractAt("PropertyToken", tokenAAddr)) as unknown as PropertyToken;

            // Token B: Enhanced KYC required
            await factory.createPropertyToken({
                name: "Token B",
                symbol: "TKB",
                totalSupply: ethers.parseEther("500"),
                propertyName: "Property B",
                propertyAddress: "Jl. B No. 2",
                totalValue: ethers.parseEther("200"),
                ipfsDocumentURI: "ipfs://B",
                requiredKYCLevel: 2,
            });
            const tokenBAddr = await factory.getTokenByPropertyId(2);
            const tokenB = (await ethers.getContractAt("PropertyToken", tokenBAddr)) as unknown as PropertyToken;

            // user1 (Basic) can receive token A but NOT token B
            await tokenA.transfer(user1.address, ethers.parseEther("50"));
            expect(await tokenA.balanceOf(user1.address)).to.equal(ethers.parseEther("50"));

            await expect(
                tokenB.transfer(user1.address, ethers.parseEther("50"))
            ).to.be.revertedWithCustomError(tokenB, "InsufficientKYCLevel");

            // user2 (Enhanced) can receive both
            await tokenA.transfer(user2.address, ethers.parseEther("50"));
            await tokenB.transfer(user2.address, ethers.parseEther("50"));
            expect(await tokenA.balanceOf(user2.address)).to.equal(ethers.parseEther("50"));
            expect(await tokenB.balanceOf(user2.address)).to.equal(ethers.parseEther("50"));

            // Different property IDs, different supplies
            expect(await tokenA.propertyId()).to.equal(1);
            expect(await tokenB.propertyId()).to.equal(2);
            expect(await factory.getDeployedTokenCount()).to.equal(2);
        });

        it("full lifecycle: create → transfer → pause → unpause → upgrade → transfer", async function () {
            await kycRegistry.addUser(owner.address, 2);
            await kycRegistry.addUser(user1.address, 1);

            await factory.createPropertyToken({
                name: "Lifecycle Token",
                symbol: "LCT",
                totalSupply: ethers.parseEther("1000"),
                propertyName: "Lifecycle Property",
                propertyAddress: "Jl. Lifecycle No. 1",
                totalValue: ethers.parseEther("500"),
                ipfsDocumentURI: "ipfs://lifecycle",
                requiredKYCLevel: 1,
            });
            const tokenAddr = await factory.getTokenByPropertyId(1);
            const token = (await ethers.getContractAt("PropertyToken", tokenAddr)) as unknown as PropertyToken;

            // Transfer works
            await token.transfer(user1.address, ethers.parseEther("100"));
            expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("100"));

            // Pause blocks transfers
            await token.pause();
            await expect(
                token.transfer(user1.address, ethers.parseEther("10"))
            ).to.be.reverted;

            // Unpause restores
            await token.unpause();
            await token.transfer(user1.address, ethers.parseEther("10"));
            expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("110"));

            // Upgrade beacon, data should survive
            const PropertyTokenV2 = await ethers.getContractFactory("PropertyToken");
            await upgrades.upgradeBeacon(await factory.tokenBeacon(), PropertyTokenV2, {
                unsafeAllow: ["constructor"],
            });

            // Transfer still works after upgrade
            await token.transfer(user1.address, ethers.parseEther("10"));
            expect(await token.balanceOf(user1.address)).to.equal(ethers.parseEther("120"));
            expect(await token.name()).to.equal("Lifecycle Token");
            expect(await token.propertyId()).to.equal(1);
            expect(await token.totalSupply()).to.equal(ethers.parseEther("1000"));
        });
    });
});
