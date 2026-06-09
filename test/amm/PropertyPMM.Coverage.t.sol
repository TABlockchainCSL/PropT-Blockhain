// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {PMMMath} from "../../src/amm/libraries/PMMMath.sol";
import {MockKYCRegistry, MockDividendDistributor} from "./helpers/AMMTestBase.sol";

/// @notice ERC20 mock that can be toggled to return `false` from transfer /
///         transferFrom, so the defensive `require(token.transfer(...), "..._FAILED")`
///         failure branches in PropertyPMM can be exercised. Standard ERC20s revert
///         instead of returning false, so these branches are otherwise unreachable.
contract ToggleERC20 is IERC20Metadata {
    string public name;
    string public symbol;
    uint8 public immutable DECIMALS;
    address public kycRegistry;

    bool public failTransfer;
    bool public failTransferFrom;
    // When non-zero, transferFrom returns false starting from the Nth call.
    // Lets a test fail only the *second* quote pull in buyBaseToken (the buy-tax
    // pull) while letting the main payment succeed.
    uint256 public failTransferFromFromCall;
    uint256 public transferFromCalls;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        DECIMALS = decimals_;
    }

    function setKycRegistry(address newKycRegistry) external {
        kycRegistry = newKycRegistry;
    }

    function setFailTransfer(bool v) external {
        failTransfer = v;
    }

    function setFailTransferFrom(bool v) external {
        failTransferFrom = v;
    }

    function setFailTransferFromFromCall(uint256 n) external {
        failTransferFromFromCall = n;
    }

    function decimals() external view returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failTransfer) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        transferFromCalls += 1;
        if (failTransferFrom) return false;
        if (failTransferFromFromCall != 0 && transferFromCalls >= failTransferFromFromCall) return false;
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Exposes the internal PMMMath library so its uncovered branch can be hit directly.
contract PMMMathWrapper {
    function solveTrade(uint256 q0, uint256 q1, uint256 iDeltaB, bool deltaBSig, uint256 k)
        external
        pure
        returns (uint256)
    {
        return PMMMath.solveQuadraticFunctionForTrade(q0, q1, iDeltaB, deltaBSig, k);
    }
}

