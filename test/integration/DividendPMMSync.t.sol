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
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";

/// @notice Mock USDC (6 decimals, like real USDC) used as the quote/stablecoin.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title DividendPMMSyncIntegration
/// @notice End-to-end: real PropertyToken + KYCRegistry + DividendDistribution +
///         PropertyPMM, proving depositDividendsAndSync routes a pool's dividend
///         share into LP accounting without a post-deposit manual-sync gap.
contract DividendPMMSyncIntegration is Test {
    // Reuse the PMM defaults that AMMTestBase is known to construct with.
    uint256 internal constant INITIAL_PRICE = 100e18;
    uint256 internal constant LP_FEE = 2e15;
    uint256 internal constant MAINTAINER_FEE = 1e15;
    uint256 internal constant K = 1e17;

    uint256 internal constant PROPERTY_SUPPLY = 100e18; // total property tokens
    uint256 internal constant POOL_BASE = 10e18; // property tokens seeded into pool (10%)
    uint256 internal constant POOL_QUOTE = 1000e6; // USDC reserve seeded into pool

    KYCRegistry internal kyc;
    PropertyToken internal token;
    MockUSDC internal usdc;
    DividendDistribution internal dividend;
    PropertyPMM internal pool;

    address internal owner;
    address internal admin = makeAddr("admin");
    address internal spv = makeAddr("spv");
    address internal supervisor = makeAddr("supervisor");
    address internal maintainer = makeAddr("maintainer");
    address internal lpProvider = makeAddr("lpProvider");

    function setUp() public {
        owner = address(this);

        // ── KYCRegistry (UUPS proxy) ──────────────────────────────────
        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy =
            new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        kyc = KYCRegistry(address(kycProxy));
        kyc.addUser(owner);
        kyc.addUser(spv);
        kyc.addUser(maintainer);
        kyc.addUser(lpProvider);

        // ── PropertyToken (Beacon proxy), owner holds full supply ─────
        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), owner);
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                ("RealToken", "RTK", PROPERTY_SUPPLY, 1, address(kyc), owner)
            )
        );
        token = PropertyToken(address(tokenProxy));

        // ── Quote stablecoin + DividendDistribution ───────────────────
        usdc = new MockUSDC();
        dividend = new DividendDistribution(address(token), address(usdc), address(kyc), admin);
        vm.startPrank(admin);
        dividend.grantRole(dividend.DEPOSITOR_ROLE(), spv);
        vm.stopPrank();

        // ── PropertyPMM (base = property token, quote = usdc) ──────────
        // Constructor reads token.kycRegistry(), validates the distributor, and
        // self-delegates the base token's votes to the pool.
        pool = new PropertyPMM(
            owner, supervisor, maintainer, address(token), address(usdc),
            INITIAL_PRICE, LP_FEE, MAINTAINER_FEE, K, address(dividend)
        );

        // Pool must be an approved contract: to hold property tokens AND to
        // pass the distributor's KYC check when it claims dividends.
        kyc.addApprovedContract(address(pool));

        // ── Seed liquidity from lpProvider ────────────────────────────
        token.transfer(lpProvider, POOL_BASE); // owner → lpProvider (both KYC'd)
        usdc.mint(lpProvider, POOL_QUOTE);
        vm.startPrank(lpProvider);
        token.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.provideLiquidity(POOL_BASE, POOL_QUOTE, 0);
        vm.stopPrank();

        // Advance so the pool's vote checkpoint is readable via getPastVotes.
        vm.roll(block.number + 1);

        // Fund the depositor.
        usdc.mint(spv, 1_000_000e6);
    }

    /// @notice Happy path: deposit + atomic sync routes the pool's 10% share
    ///         into LP accounting, and the sole LP can claim it.
    function test_endToEnd_depositAndSync_routesShareToLP() public {
        uint256 dividendAmount = 1000e6; // pool holds 10% → entitled to 100 USDC
        uint256 expectedPoolShare = 100e6;

        vm.startPrank(spv);
        usdc.approve(address(dividend), dividendAmount);
        dividend.depositDividendsAndSync(dividendAmount, address(pool));
        vm.stopPrank();

        // Epoch exists and the pool was fully synced in the same tx.
        assertEq(dividend.getEpochCount(), 1);
        assertEq(dividend.pendingDividends(address(pool), type(uint256).max), 0);

        // Pool received its share on top of its quote reserve; tracked as LP dividends.
        assertEq(usdc.balanceOf(address(pool)), POOL_QUOTE + expectedPoolShare);
        assertEq(pool.totalPendingLpQuoteDividends(), expectedPoolShare);

        // Sole LP can claim exactly the pool's share.
        assertEq(pool.pendingLpQuoteDividends(lpProvider), expectedPoolShare);
        uint256 lpBefore = usdc.balanceOf(lpProvider);
        vm.prank(lpProvider);
        uint256 claimed = pool.claimLpQuoteDividends();
        assertEq(claimed, expectedPoolShare);
        assertEq(usdc.balanceOf(lpProvider) - lpBefore, expectedPoolShare);
    }

    /// @notice An LP that joins after the atomic deposit and sync cannot capture
    ///         dividends that have already been accounted.
    function test_endToEnd_syncPreventsPostDepositJITCapture() public {
        vm.startPrank(spv);
        usdc.approve(address(dividend), 1000e6);
        dividend.depositDividendsAndSync(1000e6, address(pool));
        vm.stopPrank();

        // An LP joins after the dividend is already accounted.
        address jit = makeAddr("jit");
        kyc.addUser(jit);
        token.transfer(jit, POOL_BASE);
        usdc.mint(jit, POOL_QUOTE);
        vm.startPrank(jit);
        token.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.provideLiquidity(POOL_BASE, POOL_QUOTE, 0);
        vm.stopPrank();

        // The JIT LP cannot even trigger accounting — the claim is gated to the
        // distributor / owner / supervisor — and has zero pending dividends.
        assertEq(dividend.pendingDividends(address(pool), type(uint256).max), 0);
        vm.prank(jit);
        vm.expectRevert(bytes("CLAIM_NOT_AUTHORIZED"));
        pool.claimQuoteDividends(type(uint256).max);
        assertEq(pool.pendingLpQuoteDividends(jit), 0);
    }

    /// @notice Real KYCRegistry integration: PMM LP tokens can only move between
    ///         currently KYC-verified users or approved contracts.
    function test_endToEnd_realKycControlsLpTransfers() public {
        address receiver = makeAddr("lpReceiver");
        kyc.addUser(receiver);

        uint256 transferAmount = pool.balanceOf(lpProvider) / 4;

        vm.prank(lpProvider);
        assertTrue(pool.transfer(receiver, transferAmount));
        assertEq(pool.balanceOf(receiver), transferAmount);

        kyc.removeUser(receiver);
        vm.prank(receiver);
        vm.expectRevert(abi.encodeWithSelector(PropertyPMM.SenderNotAuthorized.selector, receiver));
        pool.transfer(lpProvider, transferAmount);

        kyc.addUser(receiver);
        vm.prank(receiver);
        assertTrue(pool.transfer(lpProvider, transferAmount));
        assertEq(pool.balanceOf(receiver), 0);
    }
}
