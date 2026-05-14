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
import "../../contracts/core/KYCRegistry.sol";
import "../../contracts/dividend/DividendDistribution.sol";
import "../../contracts/dividend/PropertyGovernor.sol";

/// @notice Mock USDC for fuzz testing
contract MockUSDC_Fuzz is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title DividendFuzzTest
/// @notice Fuzz tests for DividendDistribution — validates proportionality,
///         balance invariants, and epoch consistency with random inputs.
contract DividendFuzzTest is Test {
    KYCRegistry public kyc;
    PropertyToken public token;
    DividendDistribution public dividend;
    MockUSDC_Fuzz public usdc;

    address admin;
    address spv;
    address investor1;
    address investor2;

    uint256 constant TOTAL_SUPPLY = 1000e18;

    function setUp() public {
        admin     = makeAddr("admin");
        spv       = makeAddr("spv");
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");

        // Deploy KYCRegistry
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(
            address(kycImpl),
            abi.encodeCall(KYCRegistry.initialize, ())
        );
        kyc = KYCRegistry(address(kycProxy));

        kyc.addUser(address(this), 1);
        kyc.addUser(spv, 2);
        kyc.addUser(investor1, 1);
        kyc.addUser(investor2, 1);

        // Deploy PropertyToken
        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), address(this));
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "RealToken - Fuzz Test",
                    "RTFZ",
                    TOTAL_SUPPLY,
                    1,
                    address(kyc),
                    1,
                    address(this)
                )
            )
        );
        token = PropertyToken(address(tokenProxy));

        // Distribute: investor1 = 700 (70%), investor2 = 300 (30%)
        token.transfer(investor1, 700e18);
        token.transfer(investor2, 300e18);

        vm.prank(investor1);
        token.delegate(investor1);
        vm.prank(investor2);
        token.delegate(investor2);

        vm.roll(block.number + 1);

        // Deploy USDC & Dividend
        usdc = new MockUSDC_Fuzz();
        dividend = new DividendDistribution(
            address(token), address(usdc), address(kyc), admin
        );

        vm.startPrank(admin);
        dividend.grantRole(dividend.DEPOSITOR_ROLE(), spv);
        vm.stopPrank();

        usdc.mint(spv, type(uint128).max);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 1: Proportional dividend distribution with random amounts
    // ═══════════════════════════════════════════════════════════════════

    /// @notice For any deposit amount, investor1 gets ~70% and investor2 ~30%
    function testFuzz_proportionalDistribution(uint256 amount) public {
        // Bound to realistic USDC range: 1 USDC to 100M USDC
        amount = bound(amount, 1e6, 100_000_000e6);

        vm.startPrank(spv);
        usdc.approve(address(dividend), amount);
        dividend.depositDividends(amount);
        vm.stopPrank();

        uint256 pending1 = dividend.pendingDividends(investor1, type(uint256).max);
        uint256 pending2 = dividend.pendingDividends(investor2, type(uint256).max);

        // Expected: investor1 = amount * 700/1000, investor2 = amount * 300/1000
        uint256 expected1 = (amount * 700) / 1000;
        uint256 expected2 = (amount * 300) / 1000;

        // Allow small tolerance for rounding due to PRECISION division
        assertApproxEqAbs(pending1, expected1, 1000, "investor1 proportion wrong");
        assertApproxEqAbs(pending2, expected2, 1000, "investor2 proportion wrong");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 2: Contract balance invariant — balance >= sum of pending
    // ═══════════════════════════════════════════════════════════════════

    /// @notice After deposit, contract balance must be >= total pending dividends
    function testFuzz_balanceInvariant(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        vm.startPrank(spv);
        usdc.approve(address(dividend), amount);
        dividend.depositDividends(amount);
        vm.stopPrank();

        uint256 contractBalance = usdc.balanceOf(address(dividend));
        uint256 totalPending = dividend.pendingDividends(investor1, type(uint256).max)
            + dividend.pendingDividends(investor2, type(uint256).max);

        // Invariant: contract balance >= total pending (dust from rounding stays)
        assertTrue(
            contractBalance >= totalPending,
            "Contract balance less than total pending"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 3: Multiple epochs with random amounts — no fund leakage
    // ═══════════════════════════════════════════════════════════════════

    /// @notice After multiple random deposits and full claims, contract balance = 0 (or dust)
    function testFuzz_multiEpochNoLeakage(
        uint256 amount1,
        uint256 amount2,
        uint256 amount3
    ) public {
        amount1 = bound(amount1, 1e6, 10_000_000e6);
        amount2 = bound(amount2, 1e6, 10_000_000e6);
        amount3 = bound(amount3, 1e6, 10_000_000e6);

        uint256 totalDeposited = amount1 + amount2 + amount3;

        // Deposit 3 epochs with random amounts
        vm.startPrank(spv);
        usdc.approve(address(dividend), totalDeposited);

        dividend.depositDividends(amount1);
        vm.roll(block.number + 1);
        dividend.depositDividends(amount2);
        vm.roll(block.number + 1);
        dividend.depositDividends(amount3);
        vm.stopPrank();

        assertEq(dividend.getEpochCount(), 3);

        // Both investors claim all
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        vm.prank(investor2);
        dividend.claimDividends(type(uint256).max);

        uint256 totalClaimed = usdc.balanceOf(investor1) + usdc.balanceOf(investor2);
        uint256 remaining = usdc.balanceOf(address(dividend));

        // Invariant: totalClaimed + remaining == totalDeposited
        assertEq(
            totalClaimed + remaining,
            totalDeposited,
            "Fund leakage detected"
        );

        // Dust should be minimal (bounded by number of epochs * holders rounding)
        assertTrue(remaining <= 3000, "Excessive dust remaining");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 4: Random deposit amount — epoch data consistency
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Epoch data (block, supply, amount, cumulative) must be consistent
    function testFuzz_epochDataConsistency(uint256 amount) public {
        amount = bound(amount, 1, 100_000_000e6);

        uint256 blockBefore = block.number;

        vm.startPrank(spv);
        usdc.approve(address(dividend), amount);
        dividend.depositDividends(amount);
        vm.stopPrank();

        DividendDistribution.DividendEpoch memory epoch = dividend.getEpoch(0);

        // Block must be block.number - 1 at time of deposit
        assertEq(epoch.blockNumber, blockBefore - 1, "Wrong snapshot block");

        // Supply must match total supply at snapshot
        assertEq(epoch.totalSupply, TOTAL_SUPPLY, "Wrong total supply");

        // Amount deposited must match
        assertEq(epoch.amountDeposited, amount, "Wrong amount deposited");

        // Cumulative must be (amount * PRECISION) / supply
        uint256 expectedCumul = (amount * 1e18) / TOTAL_SUPPLY;
        assertEq(epoch.dividendPerTokenCumul, expectedCumul, "Wrong cumulative");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 5: Double-claim prevention with random amounts
    // ═══════════════════════════════════════════════════════════════════

    /// @notice After claiming, second claim must always revert
    function testFuzz_doubleClaim_alwaysReverts(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        vm.startPrank(spv);
        usdc.approve(address(dividend), amount);
        dividend.depositDividends(amount);
        vm.stopPrank();

        // First claim succeeds
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);

        // Second claim must always revert
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.NothingToClaim.selector)
        );
        dividend.claimDividends(type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 6: Pagination boundary with random maxEpochs
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Pagination with any valid maxEpochs should not lose funds
    function testFuzz_paginationNoLoss(uint256 maxEpochs) public {
        maxEpochs = bound(maxEpochs, 1, 100);

        // Deposit 5 epochs
        vm.startPrank(spv);
        usdc.approve(address(dividend), 5000e6);
        for (uint256 i = 0; i < 5; i++) {
            dividend.depositDividends(1000e6);
            vm.roll(block.number + 1);
        }
        vm.stopPrank();

        // Claim with bounded maxEpochs repeatedly until nothing left
        uint256 totalClaimed = 0;
        for (uint256 j = 0; j < 10; j++) {
            uint256 pending = dividend.pendingDividends(investor1, maxEpochs);
            if (pending == 0) break;
            vm.prank(investor1);
            dividend.claimDividends(maxEpochs);
            totalClaimed += pending;
        }

        // investor1 (70%) should get exactly 3500 USDC from 5000 total
        assertEq(totalClaimed, 3500e6, "Pagination caused fund loss");
    }
}

/// @title GovernorFuzzTest
/// @notice Fuzz tests for PropertyGovernor — validates quorum thresholds,
///         vote weight accuracy, and voting period boundaries.
contract GovernorFuzzTest is Test {
    KYCRegistry public kyc;
    PropertyToken public token;
    TimelockController public timelock;
    PropertyGovernor public governor;

    address admin;
    address voter1;
    address voter2;
    address voter3;

    uint256 constant TOTAL_SUPPLY   = 1000e18;
    uint256 constant TIMELOCK_DELAY = 172800;

    function setUp() public {
        admin  = makeAddr("admin");
        voter1 = makeAddr("voter1");
        voter2 = makeAddr("voter2");
        voter3 = makeAddr("voter3");

        // Deploy KYC
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(
            address(kycImpl),
            abi.encodeCall(KYCRegistry.initialize, ())
        );
        kyc = KYCRegistry(address(kycProxy));

        kyc.addUser(address(this), 1);
        kyc.addUser(admin, 1);
        kyc.addUser(voter1, 1);
        kyc.addUser(voter2, 1);
        kyc.addUser(voter3, 1);

        // Deploy PropertyToken
        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), address(this));
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "RealToken - Fuzz Gov", "RTFG",
                    TOTAL_SUPPLY, 1, address(kyc), 1, address(this)
                )
            )
        );
        token = PropertyToken(address(tokenProxy));

        // Distribute
        token.transfer(voter1, 400e18);
        token.transfer(voter2, 350e18);
        token.transfer(voter3, 250e18);

        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);
        vm.prank(voter3);
        token.delegate(voter3);

        vm.roll(block.number + 1);

        // Deploy Timelock + Governor
        address[] memory empty = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, empty, empty, address(this));

        governor = new PropertyGovernor(
            IVotes(address(token)), timelock, admin
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));

        vm.roll(block.number + 1);
    }

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
        description = "Fuzz proposal";
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 7: Quorum threshold with random vote combinations
    // ═══════════════════════════════════════════════════════════════════

    /// @notice If totalVotes >= 10% of supply and forVotes > againstVotes → Succeeded
    ///         Otherwise → Defeated
    function testFuzz_quorumOutcome(
        bool voter1Votes,
        uint8 voter1Support,  // 0=Against, 1=For, 2=Abstain
        bool voter2Votes,
        uint8 voter2Support,
        bool voter3Votes,
        uint8 voter3Support
    ) public {
        // Bound support values to valid range
        voter1Support = uint8(bound(voter1Support, 0, 2));
        voter2Support = uint8(bound(voter2Support, 0, 2));
        voter3Support = uint8(bound(voter3Support, 0, 2));

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + governor.votingDelay() + 1);

        // Cast votes based on fuzz inputs
        uint256 forTotal = 0;
        uint256 againstTotal = 0;
        uint256 abstainTotal = 0;

        if (voter1Votes) {
            vm.prank(voter1);
            governor.castVote(proposalId, voter1Support);
            if (voter1Support == 0) againstTotal += 400e18;
            else if (voter1Support == 1) forTotal += 400e18;
            else abstainTotal += 400e18;
        }
        if (voter2Votes) {
            vm.prank(voter2);
            governor.castVote(proposalId, voter2Support);
            if (voter2Support == 0) againstTotal += 350e18;
            else if (voter2Support == 1) forTotal += 350e18;
            else abstainTotal += 350e18;
        }
        if (voter3Votes) {
            vm.prank(voter3);
            governor.castVote(proposalId, voter3Support);
            if (voter3Support == 0) againstTotal += 250e18;
            else if (voter3Support == 1) forTotal += 250e18;
            else abstainTotal += 250e18;
        }

        vm.roll(block.number + governor.votingPeriod() + 1);

        uint256 quorum = 100e18; // 10% of 1000
        uint256 totalParticipation = forTotal + againstTotal + abstainTotal;

        IGovernor.ProposalState finalState = governor.state(proposalId);

        if (totalParticipation >= quorum && forTotal > againstTotal) {
            assertEq(
                uint256(finalState),
                uint256(IGovernor.ProposalState.Succeeded),
                "Should succeed: quorum met and majority for"
            );
        } else {
            assertEq(
                uint256(finalState),
                uint256(IGovernor.ProposalState.Defeated),
                "Should be defeated: quorum not met or majority against"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 8: Vote weight always matches snapshot token balance
    // ═══════════════════════════════════════════════════════════════════

    /// @notice After random token transfers, vote weight must match snapshot
    function testFuzz_voteWeightMatchesSnapshot(uint256 transferAmount) public {
        // voter1 has 400e18, transfer some to voter3
        transferAmount = bound(transferAmount, 0, 400e18);

        if (transferAmount > 0) {
            vm.prank(voter1);
            token.transfer(voter3, transferAmount);
            vm.roll(block.number + 1);
        }

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // Snapshot is taken at proposal creation block
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        vm.roll(block.number + governor.votingDelay() + 1);

        // Get voting power at snapshot
        uint256 voter1Power = token.getPastVotes(voter1, snapshotBlock);
        uint256 voter3Power = token.getPastVotes(voter3, snapshotBlock);

        // Vote
        vm.prank(voter1);
        governor.castVote(proposalId, 1);
        vm.prank(voter3);
        governor.castVote(proposalId, 1);

        // Verify tallies match snapshot voting power
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, voter1Power + voter3Power, "Vote weight mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Fuzz 9: IPFS document storage with random-length strings
    // ═══════════════════════════════════════════════════════════════════

    /// @notice IPFS URI of any non-empty length must be stored correctly
    function testFuzz_ipfsDocumentStorage(string memory ipfsURI) public {
        vm.assume(bytes(ipfsURI).length > 0);
        vm.assume(bytes(ipfsURI).length <= 256); // Reasonable IPFS CID length

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _createDummyProposal();

        vm.prank(admin);
        uint256 proposalId = governor.proposeWithDocument(
            targets, values, calldatas, description, ipfsURI
        );

        assertEq(
            governor.getProposalDocument(proposalId),
            ipfsURI,
            "IPFS URI not stored correctly"
        );
    }
}
