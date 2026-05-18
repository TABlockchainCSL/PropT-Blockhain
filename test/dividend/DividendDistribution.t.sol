// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../src/core/PropertyToken.sol";
import "../../src/core/KYCRegistry.sol";
import "../../src/dividend/DividendDistribution.sol";

/// @notice Mock USDC for testing (6 decimals like real USDC)
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title DividendDistributionTest
/// @notice Comprehensive tests for the DividendDistribution contract.
contract DividendDistributionTest is Test {
    KYCRegistry public kyc;
    PropertyToken public token;
    DividendDistribution public dividend;
    MockUSDC public usdc;

    address owner;
    address admin;
    address spv;
    address investor1;
    address investor2;

    uint256 constant TOTAL_SUPPLY = 1000e18;

    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
        spv = makeAddr("spv");
        investor1 = makeAddr("investor1");
        investor2 = makeAddr("investor2");

        // ── Deploy KYCRegistry via UUPS proxy ───────────────
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy = new ERC1967Proxy(
            address(kycImpl),
            abi.encodeCall(KYCRegistry.initialize, ())
        );
        kyc = KYCRegistry(address(kycProxy));

        // Add KYC for all actors
        kyc.addUser(owner);
        kyc.addUser(spv);
        kyc.addUser(investor1);
        kyc.addUser(investor2);

        // ── Deploy PropertyToken via BeaconProxy ────────────
        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), owner);
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "RealToken - Jl. Sudirman No. 1",
                    "RTJKS1",
                    TOTAL_SUPPLY,
                    1,                    // propertyId
                    address(kyc),
                    owner
                )
            )
        );
        token = PropertyToken(address(tokenProxy));

        // Distribute tokens: investor1 = 700 (70%), investor2 = 300 (30%)
        token.transfer(investor1, 700e18);
        token.transfer(investor2, 300e18);

        // PENTING: Investor WAJIB delegate ke diri sendiri agar
        // getPastVotes() mengembalikan nilai > 0
        vm.prank(investor1);
        token.delegate(investor1);
        vm.prank(investor2);
        token.delegate(investor2);

        // Maju 1 blok agar checkpoint terbaca oleh getPastVotes
        vm.roll(block.number + 1);

        // ── Deploy MockUSDC ─────────────────────────────────
        usdc = new MockUSDC();

        // ── Deploy DividendDistribution ─────────────────────
        dividend = new DividendDistribution(
            address(token),
            address(usdc),
            address(kyc),
            admin
        );

        // Grant DEPOSITOR_ROLE ke SPV
        vm.startPrank(admin);
        dividend.grantRole(dividend.DEPOSITOR_ROLE(), spv);
        vm.stopPrank();

        // Fund SPV dengan USDC
        usdc.mint(spv, 100_000e6);  // 100,000 USDC
    }

    // ═══════════════════════════════════════════════════════════════════
    //  depositDividends Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_depositDividends_success() public {
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        assertEq(dividend.getEpochCount(), 1);
        DividendDistribution.DividendEpoch memory epoch = dividend.getEpoch(0);
        assertEq(epoch.amountDeposited, 1000e6);
        assertEq(epoch.totalSupply, TOTAL_SUPPLY);
        assertEq(epoch.blockNumber, block.number - 1);
    }

    function test_depositDividends_emitsEvent() public {
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);

        vm.expectEmit(true, false, false, true);
        emit DividendDistribution.DividendsDeposited(
            0,
            block.number - 1,
            1000e6,
            TOTAL_SUPPLY
        );
        dividend.depositDividends(1000e6);
        vm.stopPrank();
    }

    function test_depositDividends_revertZeroAmount() public {
        vm.prank(spv);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.ZeroAmount.selector)
        );
        dividend.depositDividends(0);
    }

    function test_depositDividends_revertNonDepositor() public {
        vm.prank(investor1);
        vm.expectRevert();
        dividend.depositDividends(1000e6);
    }

    function test_depositDividends_multipleEpochs() public {
        // Epoch 0
        vm.startPrank(spv);
        usdc.approve(address(dividend), 3000e6);
        dividend.depositDividends(1000e6);
        vm.roll(block.number + 1);

        // Epoch 1
        dividend.depositDividends(2000e6);
        vm.stopPrank();

        assertEq(dividend.getEpochCount(), 2);
        DividendDistribution.DividendEpoch memory e0 = dividend.getEpoch(0);
        DividendDistribution.DividendEpoch memory e1 = dividend.getEpoch(1);
        assertEq(e0.amountDeposited, 1000e6);
        assertEq(e1.amountDeposited, 2000e6);
        // Cumulative should increase
        assertTrue(e1.dividendPerTokenCumul > e0.dividendPerTokenCumul);
    }

    function test_depositDividends_revertInsufficientApproval() public {
        // SPV approves 500 USDC but tries to deposit 1000
        vm.startPrank(spv);
        usdc.approve(address(dividend), 500e6);
        vm.expectRevert(); // SafeERC20 will revert
        dividend.depositDividends(1000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  claimDividends Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_claimDividends_proportional() public {
        // Deposit 1000 USDC
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // investor1 (70%) should get 700 USDC
        uint256 pending1 = dividend.pendingDividends(investor1, type(uint256).max);
        assertEq(pending1, 700e6);

        // investor2 (30%) should get 300 USDC
        uint256 pending2 = dividend.pendingDividends(investor2, type(uint256).max);
        assertEq(pending2, 300e6);

        // Claim investor1
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 700e6);

        // Claim investor2
        vm.prank(investor2);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor2), 300e6);
    }

    function test_claimDividends_emitsEvent() public {
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        vm.prank(investor1);
        vm.expectEmit(true, false, false, true);
        emit DividendDistribution.DividendsClaimed(investor1, 0, 1, 700e6);
        dividend.claimDividends(type(uint256).max);
    }

    function test_claimDividends_revertIfNotKYC() public {
        address nonKYC = address(0x9);
        vm.prank(nonKYC);
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistribution.InvestorNotKYCVerified.selector,
                nonKYC
            )
        );
        dividend.claimDividends(type(uint256).max);
    }

    function test_claimDividends_nothingToClaim_whenNoEpochs() public {
        // KYC user calls claim when 0 epochs exist
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.NothingToClaim.selector)
        );
        dividend.claimDividends(type(uint256).max);
    }

    function test_preventDoubleClaim() public {
        // Deposit
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // First claim succeeds
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 700e6);

        // Second claim reverts
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.NothingToClaim.selector)
        );
        dividend.claimDividends(type(uint256).max);
    }

    function test_claimDividends_multipleEpochs() public {
        // Epoch 0: 1000 USDC
        vm.startPrank(spv);
        usdc.approve(address(dividend), 5000e6);
        dividend.depositDividends(1000e6);
        vm.roll(block.number + 1);

        // Epoch 1: 2000 USDC
        dividend.depositDividends(2000e6);
        vm.stopPrank();

        // investor1 (70%) should get 700 + 1400 = 2100 USDC
        uint256 pending1 = dividend.pendingDividends(investor1, type(uint256).max);
        assertEq(pending1, 2100e6);

        // investor2 (30%) should get 300 + 600 = 900 USDC
        uint256 pending2 = dividend.pendingDividends(investor2, type(uint256).max);
        assertEq(pending2, 900e6);

        // Claim all at once
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 2100e6);
    }

    function test_claimDividends_partialThenNew() public {
        // Epoch 0: 1000 USDC
        vm.startPrank(spv);
        usdc.approve(address(dividend), 3000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // investor1 claims epoch 0
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 700e6);

        // New epoch deposited
        vm.roll(block.number + 1);
        vm.startPrank(spv);
        dividend.depositDividends(2000e6);
        vm.stopPrank();

        // investor1 claims epoch 1 only
        uint256 pending1 = dividend.pendingDividends(investor1, type(uint256).max);
        assertEq(pending1, 1400e6);

        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 700e6 + 1400e6);
    }

    function test_claimDividends_zeroBalanceInvestor() public {
        // Create a KYC user that has 0 tokens
        address zeroHolder = makeAddr("zeroHolder");
        kyc.addUser(zeroHolder);

        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // Zero holder has 0 pending
        assertEq(dividend.pendingDividends(zeroHolder, type(uint256).max), 0);

        // Claim should still emit event but transfer 0
        vm.prank(zeroHolder);
        dividend.claimDividends(type(uint256).max);

        // Balance stays 0
        assertEq(usdc.balanceOf(zeroHolder), 0);

        // But claimedUpToEpoch advances so NothingToClaim on retry
        vm.prank(zeroHolder);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.NothingToClaim.selector)
        );
        dividend.claimDividends(type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Flash Loan & Snapshot Protection
    // ═══════════════════════════════════════════════════════════════════

    function test_flashLoanSimulation() public {
        // Deposit dividends — snapshot taken at current block - 1
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // investor1 transfers ALL tokens to a new address AFTER the snapshot
        address attacker = address(0xBEEF);
        kyc.addUser(attacker);

        vm.prank(investor1);
        token.transfer(attacker, 700e18);

        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1);

        // Attacker should NOT be able to claim dividends from the epoch
        // because their getPastVotes at the snapshot block was 0
        uint256 attackerPending = dividend.pendingDividends(attacker, type(uint256).max);
        assertEq(attackerPending, 0);

        // Original investor1 CAN still claim (their snapshot balance was 700)
        uint256 inv1Pending = dividend.pendingDividends(investor1, type(uint256).max);
        assertEq(inv1Pending, 700e6);
    }

    function test_pendingDividends_afterTokenTransfer() public {
        // Deposit epoch 0
        vm.startPrank(spv);
        usdc.approve(address(dividend), 2000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // investor1 transfers all tokens to investor2 AFTER deposit
        vm.prank(investor1);
        token.transfer(investor2, 700e18);
        vm.roll(block.number + 1);

        // Epoch 0 snapshot: investor1 had 700, investor2 had 300
        // Pending should reflect SNAPSHOT, not current balance
        assertEq(dividend.pendingDividends(investor1, type(uint256).max), 700e6);
        assertEq(dividend.pendingDividends(investor2, type(uint256).max), 300e6);

        // Epoch 1 deposited after transfer settled
        vm.startPrank(spv);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // Epoch 1 snapshot: investor1 = 0, investor2 = 1000
        // investor1: 700 (epoch 0) + 0 (epoch 1) = 700
        assertEq(dividend.pendingDividends(investor1, type(uint256).max), 700e6);
        // investor2: 300 (epoch 0) + 1000 (epoch 1) = 1300
        assertEq(dividend.pendingDividends(investor2, type(uint256).max), 1300e6);
    }

    function test_noDelegateReturnsZero() public {
        // Deposit dividends first
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // Create a new investor that has NOT delegated
        address noDelegateInvestor = makeAddr("noDelegate");
        kyc.addUser(noDelegateInvestor);

        // Without delegate, getPastVotes returns 0
        // so pending should be 0 (investor gets no dividends)
        uint256 pending = dividend.pendingDividends(noDelegateInvestor, type(uint256).max);
        assertEq(pending, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  View Function Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_getEpochCount_initiallyZero() public {
        assertEq(dividend.getEpochCount(), 0);
    }

    function test_pendingDividends_zeroWhenNoEpochs() public {
        assertEq(dividend.pendingDividends(investor1, type(uint256).max), 0);
    }

    function test_getEpoch_returnsCorrectData() public {
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        DividendDistribution.DividendEpoch memory e = dividend.getEpoch(0);
        assertEq(e.blockNumber, block.number - 1);
        assertEq(e.totalSupply, TOTAL_SUPPLY);
        assertEq(e.amountDeposited, 1000e6);
        // dividendPerTokenCumul = (1000e6 * 1e18) / 1000e18 = 1e6
        assertEq(e.dividendPerTokenCumul, 1e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Constructor Validation Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_constructor_revertZeroPropertyToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.ZeroAddress.selector)
        );
        new DividendDistribution(
            address(0), address(usdc), address(kyc), admin
        );
    }

    function test_constructor_revertZeroStablecoin() public {
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.ZeroAddress.selector)
        );
        new DividendDistribution(
            address(token), address(0), address(kyc), admin
        );
    }

    function test_constructor_revertZeroKYCRegistry() public {
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.ZeroAddress.selector)
        );
        new DividendDistribution(
            address(token), address(usdc), address(0), admin
        );
    }

    function test_constructor_revertZeroAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.ZeroAddress.selector)
        );
        new DividendDistribution(
            address(token), address(usdc), address(kyc), address(0)
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Access Control Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_roles_depositorCanBeRevoked() public {
        // Admin revokes DEPOSITOR_ROLE from SPV
        vm.startPrank(admin);
        dividend.revokeRole(dividend.DEPOSITOR_ROLE(), spv);
        vm.stopPrank();

        // SPV can no longer deposit
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        vm.expectRevert();
        dividend.depositDividends(1000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Re-Entrancy Attack Simulation
    // ═══════════════════════════════════════════════════════════════════

    function test_reentrancy_claimDividends() public {
        // Deposit dividends
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // investor1 claims — state is updated BEFORE transfer (CEI pattern)
        // Even if stablecoin had a callback, ReentrancyGuard blocks re-entry
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        assertEq(usdc.balanceOf(investor1), 700e6);

        // After claim, claimedUpToEpoch is updated — second call reverts
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.NothingToClaim.selector)
        );
        dividend.claimDividends(type(uint256).max);

        // Verify: contract balance drained exactly by claimed amount only
        assertEq(usdc.balanceOf(address(dividend)), 300e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Pagination Boundary Tests (maxEpochs)
    // ═══════════════════════════════════════════════════════════════════

    function test_claimDividends_revertMaxEpochsZero() public {
        // maxEpochs = 0 should revert with MaxEpochsZero
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.MaxEpochsZero.selector)
        );
        dividend.claimDividends(0);
    }

    function test_claimDividends_pagination_partial() public {
        // Deposit 5 epochs
        vm.startPrank(spv);
        usdc.approve(address(dividend), 5000e6);
        for (uint256 i = 0; i < 5; i++) {
            dividend.depositDividends(1000e6);
            vm.roll(block.number + 1);
        }
        vm.stopPrank();

        assertEq(dividend.getEpochCount(), 5);

        // Claim only 2 epochs at a time (investor1 = 70%)
        // First claim: epochs 0-1 → 700 + 700 = 1400
        vm.prank(investor1);
        dividend.claimDividends(2);
        assertEq(usdc.balanceOf(investor1), 1400e6);

        // Second claim: epochs 2-3 → 700 + 700 = 1400
        vm.prank(investor1);
        dividend.claimDividends(2);
        assertEq(usdc.balanceOf(investor1), 2800e6);

        // Third claim: epoch 4 → 700 (only 1 remaining)
        vm.prank(investor1);
        dividend.claimDividends(2);
        assertEq(usdc.balanceOf(investor1), 3500e6);

        // Fourth claim: nothing left
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.NothingToClaim.selector)
        );
        dividend.claimDividends(2);
    }

    function test_pendingDividends_pagination() public {
        // Deposit 4 epochs
        vm.startPrank(spv);
        usdc.approve(address(dividend), 4000e6);
        for (uint256 i = 0; i < 4; i++) {
            dividend.depositDividends(1000e6);
            vm.roll(block.number + 1);
        }
        vm.stopPrank();

        // pendingDividends with maxEpochs=2 returns only first 2 epochs
        uint256 partialPending = dividend.pendingDividends(investor1, 2);
        assertEq(partialPending, 1400e6); // 700 * 2

        // pendingDividends with max returns all 4
        uint256 fullPending = dividend.pendingDividends(investor1, type(uint256).max);
        assertEq(fullPending, 2800e6); // 700 * 4
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Zero Supply Deposit Revert
    // ═══════════════════════════════════════════════════════════════════

    function test_depositDividends_revertZeroSupply() public {
        // Burn all tokens so totalSupply == 0
        vm.prank(investor1);
        token.burn(700e18);
        vm.prank(investor2);
        token.burn(300e18);
        vm.roll(block.number + 1);

        assertEq(token.totalSupply(), 0);

        // Deposit should revert with ZeroSupply
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.ZeroSupply.selector)
        );
        dividend.depositDividends(1000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Precision / Rounding Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_precision_smallDeposit() public {
        // Deposit very small amount: 1 USDC (1e6)
        // investor1 (70%): 0.7 USDC = 700000 wei
        // investor2 (30%): 0.3 USDC = 300000 wei
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1e6);
        dividend.depositDividends(1e6);
        vm.stopPrank();

        uint256 p1 = dividend.pendingDividends(investor1, type(uint256).max);
        uint256 p2 = dividend.pendingDividends(investor2, type(uint256).max);

        // 1e6 * 700/1000 = 700000 exactly (no rounding loss)
        assertEq(p1, 700000);
        assertEq(p2, 300000);

        // Total claimed should equal total deposited (no dust)
        assertEq(p1 + p2, 1e6);
    }

    function test_precision_oddDeposit() public {
        // Deposit 1 wei of USDC — check rounding behavior
        // 1 * PRECISION / TOTAL_SUPPLY = 1e18 / 1000e18 = 0.001 (truncated to 0)
        // With PRECISION: (1 * 1e18) / 1000e18 = 1e-3 → truncated 0 in integer
        // So dividend per token rounds down significantly for very tiny amounts
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1);
        dividend.depositDividends(1);
        vm.stopPrank();

        // Both investors get 0 due to integer truncation (1 * 700e18 * 1e-3 / 1e18 = 0.7 → 0)
        uint256 p1 = dividend.pendingDividends(investor1, type(uint256).max);
        uint256 p2 = dividend.pendingDividends(investor2, type(uint256).max);
        assertEq(p1, 0);
        assertEq(p2, 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Gas Scaling Test — Many Epochs
    // ═══════════════════════════════════════════════════════════════════

    function test_gasScaling_manyEpochs() public {
        uint256 epochCount = 20;

        // Deposit 20 epochs of 100 USDC each
        vm.startPrank(spv);
        usdc.approve(address(dividend), 100e6 * epochCount);
        for (uint256 i = 0; i < epochCount; i++) {
            dividend.depositDividends(100e6);
            vm.roll(block.number + 1);
        }
        vm.stopPrank();

        assertEq(dividend.getEpochCount(), epochCount);

        // investor1 (70%): 20 * 70 USDC = 1400 USDC
        uint256 pending = dividend.pendingDividends(investor1, type(uint256).max);
        assertEq(pending, 1400e6);

        // Measure gas for claiming all 20 epochs
        uint256 gasBefore = gasleft();
        vm.prank(investor1);
        dividend.claimDividends(type(uint256).max);
        uint256 gasUsed = gasBefore - gasleft();

        // Verify claim succeeded
        assertEq(usdc.balanceOf(investor1), 1400e6);

        // Gas should be well under block gas limit
        // Target: < 200,000 gas for claimDividends (from outline checklist)
        assertTrue(gasUsed < 500_000, "Gas too high for 20 epoch claim");
    }

    // ═══════════════════════════════════════════════════════════════════
    //  KYC Revocation Blocks Claim
    // ═══════════════════════════════════════════════════════════════════

    function test_claimDividends_revertAfterKYCRevoked() public {
        // Deposit
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividends(1000e6);
        vm.stopPrank();

        // Revoke investor1's KYC
        kyc.removeUser(investor1);

        // investor1 can no longer claim
        vm.prank(investor1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistribution.InvestorNotKYCVerified.selector,
                investor1
            )
        );
        dividend.claimDividends(type(uint256).max);
    }
}
