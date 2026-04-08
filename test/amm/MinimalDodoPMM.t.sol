// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {IERC20Minimal} from "../../src/amm/interfaces/IERC20Minimal.sol";
import {IPriceOracle} from "../../src/amm/interfaces/IPriceOracle.sol";

contract MockERC20 is IERC20Minimal {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
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

contract MockOracle is IPriceOracle {
    uint256 internal price;

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }
}

contract MinimalDodoPMMTest is Test {
    uint256 internal constant ONE = 1e18;

    MockERC20 internal base;
    MockERC20 internal quote;
    MockERC20 internal stray;
    MockOracle internal oracle;
    MinimalDodoPMM internal pool;

    address internal lpProvider = address(0x1000);
    address internal supervisor = address(0x1001);
    address internal maintainer = address(0x1002);
    address internal trader = address(0x1003);
    address internal taxRecipient = address(0x1004);
    address internal lpReceiver = address(0x1005);
    address internal outsider = address(0x1006);
    address internal secondProvider = address(0x1007);

    function _mintAndApprove(address user, uint256 baseAmount, uint256 quoteAmount) internal {
        base.mint(user, baseAmount);
        quote.mint(user, quoteAmount);

        vm.startPrank(user);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function setUp() public {
        base = new MockERC20("Base", "BASE");
        quote = new MockERC20("Quote", "QUOTE");
        stray = new MockERC20("Stray", "STRAY");
        oracle = new MockOracle();
        oracle.setPrice(100 * ONE);

        pool = new MinimalDodoPMM(
            address(this),
            supervisor,
            maintainer,
            address(base),
            address(quote),
            address(oracle),
            2e15,
            1e15,
            1e17,
            "Modern DODO LP",
            "mDLP"
        );

        _mintAndApprove(lpProvider, 10 * ONE, 1000 * ONE);
        vm.startPrank(lpProvider);
        pool.provideLiquidity(10 * ONE, 1000 * ONE, 0);
        vm.stopPrank();
        pool.enableTrading();

        _mintAndApprove(trader, 10 * ONE, 1000 * ONE);
    }

    function testEnableTaxRequiresRecipient() public {
        vm.expectRevert(bytes("TAX_RECIPIENT_NOT_SET"));
        pool.enableTax();
    }

    function testInitialPoolStateTracksTargetsAndMidPrice() public view {
        (uint256 expectedBaseTarget, uint256 expectedQuoteTarget) = pool.getExpectedTarget();

        assertEq(pool.totalSupply(), 100 * ONE);
        assertEq(pool.baseBalance(), 10 * ONE);
        assertEq(pool.quoteBalance(), 1000 * ONE);
        assertEq(pool.targetBaseTokenAmount(), 10 * ONE);
        assertEq(pool.targetQuoteTokenAmount(), 1000 * ONE);
        assertEq(uint256(pool.rStatus()), uint256(MinimalDodoPMM.RStatus.ONE));
        assertEq(expectedBaseTarget, 10 * ONE);
        assertEq(expectedQuoteTarget, 1000 * ONE);
        assertEq(pool.getOraclePrice(), 100 * ONE);
        assertEq(pool.getMidPrice(), 100 * ONE);
    }

    function testBuyTaxChargesExtraQuoteAndKeepsPoolAccounting() public {
        uint256 buyAmount = ONE;
        uint256 untaxedQuote = pool.queryBuyBaseToken(buyAmount);

        pool.setTaxRecipient(taxRecipient);
        pool.setBuyTaxRate(5e16);
        pool.enableTax();

        uint256 taxedQuote = pool.queryBuyBaseToken(buyAmount);
        uint256 expectedTax = (untaxedQuote * 5e16) / ONE;

        assertEq(taxedQuote, untaxedQuote + expectedTax);

        vm.prank(trader);
        vm.expectRevert(bytes("BUY_BASE_COST_TOO_MUCH"));
        pool.buyBaseToken(buyAmount, untaxedQuote);

        uint256 traderQuoteBefore = quote.balanceOf(trader);
        uint256 poolQuoteBefore = pool.quoteBalance();
        uint256 taxQuoteBefore = quote.balanceOf(taxRecipient);

        vm.prank(trader);
        uint256 totalPaid = pool.buyBaseToken(buyAmount, taxedQuote);

        uint256 traderQuoteAfter = quote.balanceOf(trader);
        uint256 poolQuoteAfter = pool.quoteBalance();
        uint256 taxQuoteAfter = quote.balanceOf(taxRecipient);

        assertEq(totalPaid, taxedQuote);
        assertEq(traderQuoteBefore - traderQuoteAfter, taxedQuote);
        assertEq(poolQuoteAfter - poolQuoteBefore, untaxedQuote);
        assertEq(taxQuoteAfter - taxQuoteBefore, expectedTax);
    }

    function testBuyPaysMaintainerInBaseAndMovesPoolAboveOne() public {
        uint256 buyAmount = ONE;
        uint256 maintainerBaseBefore = base.balanceOf(maintainer);
        uint256 poolBaseBefore = pool.baseBalance();
        uint256 totalPaid = pool.queryBuyBaseToken(buyAmount);

        vm.prank(trader);
        pool.buyBaseToken(buyAmount, totalPaid);

        uint256 maintainerBaseAfter = base.balanceOf(maintainer);

        assertTrue(maintainerBaseAfter > maintainerBaseBefore);
        assertEq(pool.baseBalance() + buyAmount + (maintainerBaseAfter - maintainerBaseBefore), poolBaseBefore);
        assertEq(uint256(pool.rStatus()), uint256(MinimalDodoPMM.RStatus.ABOVE_ONE));
    }

    function testPublicLpTokenCanTransferAndWithdraw() public {
        uint256 initialShares = pool.balanceOf(lpProvider);
        uint256 transferAmount = initialShares / 2;

        vm.prank(lpProvider);
        assertTrue(pool.transfer(lpReceiver, transferAmount));

        assertEq(pool.balanceOf(lpReceiver), transferAmount);
        assertEq(pool.balanceOf(lpProvider), initialShares - transferAmount);

        uint256 receiverBaseBefore = base.balanceOf(lpReceiver);
        uint256 receiverQuoteBefore = quote.balanceOf(lpReceiver);

        vm.prank(lpReceiver);
        (uint256 baseOut, uint256 quoteOut) = pool.withdrawLiquidity(transferAmount, 0, 0);

        assertEq(pool.balanceOf(lpReceiver), 0);
        assertEq(base.balanceOf(lpReceiver) - receiverBaseBefore, baseOut);
        assertEq(quote.balanceOf(lpReceiver) - receiverQuoteBefore, quoteOut);
        assertTrue(baseOut > 0);
        assertTrue(quoteOut > 0);
    }

    function testLpTokenTransferFromUsesAllowance() public {
        uint256 transferAmount = pool.balanceOf(lpProvider) / 4;

        vm.prank(lpProvider);
        assertTrue(pool.approve(outsider, transferAmount));

        vm.prank(outsider);
        assertTrue(pool.transferFrom(lpProvider, lpReceiver, transferAmount));

        assertEq(pool.balanceOf(lpReceiver), transferAmount);
        assertEq(pool.allowance(lpProvider, outsider), 0);
    }

    function testProvideLiquidityMintsProRataSharesForSecondLP() public {
        _mintAndApprove(secondProvider, 5 * ONE, 500 * ONE);

        uint256 supplyBefore = pool.totalSupply();

        vm.prank(secondProvider);
        (uint256 sharesMinted, uint256 baseAdded, uint256 quoteAdded) = pool.provideLiquidity(5 * ONE, 500 * ONE, 50 * ONE);

        assertEq(sharesMinted, 50 * ONE);
        assertEq(baseAdded, 5 * ONE);
        assertEq(quoteAdded, 500 * ONE);
        assertEq(pool.balanceOf(secondProvider), 50 * ONE);
        assertEq(pool.totalSupply(), supplyBefore + 50 * ONE);
        assertEq(pool.baseBalance(), 15 * ONE);
        assertEq(pool.quoteBalance(), 1500 * ONE);
        assertEq(pool.targetBaseTokenAmount(), 15 * ONE);
        assertEq(pool.targetQuoteTokenAmount(), 1500 * ONE);
    }

    function testProvideLiquidityRevertsOnZeroOrUnbalancedState() public {
        _mintAndApprove(secondProvider, 5 * ONE, 500 * ONE);

        vm.prank(secondProvider);
        vm.expectRevert(bytes("NO_LIQUIDITY"));
        pool.provideLiquidity(0, 500 * ONE, 0);

        uint256 totalPaid = pool.queryBuyBaseToken(ONE);
        vm.prank(trader);
        pool.buyBaseToken(ONE, totalPaid);

        vm.prank(secondProvider);
        vm.expectRevert(bytes("NOT_BALANCED"));
        pool.provideLiquidity(5 * ONE, 500 * ONE, 0);
    }

    function testWithdrawLiquidityChecksBounds() public {
        uint256 shares = pool.balanceOf(lpProvider) / 2;

        vm.prank(lpProvider);
        vm.expectRevert(bytes("ZERO_SHARES"));
        pool.withdrawLiquidity(0, 0, 0);

        vm.prank(lpProvider);
        vm.expectRevert(bytes("BASE_AMOUNT_NOT_ENOUGH"));
        pool.withdrawLiquidity(shares, 6 * ONE, 0);

        vm.prank(lpProvider);
        vm.expectRevert(bytes("QUOTE_AMOUNT_NOT_ENOUGH"));
        pool.withdrawLiquidity(shares, 0, 600 * ONE);
    }

    function testOwnerCanRecoverOnlyExcessOrStrayTokens() public {
        stray.mint(address(pool), 7 * ONE);

        uint256 strayBefore = stray.balanceOf(address(this));
        pool.recoverToken(address(stray), address(this), 7 * ONE);
        assertEq(stray.balanceOf(address(this)) - strayBefore, 7 * ONE);

        base.mint(address(pool), ONE);
        uint256 ownerBaseBefore = base.balanceOf(address(this));
        pool.recoverToken(address(base), address(this), ONE);
        assertEq(base.balanceOf(address(this)) - ownerBaseBefore, ONE);

        vm.expectRevert(bytes("BASE_BALANCE_NOT_ENOUGH"));
        pool.recoverToken(address(base), address(this), 1);
    }

    function testRecoverQuoteTokenCannotDrainTrackedLiquidity() public {
        vm.expectRevert(bytes("QUOTE_BALANCE_NOT_ENOUGH"));
        pool.recoverToken(address(quote), address(this), 1);
    }

    function testSellTaxReducesTraderProceedsAndKeepsPoolAccounting() public {
        uint256 sellAmount = ONE;
        uint256 untaxedReceive = pool.querySellBaseToken(sellAmount);

        pool.setTaxRecipient(taxRecipient);
        pool.setSellTaxRate(5e16);
        pool.enableTax();

        uint256 taxedReceive = pool.querySellBaseToken(sellAmount);
        assertLt(taxedReceive, untaxedReceive);

        uint256 traderQuoteBefore = quote.balanceOf(trader);
        uint256 poolQuoteBefore = pool.quoteBalance();
        uint256 maintainerQuoteBefore = quote.balanceOf(maintainer);
        uint256 taxQuoteBefore = quote.balanceOf(taxRecipient);

        vm.prank(trader);
        uint256 received = pool.sellBaseToken(sellAmount, taxedReceive);

        uint256 traderQuoteAfter = quote.balanceOf(trader);
        uint256 poolQuoteAfter = pool.quoteBalance();
        uint256 maintainerQuoteAfter = quote.balanceOf(maintainer);
        uint256 taxQuoteAfter = quote.balanceOf(taxRecipient);

        assertEq(received, taxedReceive);
        assertEq(traderQuoteAfter - traderQuoteBefore, taxedReceive);
        assertTrue(taxQuoteAfter > taxQuoteBefore);
        assertEq(
            poolQuoteBefore - poolQuoteAfter,
            (traderQuoteAfter - traderQuoteBefore)
                + (maintainerQuoteAfter - maintainerQuoteBefore)
                + (taxQuoteAfter - taxQuoteBefore)
        );
    }

    function testSellPaysMaintainerInQuoteAndMovesPoolBelowOne() public {
        uint256 sellAmount = ONE;
        uint256 maintainerQuoteBefore = quote.balanceOf(maintainer);
        uint256 poolQuoteBefore = pool.quoteBalance();
        uint256 traderQuoteBefore = quote.balanceOf(trader);
        uint256 minReceiveQuote = pool.querySellBaseToken(sellAmount);

        vm.prank(trader);
        uint256 traderReceived = pool.sellBaseToken(sellAmount, minReceiveQuote);

        uint256 maintainerQuoteAfter = quote.balanceOf(maintainer);

        assertTrue(maintainerQuoteAfter > maintainerQuoteBefore);
        assertEq(
            poolQuoteBefore - pool.quoteBalance(),
            traderReceived + (maintainerQuoteAfter - maintainerQuoteBefore)
        );
        assertEq(quote.balanceOf(trader) - traderQuoteBefore, traderReceived);
        assertEq(uint256(pool.rStatus()), uint256(MinimalDodoPMM.RStatus.BELOW_ONE));
    }

    function testSupervisorCanPauseTradingAndOwnerCanResume() public {
        vm.prank(supervisor);
        pool.disableTrading();

        uint256 totalPaid = pool.queryBuyBaseToken(ONE);

        vm.prank(trader);
        vm.expectRevert(bytes("TRADE_NOT_ALLOWED"));
        pool.buyBaseToken(ONE, totalPaid);

        pool.enableTrading();

        vm.prank(trader);
        pool.buyBaseToken(ONE, totalPaid);
        assertEq(uint256(pool.rStatus()), uint256(MinimalDodoPMM.RStatus.ABOVE_ONE));
    }

    function testDirectionalSwitchesBlockOnlyTheirSide() public {
        pool.disableBuying();
        uint256 buyQuote = pool.queryBuyBaseToken(ONE);

        vm.prank(trader);
        vm.expectRevert(bytes("BUYING_NOT_ALLOWED"));
        pool.buyBaseToken(ONE, buyQuote);

        pool.enableBuying();
        pool.disableSelling();
        uint256 sellQuote = pool.querySellBaseToken(ONE);

        vm.prank(trader);
        vm.expectRevert(bytes("SELLING_NOT_ALLOWED"));
        pool.sellBaseToken(ONE, sellQuote);
    }

    function testAccessControlAndParameterGuards() public {
        vm.prank(outsider);
        vm.expectRevert(bytes("NOT_OWNER"));
        pool.setK(2e17);

        vm.prank(outsider);
        vm.expectRevert(bytes("NOT_SUPERVISOR_OR_OWNER"));
        pool.disableTrading();

        vm.expectRevert(bytes("K=0"));
        pool.setK(0);

        vm.expectRevert(bytes("K>=1"));
        pool.setK(ONE);

        vm.expectRevert(bytes("BUY_TAX_RATE>=1"));
        pool.setBuyTaxRate(ONE);

        vm.expectRevert(bytes("FEE_RATE>=1"));
        pool.setSellTaxRate(997e15);
    }

    function testFuzzQuoteQueriesGrowWithOrderSize(uint96 rawSmall, uint96 rawLarge) public view {
        uint256 small = bound(uint256(rawSmall), 1, ONE);
        uint256 large = bound(uint256(rawLarge), small + 1, 2 * ONE);

        assertLt(pool.queryBuyBaseToken(small), pool.queryBuyBaseToken(large));
        assertLt(pool.querySellBaseToken(small), pool.querySellBaseToken(large));
    }

    function testOnlyNeededAdminSurfaceIsPresent() public view {
        assertEq(pool.owner(), address(this));
        assertEq(pool.supervisor(), supervisor);
        assertEq(pool.maintainer(), maintainer);
        assertEq(pool.balanceOf(lpProvider), pool.totalSupply());
        assertTrue(pool.tradingEnabled());
        assertTrue(pool.buyingEnabled());
        assertTrue(pool.sellingEnabled());
    }
}
