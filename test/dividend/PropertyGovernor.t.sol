// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../contracts/core/PropertyToken.sol";
import "../../contracts/core/PropertyRegistry.sol";
import "../../contracts/core/KYCRegistry.sol";
import "../../contracts/dividend/DividendDistribution.sol";
import "../../contracts/dividend/PropertyGovernor.sol";

/// @notice Mock stablecoin for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title PropertyGovernorTest
/// @notice Tests for the PropertyGovernor DAO governance contract.
///         Covers: admin-only propose, 10% quorum, IPFS document storage,
///         liquidation (burn) flow, and voting mechanics.
contract PropertyGovernorTest is Test {
    KYCRegistry public kyc;
    PropertyRegistry public registry;
    PropertyToken public token;
    TimelockController public timelock;
    PropertyGovernor public governor;
    DividendDistribution public dividend;
    MockUSDC public usdc;

    address admin;    // proposer admin (MultiSig)
    address voter1;
    address voter2;
    address voter3;

    uint256 constant TOTAL_SUPPLY  = 1000e18;
    uint256 constant TIMELOCK_DELAY = 172800; // 2 days in seconds

    function setUp() public {
        admin = makeAddr("admin");
        voter1 = makeAddr("voter1");
        voter2 = makeAddr("voter2");
        voter3 = makeAddr("voter3");

        // ── Deploy KYCRegistry via UUPS proxy ───────────────
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(
            address(kycImpl),
            abi.encodeCall(KYCRegistry.initialize, ())
        );
        kyc = KYCRegistry(address(kycProxy));

        // Add KYC
        kyc.addUser(address(this), 1);
        kyc.addUser(admin, 1);
        kyc.addUser(voter1, 1);
        kyc.addUser(voter2, 1);
        kyc.addUser(voter3, 1);

        // ── Deploy PropertyRegistry via UUPS proxy ──────────
        PropertyRegistry regImpl = new PropertyRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(PropertyRegistry.initialize, ())
        );
        registry = PropertyRegistry(address(regProxy));

        // ── Deploy PropertyToken via BeaconProxy ────────────
        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(
            address(tokenImpl), address(this)
        );
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "RealToken - Jl. Sudirman No. 1",
                    "RTJKS1",
                    TOTAL_SUPPLY,
                    1,
                    address(kyc),
                    1,
                    address(this) // owner = test contract
                )
            )
        );
        token = PropertyToken(address(tokenProxy));

        // Register property in registry
        registry.registerProperty(
            "Apartemen Sudirman Park",
            "Jl. Jend. Sudirman No. 1, Jakarta Selatan",
            100 ether,
            "ipfs://QmExamplePropertyDocHash",
            address(token)
        );

        // Distribute tokens to voters
        token.transfer(voter1, 400e18); // 40%
        token.transfer(voter2, 350e18); // 35%
        token.transfer(voter3, 250e18); // 25%

        // All must delegate to themselves for voting power
        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);
        vm.prank(voter3);
        token.delegate(voter3);

        // Move 1 block for checkpoints to be readable
        vm.roll(block.number + 1);

        // ── Deploy TimelockController ───────────────────────
        address[] memory empty = new address[](0);
        timelock = new TimelockController(
            TIMELOCK_DELAY, empty, empty, address(this)
        );

        // ── Deploy PropertyGovernor with admin as proposer ──
        governor = new PropertyGovernor(
            IVotes(address(token)),
            timelock,
            admin  // hanya admin yang bisa propose
        );

        // Grant Governor as proposer and executor on Timelock
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // Grant Timelock the REGISTRY_ADMIN_ROLE for property deactivation
        registry.grantRole(registry.REGISTRY_ADMIN_ROLE(), address(timelock));

        // ── Deploy MockUSDC + DividendDistribution ──────────
        usdc = new MockUSDC();
        dividend = new DividendDistribution(
            address(token),
            address(usdc),
            address(kyc),
            address(timelock) // admin = Timelock for governance control
        );

        // Grant Timelock as DEPOSITOR on DividendDistribution
        vm.startPrank(address(timelock));
        dividend.grantRole(dividend.DEPOSITOR_ROLE(), address(timelock));
        vm.stopPrank();

        // Move another block so quorum queries work correctly
        vm.roll(block.number + 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Helper Functions
    // ═══════════════════════════════════════════════════════════════════

    function _createDummyProposal()
        internal
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        )
    {
        targets = new address[](1);
        targets[0] = address(timelock);

        values = new uint256[](1);
        values[0] = 0;

        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            TimelockController.updateDelay.selector,
            TIMELOCK_DELAY
        );

        description = "Proposal #1: Maintain timelock delay";
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Configuration Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_governor_name() public {
        assertEq(governor.name(), "PropertyGovernor");
    }

    function test_governor_votingDelay() public {
        assertEq(governor.votingDelay(), 7200);
    }

    function test_governor_votingPeriod() public {
        assertEq(governor.votingPeriod(), 36000);
    }

    function test_governor_proposerAdmin() public {
        assertEq(governor.proposerAdmin(), admin);
    }

    function test_governor_quorum_is10Percent() public {
        // 10% of 1000e18 = 100e18
        uint256 q = governor.quorum(block.number - 1);
        assertEq(q, 100e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Admin-Only Proposal Access
    // ═══════════════════════════════════════════════════════════════════

    function test_propose_onlyAdmin_success() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        // Admin can propose
        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );
        assertTrue(proposalId > 0);
    }

    function test_propose_revertIfNotAdmin() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        // voter1 (non-admin) cannot propose even with 40% tokens
        vm.prank(voter1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyGovernor.OnlyProposerAdmin.selector,
                voter1,
                admin
            )
        );
        governor.propose(targets, values, calldatas, description);
    }

    function test_propose_revertIfRandomAddress() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyGovernor.OnlyProposerAdmin.selector,
                attacker,
                admin
            )
        );
        governor.propose(targets, values, calldatas, description);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  IPFS Document Proposals
    // ═══════════════════════════════════════════════════════════════════

    function test_proposeWithDocument() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        string memory ipfsURI = "ipfs://QmProposalDocumentHash123";

        vm.prank(admin);
        uint256 proposalId = governor.proposeWithDocument(
            targets, values, calldatas, description, ipfsURI
        );

        // Verify document was stored
        assertEq(governor.getProposalDocument(proposalId), ipfsURI);
    }

    function test_proposeWithDocument_emitsEvent() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        string memory ipfsURI = "ipfs://QmProposalDocumentHash456";

        uint256 expectedId = governor.hashProposal(
            targets, values, calldatas, keccak256(bytes(description))
        );

        vm.expectEmit(true, false, false, true);
        emit PropertyGovernor.ProposalDocumentSet(expectedId, ipfsURI);

        vm.prank(admin);
        governor.proposeWithDocument(
            targets, values, calldatas, description, ipfsURI
        );
    }

    function test_proposeWithDocument_revertEmptyURI() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyGovernor.EmptyDocumentURI.selector)
        );
        governor.proposeWithDocument(
            targets, values, calldatas, description, ""
        );
    }

    function test_proposeWithDocument_revertIfNotAdmin() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        // voter1 cannot propose even with document
        vm.prank(voter1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyGovernor.OnlyProposerAdmin.selector,
                voter1,
                admin
            )
        );
        governor.proposeWithDocument(
            targets, values, calldatas, description, "ipfs://Qm..."
        );
    }

    function test_proposalWithoutDocument_returnsEmpty() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        assertEq(bytes(governor.getProposalDocument(proposalId)).length, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Full Proposal Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    function test_fullProposalLifecycle() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        // 1. Admin proposes
        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Pending)
        );

        // 2. Advance past votingDelay → Active
        vm.roll(block.number + governor.votingDelay() + 1);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Active)
        );

        // 3. Investors vote
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For

        // 4. Advance past votingPeriod → Succeeded
        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded)
        );

        // 5. Queue → Queued
        governor.queue(
            targets, values, calldatas, keccak256(bytes(description))
        );
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued)
        );

        // 6. Advance past timelock delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // 7. Execute → Executed
        governor.execute(
            targets, values, calldatas, keccak256(bytes(description))
        );
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Executed)
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Property Liquidation Flow (Jual Properti + Burn)
    // ═══════════════════════════════════════════════════════════════════

    function test_liquidationFullLifecycle() public {
        uint256 saleProceeds = 5000e6; // 5000 USDC dari penjualan properti

        // Fund the Timelock with USDC (simulating sale proceeds received)
        usdc.mint(address(timelock), saleProceeds);

        // ── Step 1: Admin creates liquidation proposal ──────
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

        // Action B: Deposit dividends (proceeds from property sale)
        targets[1] = address(dividend);
        values[1] = 0;
        calldatas[1] = abi.encodeWithSelector(
            DividendDistribution.depositDividends.selector,
            saleProceeds
        );

        // Action C: Deactivate property in registry
        targets[2] = address(registry);
        values[2] = 0;
        calldatas[2] = abi.encodeWithSelector(
            PropertyRegistry.deactivateProperty.selector,
            1 // propertyId = 1
        );

        string memory description =
            "Proposal: Likuidasi Properti Sudirman Park - Jual dan distribusi hasil";

        // ── Step 2: Admin proposes with document ─────────────
        vm.prank(admin);
        uint256 proposalId = governor.proposeWithDocument(
            targets, values, calldatas, description,
            "ipfs://QmLiquidationReport_SudirmanPark"
        );

        // ── Step 3: Investors vote ───────────────────────────
        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For
        vm.prank(voter3);
        governor.castVote(proposalId, 1); // For (unanimous)

        // ── Step 4: Queue + Execute via Timelock ─────────────
        vm.roll(block.number + governor.votingPeriod() + 1);
        governor.queue(
            targets, values, calldatas, keccak256(bytes(description))
        );

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(
            targets, values, calldatas, keccak256(bytes(description))
        );

        // ── Step 5: Verify results ───────────────────────────
        // Property should be deactivated
        IPropertyRegistry.Property memory prop = registry.getProperty(1);
        assertFalse(prop.isActive);

        // Dividends should be deposited
        assertEq(dividend.getEpochCount(), 1);

        // ── Step 6: Investors claim final dividends ──────────
        // voter1 (400/1000 = 40%) → 2000 USDC
        assertEq(dividend.pendingDividends(voter1), 2000e6);
        vm.prank(voter1);
        dividend.claimDividends();
        assertEq(usdc.balanceOf(voter1), 2000e6);

        // voter2 (350/1000 = 35%) → 1750 USDC
        vm.prank(voter2);
        dividend.claimDividends();
        assertEq(usdc.balanceOf(voter2), 1750e6);

        // voter3 (250/1000 = 25%) → 1250 USDC
        vm.prank(voter3);
        dividend.claimDividends();
        assertEq(usdc.balanceOf(voter3), 1250e6);

        // ── Step 7: Investors burn their tokens ──────────────
        vm.startPrank(voter1);
        token.burn(token.balanceOf(voter1));
        vm.stopPrank();
        assertEq(token.balanceOf(voter1), 0);

        vm.startPrank(voter2);
        token.burn(token.balanceOf(voter2));
        vm.stopPrank();
        assertEq(token.balanceOf(voter2), 0);

        vm.startPrank(voter3);
        token.burn(token.balanceOf(voter3));
        vm.stopPrank();
        assertEq(token.balanceOf(voter3), 0);

        // Total supply should be 0
        assertEq(token.totalSupply(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Edge Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_proposalDefeated_quorumNotMet() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        // Admin proposes
        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        // Advance to active
        vm.roll(block.number + governor.votingDelay() + 1);

        // No votes cast — advance past voting period
        vm.roll(block.number + governor.votingPeriod() + 1);

        // Should be Defeated (no quorum)
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated)
        );
    }

    function test_proposalDefeated_majorityAgainst() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        vm.roll(block.number + governor.votingDelay() + 1);

        // voter1 (400e18) votes Against, voter2 (350e18) votes For
        vm.prank(voter1);
        governor.castVote(proposalId, 0); // Against
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For

        vm.roll(block.number + governor.votingPeriod() + 1);

        // Defeated because Against > For
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated)
        );
    }

    function test_votingPower_fromSnapshot() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        // Admin proposes
        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        // Transfer tokens AFTER proposal (before voting)
        vm.prank(voter1);
        token.transfer(voter3, 400e18);

        // Advance to voting
        vm.roll(block.number + governor.votingDelay() + 1);

        // voter1 still has snapshot voting power (400e18 before transfer)
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // voter3 snapshot power = 250e18 (before transfer)
        vm.prank(voter3);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + governor.votingPeriod() + 1);

        // voter1 (400) + voter3 (250) = 650 > 100 quorum (10%)
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded)
        );
    }

    function test_cannotVoteTwice() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        vm.prank(voter1);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test_cannotVoteBeforeActive() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        // Try to vote while still Pending
        vm.prank(voter1);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test_constructor_revertZeroProposerAdmin() public {
        vm.expectRevert("Governor: zero proposer admin");
        new PropertyGovernor(
            IVotes(address(token)),
            timelock,
            address(0) // zero proposer admin
        );
    }

    function test_castVoteWithReason() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        vm.roll(block.number + governor.votingDelay() + 1);

        // voter1 votes with reason
        vm.prank(voter1);
        governor.castVoteWithReason(
            proposalId, 1, "Setuju karena proposal ini menguntungkan investor"
        );

        // voter2 votes against with reason
        vm.prank(voter2);
        governor.castVoteWithReason(
            proposalId, 0, "Tidak setuju, perlu revisi terlebih dulu"
        );

        assertTrue(governor.hasVoted(proposalId, voter1));
        assertTrue(governor.hasVoted(proposalId, voter2));
    }

    function test_proposalSucceeded_exactQuorum() public {
        // Deploy a new setup where one voter has exactly 10% (100e18)
        // voter3 has 250e18 (25% > 10%), so just voter3 voting = quorum met
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        vm.roll(block.number + governor.votingDelay() + 1);

        // Only voter3 (250e18 = 25%) votes For — quorum is 100e18 (10%)
        vm.prank(voter3);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + governor.votingPeriod() + 1);

        // Should succeed: 250e18 > 100e18 quorum, For > Against
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded)
        );
    }

    function test_abstainVote_countsForQuorum() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(
            targets, values, calldatas, description
        );

        vm.roll(block.number + governor.votingDelay() + 1);

        // voter3 (250e18) votes Abstain (2) — counts towards quorum
        vm.prank(voter3);
        governor.castVote(proposalId, 2); // Abstain

        // voter1 (400e18) votes For
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For

        vm.roll(block.number + governor.votingPeriod() + 1);

        // Quorum met (250 + 400 = 650 > 100), For (400) > Against (0)
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded)
        );
    }
}
