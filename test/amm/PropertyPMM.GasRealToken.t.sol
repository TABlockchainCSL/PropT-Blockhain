// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {KYCRegistry} from "../../src/core/KYCRegistry.sol";
import {PropertyToken} from "../../src/core/PropertyToken.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {MockERC20, MockDividendDistributor} from "./helpers/AMMTestBase.sol";

/// @notice Gas measurement for PropertyPMM using the REAL PropertyToken
///         (KYC-gated + ERC20Votes) as the base token, and a plain ERC20
///         stablecoin as the quote token. This mirrors the production wiring
///         so the reported gas includes KYC checks and voting checkpoints,
///         unlike PropertyPMM.Unit.t.sol which uses a plain MockERC20 base.
contract PropertyPMMGasRealTokenTest is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000 * ONE;
    uint256 internal constant INITIAL_BASE = 10 * ONE;
    uint256 internal constant INITIAL_QUOTE = 1000 * ONE;
    uint256 internal constant INITIAL_PRICE = 100 * ONE;
    uint256 internal constant DEFAULT_LP_FEE = 2e15;
    uint256 internal constant DEFAULT_MAINTAINER_FEE = 1e15;
    uint256 internal constant DEFAULT_K = 1e17;

    address internal owner;
    address internal supervisor = address(0x1001);
    address internal maintainer = address(0x1002);
    address internal lpProvider = address(0x1000);
    address internal trader = address(0x1003);

    KYCRegistry internal kyc;
    PropertyToken internal base; // real KYC-gated, ERC20Votes token
    MockERC20 internal quote; // plain stablecoin
    MockDividendDistributor internal dividendDistributor;
    PropertyPMM internal pool;

    function setUp() public {
        owner = address(this);

        // --- Real KYCRegistry (UUPS proxy) ---
        KYCRegistry kycImpl = new KYCRegistry();
        kyc = KYCRegistry(address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()))));

        // --- Real PropertyToken (beacon proxy), all supply minted to owner ---
        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), owner);
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize, ("Property Token", "PROP", TOTAL_SUPPLY, 1, address(kyc), owner)
            )
        );
        base = PropertyToken(address(tokenProxy));

        // --- Plain ERC20 stablecoin as quote ---
        quote = new MockERC20("USD Coin", "USDC", 18);

        dividendDistributor = new MockDividendDistributor(address(base), address(quote));

        // --- PMM reads kycRegistry() from the base token in its constructor ---
        pool = new PropertyPMM(
            owner,
            supervisor,
            maintainer,
            address(base),
            address(quote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            address(dividendDistributor)
        );

        // --- KYC wiring: verify humans, approve the pool as a contract ---
        kyc.addUser(owner);
        kyc.addUser(lpProvider);
        kyc.addUser(trader);
        kyc.addUser(maintainer);
        kyc.addApprovedContract(address(pool));

        // --- Distribute base tokens (owner -> actors) and mint quote ---
        base.transfer(lpProvider, INITIAL_BASE * 10);
        base.transfer(trader, INITIAL_BASE * 10);
        quote.mint(lpProvider, INITIAL_QUOTE * 10);
        quote.mint(trader, INITIAL_QUOTE * 10);

        vm.startPrank(lpProvider);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // --- Seed liquidity and enable trading ---
        vm.prank(lpProvider);
        pool.provideLiquidity(INITIAL_BASE, INITIAL_QUOTE, 0);
        pool.enableTrading();
    }

    /// @dev Each operation is exercised once so the forge --gas-report row
    ///      collapses to a single number (Min == Median == Max == Avg).

    function test_gas_provideLiquidity() public {
        vm.prank(lpProvider);
        pool.provideLiquidity(INITIAL_BASE, INITIAL_QUOTE, 0);
    }

    function test_gas_buyBaseToken() public {
        vm.prank(trader);
        pool.buyBaseToken(1 * ONE, type(uint256).max);
    }

    function test_gas_sellBaseToken() public {
        vm.prank(trader);
        pool.sellBaseToken(1 * ONE, 0);
    }

    function test_gas_withdrawLiquidity() public {
        uint256 shares = pool.balanceOf(lpProvider);
        vm.prank(lpProvider);
        pool.withdrawLiquidity(shares / 2, 0, 0);
    }
}