/// @notice Targets the few remaining uncovered branches in PropertyPMM and PMMMath:
///         the `require(token.transfer/transferFrom(...))` failure paths and the
///         `minusBSig = false` branch of the DODO trade quadratic.
contract PropertyPMMCoverageTest is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant INITIAL_BASE = 10 * ONE;
    uint256 internal constant INITIAL_QUOTE = 1000 * ONE;
    uint256 internal constant INITIAL_PRICE = 100 * ONE;
    uint256 internal constant DEFAULT_LP_FEE = 2e15;
    uint256 internal constant DEFAULT_MAINTAINER_FEE = 1e15;
    uint256 internal constant DEFAULT_K = 1e17;

    address internal supervisor = address(0x1001);
    address internal maintainer = address(0x1002);
    address internal taxRecipient = address(0x1004);
    address internal lpProvider = address(0x1000);
    address internal trader = address(0x1003);

    MockKYCRegistry internal kyc;
    ToggleERC20 internal base;
    ToggleERC20 internal quote;
    MockDividendDistributor internal dividendDistributor;
    PropertyPMM internal pool;

    function setUp() public {
        kyc = new MockKYCRegistry();
        kyc.setVerified(lpProvider, true);
        kyc.setVerified(trader, true);
        kyc.setVerified(maintainer, true);
        kyc.setVerified(taxRecipient, true);
        kyc.setVerified(address(this), true);

        base = new ToggleERC20("Base", "BASE", 18);
        quote = new ToggleERC20("Quote", "QUOTE", 18);
        base.setKycRegistry(address(kyc));

        dividendDistributor = new MockDividendDistributor(address(base), address(quote));

        pool = new PropertyPMM(
            address(this),
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
        kyc.setApprovedContract(address(pool), true);

        _fund(lpProvider, INITIAL_BASE * 5, INITIAL_QUOTE * 5);
        _fund(trader, INITIAL_BASE * 5, INITIAL_QUOTE * 5);

        vm.prank(lpProvider);
        pool.provideLiquidity(INITIAL_BASE, INITIAL_QUOTE, 0);
        pool.enableTrading();
    }

    function _fund(address user, uint256 baseAmount, uint256 quoteAmount) internal {
        base.mint(user, baseAmount);
        quote.mint(user, quoteAmount);
        vm.startPrank(user);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // --- Branch 61: _quoteTokenTransferFrom failure (QUOTE_TRANSFER_FROM_FAILED) ---
    function test_provideLiquidity_revertsWhenQuotePullFails() public {
        quote.setFailTransferFrom(true);
        vm.prank(lpProvider);
        vm.expectRevert(bytes("QUOTE_TRANSFER_FROM_FAILED"));
        pool.provideLiquidity(INITIAL_BASE, INITIAL_QUOTE, 0);
    }

    // --- Branch 61: _quoteTokenTransferFrom failure on the buy-tax pull ---
    // The main payment (a different require) must succeed, so we fail only the
    // *next* quote transferFrom after it: the buy-tax pull inside _chargeBuyFees.
    function test_buyTaxPull_revertsWhenTransferFromFails() public {
        pool.setTaxRecipient(taxRecipient);
        pool.setBuyTaxRate(5e16);
        pool.enableTax();

        uint256 cost = pool.queryBuyBaseToken(ONE);
        // After main payment (call k+1), fail the buy-tax pull (call k+2).
        quote.setFailTransferFromFromCall(quote.transferFromCalls() + 2);

        vm.prank(trader);
        vm.expectRevert(bytes("QUOTE_TRANSFER_FROM_FAILED"));
        pool.buyBaseToken(ONE, cost);
    }

    // --- Branch 20: claimLpQuoteDividends transfer failure (QUOTE_TRANSFER_FAILED) ---
    function test_claimLpQuoteDividends_revertsWhenTransferFails() public {
        quote.mint(address(dividendDistributor), 25 * ONE);
        dividendDistributor.setClaimAmount(25 * ONE);
        pool.claimQuoteDividends(type(uint256).max); // owner accrues to LPs
        assertEq(pool.pendingLpQuoteDividends(lpProvider), 25 * ONE);

        quote.setFailTransfer(true);
        vm.prank(lpProvider);
        vm.expectRevert(bytes("QUOTE_TRANSFER_FAILED"));
        pool.claimLpQuoteDividends();
    }

    // --- Branch 64: claimMaintainerFees base transfer failure (BASE_TRANSFER_FAILED) ---
    function test_claimMaintainerFees_revertsWhenBaseTransferFails() public {
        uint256 cost = pool.queryBuyBaseToken(ONE);
        vm.prank(trader);
        pool.buyBaseToken(ONE, cost); // accrues pendingMaintainerFeeBase
        assertGt(pool.pendingMaintainerFeeBase(), 0);
        assertEq(pool.pendingMaintainerFeeQuote(), 0);

        base.setFailTransfer(true);
        vm.expectRevert(bytes("BASE_TRANSFER_FAILED"));
        pool.claimMaintainerFees();
    }

    // --- Branch 66: claimMaintainerFees quote transfer failure (QUOTE_TRANSFER_FAILED) ---
    function test_claimMaintainerFees_revertsWhenQuoteTransferFails() public {
        uint256 proceeds = pool.querySellBaseToken(ONE);
        vm.prank(trader);
        pool.sellBaseToken(ONE, proceeds); // accrues pendingMaintainerFeeQuote
        assertGt(pool.pendingMaintainerFeeQuote(), 0);
        assertEq(pool.pendingMaintainerFeeBase(), 0);

        quote.setFailTransfer(true);
        vm.expectRevert(bytes("QUOTE_TRANSFER_FAILED"));
        pool.claimMaintainerFees();
    }

    // --- Branch 71: claimTax quote transfer failure (QUOTE_TRANSFER_FAILED) ---
    function test_claimTax_revertsWhenQuoteTransferFails() public {
        pool.setTaxRecipient(taxRecipient);
        pool.setBuyTaxRate(5e16);
        pool.enableTax();

        uint256 cost = pool.queryBuyBaseToken(ONE);
        vm.prank(trader);
        pool.buyBaseToken(ONE, cost); // accrues pendingTaxQuote
        assertGt(pool.pendingTaxQuote(), 0);

        quote.setFailTransfer(true);
        vm.expectRevert(bytes("QUOTE_TRANSFER_FAILED"));
        pool.claimTax();
    }

    // --- PMMMath: minusBSig = false branch (b < kQ02Q1) ---
    function test_pmmMath_solveTrade_hitsMinusBSigFalseBranch() public {
        PMMMathWrapper wrapper = new PMMMathWrapper();
        // deltaBSig=false makes kQ02Q1 += iDeltaB, pushing it above b so the
        // `else { b = kQ02Q1 - b; minusBSig = false; }` branch executes.
        uint256 result = wrapper.solveTrade(ONE, ONE, ONE, false, DEFAULT_K);
        assertGt(result, 0);
    }
}
