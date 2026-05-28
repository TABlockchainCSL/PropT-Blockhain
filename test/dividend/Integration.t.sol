// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import "../../src/core/PropertyToken.sol";
import "../../src/core/PropertyRegistry.sol";
import "../../src/core/KYCRegistry.sol";
import "../../src/dividend/DividendDistribution.sol";
import "../../src/dividend/PropertyGovernor.sol";

/// @notice Mock stablecoin for integration testing
contract MockUSDC_Int is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @notice Helper mock contract acting as an approved contract (like AMM pool or marketplace)
contract MockApprovedContract {
    DividendDistribution public immutable dividend;
    IERC20 public immutable stablecoin;
    IVotes public immutable votesToken;

    constructor(address dividend_, address stablecoin_, address votesToken_) {
        dividend = DividendDistribution(dividend_);
        stablecoin = IERC20(stablecoin_);
        votesToken = IVotes(votesToken_);
        
        // Self-delegate votes so that it holds active voting power checks on snapshots
        votesToken.delegate(address(this));
    }

    function claim(uint256 maxEpochs) external {
        dividend.claimDividends(maxEpochs);
    }
}

/// @title IntegrationTest
/// @notice End-to-end integration tests that simulate real-world flows
///         across all contracts: KYCRegistry, PropertyToken, PropertyRegistry,
///         TimelockController, DividendDistribution, and PropertyGovernor.
///         These tests validate cross-contract interactions in a single
///         Anvil-backed Foundry environment.
contract IntegrationTest is Test {
    KYCRegistry public kyc;
    PropertyRegistry public registry;
    PropertyToken public token;
    TimelockController public timelock;
    PropertyGovernor public governor;
    DividendDistribution public dividend;
    MockUSDC_Int public usdc;

    address deployer;
    address admin;     // MultiSig (proposer admin)
    address spv;       // Special Purpose Vehicle (depositor)
    address investor1;
    address investor2;
    address investor3;

    uint256 constant TOTAL_SUPPLY    = 1000e18;
    uint256 constant TIMELOCK_DELAY  = 172800; // 2 days

    function setUp() public {
        deployer  = address(this);
        admin     = makeAddr("admin");
        spv       = makeAddr("spv");
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");
        investor3 = makeAddr("investor3");

        // ── Deploy KYCRegistry (Person 1 core) ──────────────────────
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(
            address(kycImpl),
            abi.encodeCall(KYCRegistry.initialize, ())
        );
        kyc = KYCRegistry(address(kycProxy));

        kyc.addUser(deployer);
        kyc.addUser(admin);
        kyc.addUser(spv);
        kyc.addUser(investor1);
        kyc.addUser(investor2);
        kyc.addUser(investor3);

        // ── Deploy PropertyRegistry (Person 1 core) ─────────────────
        PropertyRegistry regImpl = new PropertyRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(PropertyRegistry.initialize, ())
        );
        registry = PropertyRegistry(address(regProxy));

        // ── Deploy PropertyToken via BeaconProxy (Person 1 core) ────
        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(
            address(tokenImpl), deployer
        );
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "RealToken - Apartemen Sudirman Park",
                    "RTASP",
                    TOTAL_SUPPLY,
                    1,               // propertyId
                    address(kyc),
                    deployer
                )
            )
        );
        token = PropertyToken(address(tokenProxy));

        // Register property
        registry.registerProperty(
            "Apartemen Sudirman Park",
            "Jl. Jend. Sudirman No. 1, Jakarta Selatan",
            100 ether,
            "ipfs://QmPropertyDocHash",
            address(token)
        );

        // ── Deploy TimelockController (Person 1 governance) ─────────
        address[] memory empty = new address[](0);
        timelock = new TimelockController(
            TIMELOCK_DELAY, empty, empty, deployer
        );

        // ── Deploy MockUSDC ─────────────────────────────────────────
        usdc = new MockUSDC_Int();

        // ── Deploy DividendDistribution (Person 2) ──────────────────
        dividend = new DividendDistribution(
            address(token),
            address(usdc),
            address(kyc),
            address(timelock) // admin = Timelock
        );

        // ── Deploy PropertyGovernor (Person 2) ──────────────────────
        governor = new PropertyGovernor(
            IVotes(address(token)),
            timelock,
            admin
        );

        // ── Configure roles ─────────────────────────────────────────
        // Governor as proposer + executor on Timelock
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // Timelock as REGISTRY_ADMIN_ROLE for property deactivation
        registry.grantRole(registry.REGISTRY_ADMIN_ROLE(), address(timelock));

        // Timelock as DEPOSITOR on DividendDistribution
        vm.startPrank(address(timelock));
        dividend.grantRole(dividend.DEPOSITOR_ROLE(), address(timelock));
        vm.stopPrank();

        // SPV as DEPOSITOR for regular dividend deposits
        vm.startPrank(address(timelock));
        dividend.grantRole(dividend.DEPOSITOR_ROLE(), spv);
        vm.stopPrank();

        // ── Distribute tokens to investors ──────────────────────────
        token.transfer(investor1, 500e18); // 50%
        token.transfer(investor2, 300e18); // 30%
        token.transfer(investor3, 200e18); // 20%

        // All must delegate to themselves for voting power & dividends
        vm.prank(investor1);
        token.delegate(investor1);
        vm.prank(investor2);
        token.delegate(investor2);
        vm.prank(investor3);
        token.delegate(investor3);

        // Advance blocks for checkpoints
        vm.roll(block.number + 2);

        // Fund SPV with USDC
        usdc.mint(spv, 1_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Integration Test 1: End-to-End Dividend Flow
    //  SPV deposit → investor klaim → multi-epoch → proporsi benar
    // ═══════════════════════════════════════════════════════════════════

    function test_integration_dividendEndToEnd() public {
        // ── Month 1: SPV deposits 10,000 USDC rental income ──────
        vm.startPrank(spv);
        usdc.approve(address(dividend), 10_000e6);
        dividend.depositDividends(10_000e6);
        vm.stopPrank();

        assertEq(dividend.getEpochCount(), 1);

        // Verify proportional pending amounts
        // investor1 (50%): 5000 USDC
        assertEq(dividend.pendingDividends(investor1, type(uint256).max), 5000e6);
        // investor2 (30%): 3000 USDC
        assertEq(dividend.pendingDividends(investor2, type(uint256).max), 3000e6);
        // investor3 (20%): 2000 USDC
        assertEq(dividend.pendingDividends(investor3, type(uint256).max), 2000e6);

        // ── Investor1 claims month 1 ──────────────────────────────
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 5000e6);

        // ── Month 2: Another deposit ──────────────────────────────
        vm.roll(block.number + 1);
        vm.startPrank(spv);
        usdc.approve(address(dividend), 8_000e6);
        dividend.depositDividends(8_000e6);
        vm.stopPrank();

        assertEq(dividend.getEpochCount(), 2);

        // Investor1 already claimed month 1, only month 2 pending
        assertEq(dividend.pendingDividends(investor1, type(uint256).max), 4000e6);
        // Investor2 has both months pending: 3000 + 2400 = 5400
        assertEq(dividend.pendingDividends(investor2, type(uint256).max), 5400e6);

        // ── Month 3: Third deposit ────────────────────────────────
        vm.roll(block.number + 1);
        vm.startPrank(spv);
        usdc.approve(address(dividend), 6_000e6);
        dividend.depositDividends(6_000e6);
        vm.stopPrank();

        assertEq(dividend.getEpochCount(), 3);

        // ── All investors claim remaining ─────────────────────────
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        // investor1: 4000 (month 2) + 3000 (month 3) = 7000
        assertEq(usdc.balanceOf(investor1), 5000e6 + 7000e6);

        vm.prank(investor2);
        dividend.claimDividends(type(uint256).max);
        // investor2: 3000 + 2400 + 1800 = 7200
        assertEq(usdc.balanceOf(investor2), 7200e6);

        vm.prank(investor3);
        dividend.claimDividends(type(uint256).max);
        // investor3: 2000 + 1600 + 1200 = 4800
        assertEq(usdc.balanceOf(investor3), 4800e6);

        // Verify all dividends distributed (10000 + 8000 + 6000 = 24000)
        assertEq(
            usdc.balanceOf(investor1) + usdc.balanceOf(investor2) + usdc.balanceOf(investor3),
            24_000e6
        );
        // Contract should have 0 remaining
        assertEq(usdc.balanceOf(address(dividend)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Integration Test 2: End-to-End Governance Flow
    //  propose → vote → queue → execute (via Timelock)
    // ═══════════════════════════════════════════════════════════════════

    function test_integration_governanceEndToEnd() public {
        // ── Step 1: Admin proposes to update timelock delay ───────
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            TimelockController.updateDelay.selector,
            259200 // New delay: 3 days
        );
        string memory description =
            "Proposal #1: Update timelock delay to 3 days";

        vm.prank(admin);
        uint256 proposalId = governor.proposeWithDocument(
            targets, values, calldatas, description,
            "ipfs://QmProposalDoc_UpdateDelay"
        );

        // Verify initial state
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Pending)
        );
        assertEq(
            governor.getProposalDocument(proposalId),
            "ipfs://QmProposalDoc_UpdateDelay"
        );

        // ── Step 2: Advance past voting delay → Active ───────────
        vm.roll(block.number + governor.votingDelay() + 1);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Active)
        );

        // ── Step 3: Investors vote ───────────────────────────────
        vm.prank(investor1);
        governor.castVoteWithReason(proposalId, 1, "Setuju, 3 hari lebih aman");
        vm.prank(investor2);
        governor.castVote(proposalId, 1); // For
        vm.prank(investor3);
        governor.castVote(proposalId, 2); // Abstain

        // Verify vote tallies
        (uint256 against, uint256 forVotes, uint256 abstain) =
            governor.proposalVotes(proposalId);
        assertEq(forVotes, 800e18);   // investor1 (500) + investor2 (300)
        assertEq(against, 0);
        assertEq(abstain, 200e18);    // investor3 (200)

        // ── Step 4: Advance past voting period → Succeeded ───────
        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded)
        );

        // ── Step 5: Queue → Queued ───────────────────────────────
        governor.queue(
            targets, values, calldatas, keccak256(bytes(description))
        );
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued)
        );

        // ── Step 6: Advance past timelock delay → Execute ────────
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(
            targets, values, calldatas, keccak256(bytes(description))
        );
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Executed)
        );

        // ── Step 7: Verify execution effect ──────────────────────
        assertEq(timelock.getMinDelay(), 259200); // 3 days
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Integration Test 3: KYC + Multi-Epoch Dividend Integration
    //  KYC verification → deposit → revoke KYC → revert claim
    // ═══════════════════════════════════════════════════════════════════

    function test_integration_kycDividendInteraction() public {
        // ── Step 1: SPV deposits dividends ───────────────────────
        vm.startPrank(spv);
        usdc.approve(address(dividend), 5000e6);
        dividend.depositDividends(5000e6);
        vm.stopPrank();

        // ── Step 2: Investor1 (KYC verified) claims successfully ─
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 2500e6); // 50%

        // ── Step 3: Revoke investor2's KYC ───────────────────────
        kyc.removeUser(investor2);

        // ── Step 4: Investor2 (KYC revoked) cannot claim ─────────
        vm.prank(investor2);
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistribution.InvestorNotKYCVerified.selector,
                investor2
            )
        );
        dividend.claimDividends(type(uint256).max);

        // ── Step 5: Restore KYC and claim ────────────────────────
        kyc.addUser(investor2);
        vm.prank(investor2);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor2), 1500e6); // 30%

        // ── Step 6: New epoch after KYC changes ──────────────────
        vm.roll(block.number + 1);
        vm.startPrank(spv);
        usdc.approve(address(dividend), 3000e6);
        dividend.depositDividends(3000e6);
        vm.stopPrank();

        // All investors can claim epoch 2
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 2500e6 + 1500e6); // 50% of 3000

        vm.prank(investor2);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor2), 1500e6 + 900e6); // 30% of 3000

        vm.prank(investor3);
        dividend.claimDividends(type(uint256).max);
        // investor3 claims both epochs: 1000 + 600 = 1600
        assertEq(usdc.balanceOf(investor3), 1600e6);

        // ── Step 7: Approved Contract KYC Bypass Flow ────────────
        // Deploy approved and unapproved mock contracts
        MockApprovedContract approvedContract = new MockApprovedContract(
            address(dividend),
            address(usdc),
            address(token)
        );
        MockApprovedContract unapprovedContract = new MockApprovedContract(
            address(dividend),
            address(usdc),
            address(token)
        );

        // Register approvedContract in KYCRegistry
        kyc.addApprovedContract(address(approvedContract));

        // Assert contract statuses
        assertFalse(kyc.isVerified(address(approvedContract)));
        assertTrue(kyc.isApprovedContract(address(approvedContract)));
        assertFalse(kyc.isVerified(address(unapprovedContract)));
        assertFalse(kyc.isApprovedContract(address(unapprovedContract)));

        // Register unapprovedContract temporarily to allow token transfers
        kyc.addApprovedContract(address(unapprovedContract));

        // Transfer 10% (100 token) of property token to approvedContract
        // and 10% (100 token) to unapprovedContract
        vm.startPrank(investor1);
        token.transfer(address(approvedContract), 100e18);
        token.transfer(address(unapprovedContract), 100e18);
        vm.stopPrank();

        // Revoke approval for unapprovedContract to test the KYC bypass rejection
        kyc.removeApprovedContract(address(unapprovedContract));

        vm.roll(block.number + 1);

        // Deposit new dividends: 1000 USDC (epoch 3)
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // Unapproved contract fails to claim (InvestorNotKYCVerified)
        vm.prank(address(unapprovedContract));
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistribution.InvestorNotKYCVerified.selector,
                address(unapprovedContract)
            )
        );
        unapprovedContract.claim(type(uint256).max);

        // Approved contract successfully claims 10% of 1000 USDC = 100 USDC
        approvedContract.claim(type(uint256).max);
        assertEq(usdc.balanceOf(address(approvedContract)), 100e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Integration Test 4: Full Liquidation Lifecycle
    //  Governance proposal → vote → execute → dividend deposit →
    //  property deactivation → investor claim → burn tokens
    // ═══════════════════════════════════════════════════════════════════

    function test_integration_liquidationFullFlow() public {
        // ── Pre-condition: Deposit one normal dividend epoch first ─
        vm.startPrank(spv);
        usdc.approve(address(dividend), 2000e6);
        dividend.depositDividends(2000e6);
        vm.stopPrank();

        // Investors claim regular dividends
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        vm.prank(investor2);
        dividend.claimDividends(type(uint256).max);
        vm.prank(investor3);
        dividend.claimDividends(type(uint256).max);

        uint256 bal1Before = usdc.balanceOf(investor1); // 1000
        uint256 bal2Before = usdc.balanceOf(investor2); // 600
        uint256 bal3Before = usdc.balanceOf(investor3); // 400

        // ── Step 1: Fund Timelock with sale proceeds ─────────────
        uint256 saleProceeds = 50_000e6; // 50,000 USDC from property sale
        usdc.mint(address(timelock), saleProceeds);

        // ── Step 2: Admin creates liquidation proposal ───────────
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory calldatas = new bytes[](3);

        // Action A: Timelock approves USDC for dividend contract
        targets[0] = address(usdc);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(dividend),
            saleProceeds
        );

        // Action B: Deposit sale proceeds as final dividend
        targets[1] = address(dividend);
        values[1] = 0;
        calldatas[1] = abi.encodeWithSelector(
            DividendDistribution.depositDividends.selector,
            saleProceeds
        );

        // Action C: Deactivate property
        targets[2] = address(registry);
        values[2] = 0;
        calldatas[2] = abi.encodeWithSelector(
            PropertyRegistry.deactivateProperty.selector,
            1
        );

        string memory description =
            "Proposal: Likuidasi Apartemen Sudirman Park - Distribusi hasil penjualan";

        vm.prank(admin);
        uint256 proposalId = governor.proposeWithDocument(
            targets, values, calldatas, description,
            "ipfs://QmLiquidationReport_SudirmanPark_2026"
        );

        // ── Step 3: Voting ───────────────────────────────────────
        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(investor1);
        governor.castVoteWithReason(proposalId, 1, "Setuju likuidasi, harga bagus");
        vm.prank(investor2);
        governor.castVote(proposalId, 1);
        vm.prank(investor3);
        governor.castVote(proposalId, 1); // Unanimous

        // ── Step 4: Queue + Execute ──────────────────────────────
        vm.roll(block.number + governor.votingPeriod() + 1);
        governor.queue(
            targets, values, calldatas, keccak256(bytes(description))
        );

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(
            targets, values, calldatas, keccak256(bytes(description))
        );

        // ── Step 5: Verify property deactivated ──────────────────
        IPropertyRegistry.Property memory prop = registry.getProperty(1);
        assertFalse(prop.isActive);

        // ── Step 6: Verify final dividends deposited ─────────────
        assertEq(dividend.getEpochCount(), 2); // 1 regular + 1 liquidation

        // ── Step 7: Investors claim final dividends ──────────────
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), bal1Before + 25_000e6); // 50%

        vm.prank(investor2);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor2), bal2Before + 15_000e6); // 30%

        vm.prank(investor3);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor3), bal3Before + 10_000e6); // 20%

        // ── Step 8: Investors burn tokens ─────────────────────────
        vm.startPrank(investor1);
        token.burn(token.balanceOf(investor1));
        vm.stopPrank();
        vm.startPrank(investor2);
        token.burn(token.balanceOf(investor2));
        vm.stopPrank();
        vm.startPrank(investor3);
        token.burn(token.balanceOf(investor3));
        vm.stopPrank();

        assertEq(token.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(dividend)), 0);

        // ── Final: Verify IPFS document stored ───────────────────
        assertEq(
            governor.getProposalDocument(proposalId),
            "ipfs://QmLiquidationReport_SudirmanPark_2026"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Integration Test 5: Token Transfer Between Epochs
    //  Verifies snapshot isolation across dividend epochs
    // ═══════════════════════════════════════════════════════════════════

    function test_integration_tokenTransferBetweenEpochs() public {
        // ── Epoch 0: Initial distribution ────────────────────────
        vm.startPrank(spv);
        usdc.approve(address(dividend), 20_000e6);
        dividend.depositDividends(10_000e6);
        vm.stopPrank();

        // Epoch 0 snapshot: investor1=500, investor2=300, investor3=200

        // ── Investor1 transfers 200 tokens to investor3 ──────────
        vm.prank(investor1);
        token.transfer(investor3, 200e18);
        vm.roll(block.number + 1);

        // ── Epoch 1: After transfer ──────────────────────────────
        vm.startPrank(spv);
        dividend.depositDividends(10_000e6);
        vm.stopPrank();

        // Epoch 1 snapshot: investor1=300, investor2=300, investor3=400

        // ── Verify epoch 0 uses OLD balances ─────────────────────
        // investor1 epoch0 = 50% of 10000 = 5000
        // investor1 epoch1 = 30% of 10000 = 3000
        // Total investor1 = 8000
        assertEq(dividend.pendingDividends(investor1, type(uint256).max), 8000e6);

        // investor3 epoch0 = 20% of 10000 = 2000
        // investor3 epoch1 = 40% of 10000 = 4000
        // Total investor3 = 6000
        assertEq(dividend.pendingDividends(investor3, type(uint256).max), 6000e6);

        // investor2 unchanged: 30% * 2 * 10000 = 6000
        assertEq(dividend.pendingDividends(investor2, type(uint256).max), 6000e6);

        // ── All claim and verify ─────────────────────────────────
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        vm.prank(investor2);
        dividend.claimDividends(type(uint256).max);
        vm.prank(investor3);
        dividend.claimDividends(type(uint256).max);

        // Total distributed should equal total deposited
        assertEq(
            usdc.balanceOf(investor1) + usdc.balanceOf(investor2) + usdc.balanceOf(investor3),
            20_000e6
        );
    }
}
