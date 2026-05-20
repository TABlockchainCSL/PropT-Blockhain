// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {RStatus} from "../../src/amm/types/PMMTypes.sol";
import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {AMMTestBase, MockERC20} from "./helpers/AMMTestBase.sol";

contract MockDividendDistributor {
    MockERC20 public immutable stablecoin;
    uint256 public claimAmount;
    uint256 public pendingAmount;

    constructor(MockERC20 stablecoin_) {
        stablecoin = stablecoin_;
    }

    function setClaimAmount(uint256 amount) external {
        claimAmount = amount;
    }

    function setPendingAmount(uint256 amount) external {
        pendingAmount = amount;
    }

    function claimDividends(uint256) external {
        uint256 amount = claimAmount;
        claimAmount = 0;
        stablecoin.transfer(msg.sender, amount);
    }

    function pendingDividends(address, uint256) external view returns (uint256) {
        return pendingAmount;
    }
}

contract MinimalDodoPMMDeploymentConfigTest is AMMTestBase {
    function testConstructorRejectsInvalidPoolConfiguration() public {
        vm.expectRevert(bytes("IDENTICAL_TOKENS"));
        _newPoolWithTokens(address(base), address(base), maintainer);

        vm.expectRevert(bytes("MAINTAINER_NOT_SET"));
        _newPoolWithTokens(address(base), address(quote), address(0));
    }

    function testConstructorSupportsNon18DecimalTokensAndRejectsOver18Decimals() public {
        MockERC20 sixBase = new MockERC20("Six Base", "SIXB", 6);
        MockERC20 sixDecimals = new MockERC20("Six", "SIX", 6);
        MinimalDodoPMM sixDecimalPool = _newPoolWithTokens(address(sixBase), address(sixDecimals), maintainer);

        assertEq(sixDecimalPool.baseTokenDecimals(), 6);
        assertEq(sixDecimalPool.quoteTokenDecimals(), 6);
        assertEq(sixDecimalPool.baseTokenScale(), 1e12);
        assertEq(sixDecimalPool.quoteTokenScale(), 1e12);

        MockERC20 nineteenDecimals = new MockERC20("Nineteen", "NINE", 19);

        vm.expectRevert(bytes("BASE_DECIMALS_GT_18"));
        _newPoolWithTokens(address(nineteenDecimals), address(quote), maintainer);

        vm.expectRevert(bytes("QUOTE_DECIMALS_GT_18"));
        _newPoolWithTokens(address(base), address(nineteenDecimals), maintainer);
    }

    function testInitialPoolStateTracksTargetsAndMidPrice() public {
        (uint256 expectedBaseTarget, uint256 expectedQuoteTarget) = pool.getExpectedTarget();

        assertEq(pool.totalSupply(), 100 * ONE);
        assertEq(pool.baseBalance(), INITIAL_BASE);
        assertEq(pool.quoteBalance(), INITIAL_QUOTE);
        assertEq(pool.targetBaseTokenAmount(), INITIAL_BASE);
        assertEq(pool.targetQuoteTokenAmount(), INITIAL_QUOTE);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ONE));
        assertEq(expectedBaseTarget, INITIAL_BASE);
        assertEq(expectedQuoteTarget, INITIAL_QUOTE);
        assertEq(pool.getValuationPrice(), INITIAL_PRICE);
        assertEq(pool.getEffectiveK(), pool.k());
        assertEq(pool.getMidPrice(), INITIAL_PRICE);
        _assertTrackedBalancesAtMostActual();
    }

    function testAccessControlAndParameterGuards() public {
        vm.prank(outsider);
        vm.expectRevert(bytes("NOT_OWNER"));
        pool.setK(2e17);

        vm.prank(outsider);
        vm.expectRevert(bytes("NOT_OWNER"));
        pool.setAgeAdjustedK(7e17, 0);

        vm.prank(outsider);
        vm.expectRevert(bytes("NOT_SUPERVISOR_OR_OWNER"));
        pool.disableTrading();

        vm.expectRevert(bytes("K=0"));
        pool.setK(0);

        vm.expectRevert(bytes("K>=1"));
        pool.setK(ONE);

        vm.expectRevert(bytes("MAX_K<K"));
        pool.setAgeAdjustedK(1e17 - 1, 0);

        vm.expectRevert(bytes("MAX_K>=1"));
        pool.setAgeAdjustedK(ONE, 0);

        vm.expectRevert(bytes("BUY_TAX_RATE>=1"));
        pool.setBuyTaxRate(ONE);

        vm.expectRevert(bytes("FEE_RATE>=1"));
        pool.setSellTaxRate(997e15);

        pool.setMaintainerFeeRate(0);
        pool.setMaintainer(address(0));

        vm.expectRevert(bytes("MAINTAINER_NOT_SET"));
        pool.setMaintainerFeeRate(1);

        vm.expectRevert(bytes("INVALID_MIN_VALUATION_PRICE"));
        pool.setValuationValidation(1 hours, 0, 100 * ONE);

        vm.expectRevert(bytes("INVALID_MAX_VALUATION_PRICE"));
        pool.setValuationValidation(1 hours, 100 * ONE, 99 * ONE);

        vm.expectRevert(bytes("INVALID_VALUATION_STALENESS"));
        pool.setValuationValidation(0, 1, 100 * ONE);
    }

    function testOnlyNeededAdminSurfaceIsPresent() public {
        assertEq(pool.owner(), address(this));
        assertEq(pool.supervisor(), supervisor);
        assertEq(pool.maintainer(), maintainer);
        assertEq(pool.balanceOf(lpProvider), pool.totalSupply());
        assertTrue(pool.tradingEnabled());
        assertTrue(pool.buyingEnabled());
        assertTrue(pool.sellingEnabled());
    }
}

contract MinimalDodoPMMValuationTest is AMMTestBase {
    function testValuationRejectsZeroStaleFutureAndOutOfRangePrices() public {
        vm.expectRevert(bytes("INVALID_VALUATION_PRICE"));
        pool.setValuationPrice(0);

        pool.setValuationPrice(INITIAL_PRICE);
        vm.warp(block.timestamp + pool.valuationMaxStaleness() + 1);
        vm.expectRevert(bytes("STALE_VALUATION_PRICE"));
        pool.queryBuyBaseToken(ONE);

        vm.expectRevert(bytes("VALUATION_TIMESTAMP_IN_FUTURE"));
        pool.setValuationPriceWithTimestamp(INITIAL_PRICE, block.timestamp + 1);

        pool.setValuationPrice(INITIAL_PRICE);
        pool.setValuationValidation(1 hours, 90 * ONE, 110 * ONE);
        vm.expectRevert(bytes("VALUATION_PRICE_OUT_OF_RANGE"));
        pool.setValuationPrice(120 * ONE);
    }

    function testValuationExpiryBoundary() public {
        pool.setValuationPrice(INITIAL_PRICE);
        uint256 updatedAt = block.timestamp;

        vm.warp(updatedAt + pool.valuationMaxStaleness());
        assertGt(pool.queryBuyBaseToken(ONE), 0);

        vm.warp(updatedAt + pool.valuationMaxStaleness() + 1);
        vm.expectRevert(bytes("STALE_VALUATION_PRICE"));
        pool.queryBuyBaseToken(ONE);
    }

    function testSetValuationPriceRejectsInvalidAndUpdatesPrice() public {
        vm.expectRevert(bytes("NOT_OWNER"));
        vm.prank(outsider);
        pool.setValuationPrice(111 * ONE);

        pool.setValuationPrice(111 * ONE);
        assertEq(pool.getValuationPrice(), 111 * ONE);
    }

    function testEffectiveKGrowsWithValuationAgeAndCapsAtMaxK() public {
        uint256 baseK = pool.k();
        uint256 maxK = 7e17;
        uint256 growthPerSecond = 1e15;
        pool.setAgeAdjustedK(maxK, growthPerSecond);

        pool.setValuationPrice(INITIAL_PRICE);
        assertEq(pool.getEffectiveK(), baseK);

        vm.warp(block.timestamp + 100);
        assertEq(pool.getEffectiveK(), baseK + (100 * growthPerSecond));

        vm.warp(block.timestamp + 1000);
        assertEq(pool.getEffectiveK(), maxK);
    }

    function testZeroGrowthFreezesEffectiveK() public {
        pool.setAgeAdjustedK(7e17, 0);
        pool.setValuationPrice(INITIAL_PRICE);
        vm.warp(block.timestamp + 90 days);
        assertEq(pool.getEffectiveK(), pool.k());
    }

    function testSetKAfterAgeConfigChecksMaxK() public {
        pool.setAgeAdjustedK(2e17, 0);

        vm.expectRevert(bytes("MAX_K<K"));
        pool.setK(3e17);

        pool.setK(15e16);
        assertEq(pool.k(), 15e16);
    }

    function testAgedValuationWorsensFixedSizeQuotes() public {
        pool.setAgeAdjustedK(7e17, 1e15);
        pool.setValuationPrice(INITIAL_PRICE);

        uint256 freshBuyQuote = pool.queryBuyBaseToken(ONE);
        uint256 freshSellQuote = pool.querySellBaseToken(ONE);

        vm.warp(block.timestamp + 100);

        assertGt(pool.queryBuyBaseToken(ONE), freshBuyQuote);
        assertLt(pool.querySellBaseToken(ONE), freshSellQuote);
    }
}

contract MinimalDodoPMMLiquidityTest is AMMTestBase {
    struct LiquiditySnapshot {
        uint256 supply;
        uint256 baseBalance;
        uint256 quoteBalance;
        uint256 baseTarget;
        uint256 quoteTarget;
        uint256 rStatus;
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
        assertGt(baseOut, 0);
        assertGt(quoteOut, 0);
    }

    function testProvideLiquidityMintsProRataSharesForSecondLP() public {
        _mintAndApprove(secondProvider, 5 * ONE, 500 * ONE);

        uint256 supplyBefore = pool.totalSupply();

        vm.prank(secondProvider);
        (uint256 sharesMinted, uint256 baseAdded, uint256 quoteAdded) =
            pool.provideLiquidity(5 * ONE, 500 * ONE, 50 * ONE);

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

    function testProvideLiquidityRejectsZeroAndAllowsUnbalancedProRata() public {
        _mintAndApprove(secondProvider, 5 * ONE, 500 * ONE);

        vm.prank(secondProvider);
        vm.expectRevert(bytes("NO_LIQUIDITY"));
        pool.provideLiquidity(0, 500 * ONE, 0);

        uint256 totalPaid = pool.queryBuyBaseToken(ONE);
        vm.prank(trader);
        pool.buyBaseToken(ONE, totalPaid);

        LiquiditySnapshot memory beforeState = LiquiditySnapshot({
            supply: pool.totalSupply(),
            baseBalance: pool.baseBalance(),
            quoteBalance: pool.quoteBalance(),
            baseTarget: pool.targetBaseTokenAmount(),
            quoteTarget: pool.targetQuoteTokenAmount(),
            rStatus: uint256(pool.rStatus())
        });
        uint256 expectedSharesFromBase = (5 * ONE * beforeState.supply) / beforeState.baseBalance;
        uint256 expectedSharesFromQuote = (500 * ONE * beforeState.supply) / beforeState.quoteBalance;
        uint256 expectedShares =
            expectedSharesFromBase < expectedSharesFromQuote ? expectedSharesFromBase : expectedSharesFromQuote;
        uint256 expectedBaseAdded = (expectedShares * beforeState.baseBalance) / beforeState.supply;
        uint256 expectedQuoteAdded = (expectedShares * beforeState.quoteBalance) / beforeState.supply;

        vm.prank(secondProvider);
        (uint256 sharesMinted, uint256 baseAdded, uint256 quoteAdded) = pool.provideLiquidity(5 * ONE, 500 * ONE, 0);

        assertEq(sharesMinted, expectedShares);
        assertEq(baseAdded, expectedBaseAdded);
        assertEq(quoteAdded, expectedQuoteAdded);
        assertEq(pool.baseBalance(), beforeState.baseBalance + expectedBaseAdded);
        assertEq(pool.quoteBalance(), beforeState.quoteBalance + expectedQuoteAdded);
        assertEq(
            pool.targetBaseTokenAmount(),
            beforeState.baseTarget + ((beforeState.baseTarget * expectedShares) / beforeState.supply)
        );
        assertEq(
            pool.targetQuoteTokenAmount(),
            beforeState.quoteTarget + ((beforeState.quoteTarget * expectedShares) / beforeState.supply)
        );
        assertEq(uint256(pool.rStatus()), beforeState.rStatus);
    }

    function testSecondLiquidityUsesFullPrecisionMathWhenIntermediateProductWouldOverflow() public {
        MockERC20 hugeBase = new MockERC20("Huge Base", "HBASE", 18);
        MockERC20 hugeQuote = new MockERC20("Huge Quote", "HQUOTE", 18);
        MinimalDodoPMM hugePool = _newPoolWithTokens(address(hugeBase), address(hugeQuote), maintainer);

        uint256 initialBase = uint256(1) << 64;
        uint256 initialQuote = uint256(1) << 191;
        hugeBase.mint(lpProvider, initialBase);
        hugeQuote.mint(lpProvider, initialQuote);

        vm.startPrank(lpProvider);
        hugeBase.approve(address(hugePool), type(uint256).max);
        hugeQuote.approve(address(hugePool), type(uint256).max);
        hugePool.provideLiquidity(initialBase, initialQuote, 0);
        vm.stopPrank();

        uint256 baseMax = uint256(1) << 150;
        uint256 quoteMax = uint256(1) << 129;
        uint256 supply = hugePool.totalSupply();
        assertGt(baseMax, type(uint256).max / supply);

        hugeBase.mint(secondProvider, baseMax);
        hugeQuote.mint(secondProvider, quoteMax);
        vm.startPrank(secondProvider);
        hugeBase.approve(address(hugePool), type(uint256).max);
        hugeQuote.approve(address(hugePool), type(uint256).max);
        (uint256 sharesMinted, uint256 baseAdded, uint256 quoteAdded) = hugePool.provideLiquidity(baseMax, quoteMax, 0);
        vm.stopPrank();

        assertGt(sharesMinted, 0);
        assertGt(baseAdded, 0);
        assertGt(quoteAdded, 0);
        assertLe(baseAdded, baseMax);
        assertLe(quoteAdded, quoteMax);
    }

    function testSixDecimalPoolUsesNativeTokenAmountsAndWadAccounting() public {
        MockERC20 sixBase = new MockERC20("Six Base", "SIXB", 6);
        MockERC20 sixQuote = new MockERC20("Six Quote", "SIXQ", 6);
        MinimalDodoPMM sixPool = _newPoolWithTokens(address(sixBase), address(sixQuote), maintainer);

        uint256 nativeBaseLiquidity = 10e6;
        uint256 nativeQuoteLiquidity = 1000e6;
        sixBase.mint(lpProvider, nativeBaseLiquidity);
        sixQuote.mint(lpProvider, nativeQuoteLiquidity);

        vm.startPrank(lpProvider);
        sixBase.approve(address(sixPool), type(uint256).max);
        sixQuote.approve(address(sixPool), type(uint256).max);
        (uint256 sharesMinted, uint256 baseAdded, uint256 quoteAdded) =
            sixPool.provideLiquidity(nativeBaseLiquidity, nativeQuoteLiquidity, 0);
        vm.stopPrank();

        assertEq(sharesMinted, 100 * ONE);
        assertEq(baseAdded, nativeBaseLiquidity);
        assertEq(quoteAdded, nativeQuoteLiquidity);
        assertEq(sixPool.baseBalance(), INITIAL_BASE);
        assertEq(sixPool.quoteBalance(), INITIAL_QUOTE);
        assertEq(sixBase.balanceOf(address(sixPool)), nativeBaseLiquidity);
        assertEq(sixQuote.balanceOf(address(sixPool)), nativeQuoteLiquidity);

        sixPool.enableTrading();
        sixQuote.mint(trader, 1000e6);
        vm.startPrank(trader);
        sixQuote.approve(address(sixPool), type(uint256).max);
        uint256 quotePaid = sixPool.queryBuyBaseToken(1e6);
        uint256 traderBaseBefore = sixBase.balanceOf(trader);
        sixPool.buyBaseToken(1e6, quotePaid);
        vm.stopPrank();

        assertEq(sixBase.balanceOf(trader) - traderBaseBefore, 1e6);
        assertEq(sixQuote.balanceOf(address(sixPool)), nativeQuoteLiquidity + quotePaid);
        assertGt(sixPool.quoteBalance(), INITIAL_QUOTE);
    }

    function testWithdrawLiquidityWorksWhenPoolIsUnbalanced() public {
        uint256 buyQuote = pool.queryBuyBaseToken(ONE);
        vm.prank(trader);
        pool.buyBaseToken(ONE, buyQuote);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));

        uint256 shares = pool.balanceOf(lpProvider) / 2;
        uint256 providerBaseBefore = base.balanceOf(lpProvider);
        uint256 providerQuoteBefore = quote.balanceOf(lpProvider);
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(lpProvider);
        (uint256 baseOut, uint256 quoteOut) = pool.withdrawLiquidity(shares, 0, 0);

        assertEq(pool.totalSupply(), supplyBefore - shares);
        assertEq(base.balanceOf(lpProvider) - providerBaseBefore, baseOut);
        assertEq(quote.balanceOf(lpProvider) - providerQuoteBefore, quoteOut);
        assertGt(baseOut, 0);
        assertGt(quoteOut, 0);
    }

    function testFinalUnbalancedWithdrawalResetsPoolAndOnlyDisablesTrading() public {
        uint256 buyQuote = pool.queryBuyBaseToken(ONE);
        vm.prank(trader);
        pool.buyBaseToken(ONE, buyQuote);

        uint256 shares = pool.balanceOf(lpProvider);

        vm.prank(lpProvider);
        pool.withdrawLiquidity(shares, 0, 0);

        _assertEmptyPoolState();
        assertTrue(pool.buyingEnabled());
        assertTrue(pool.sellingEnabled());
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
}

contract MinimalDodoPMMTradingTaxTest is AMMTestBase {
    function testTradesRejectZeroAmountWithoutChangingState() public {
        vm.prank(trader);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        pool.buyBaseToken(0, 0);

        assertEq(uint256(pool.rStatus()), uint256(RStatus.ONE));

        vm.prank(trader);
        vm.expectRevert(bytes("ZERO_AMOUNT"));
        pool.sellBaseToken(0, 0);

        assertEq(uint256(pool.rStatus()), uint256(RStatus.ONE));
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

        assertEq(totalPaid, taxedQuote);
        assertEq(traderQuoteBefore - quote.balanceOf(trader), taxedQuote);
        assertEq(pool.quoteBalance() - poolQuoteBefore, untaxedQuote);
        assertEq(quote.balanceOf(taxRecipient) - taxQuoteBefore, expectedTax);
    }

    function testBuyPaysMaintainerInBaseAndMovesPoolAboveOne() public {
        uint256 buyAmount = ONE;
        uint256 maintainerBaseBefore = base.balanceOf(maintainer);
        uint256 poolBaseBefore = pool.baseBalance();
        uint256 totalPaid = pool.queryBuyBaseToken(buyAmount);

        vm.prank(trader);
        pool.buyBaseToken(buyAmount, totalPaid);

        uint256 maintainerBasePaid = base.balanceOf(maintainer) - maintainerBaseBefore;

        assertGt(maintainerBasePaid, 0);
        assertEq(pool.baseBalance() + buyAmount + maintainerBasePaid, poolBaseBefore);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));
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

        uint256 traderReceived = quote.balanceOf(trader) - traderQuoteBefore;
        uint256 maintainerPaid = quote.balanceOf(maintainer) - maintainerQuoteBefore;
        uint256 taxPaid = quote.balanceOf(taxRecipient) - taxQuoteBefore;

        assertEq(received, taxedReceive);
        assertEq(traderReceived, taxedReceive);
        assertGt(taxPaid, 0);
        assertEq(poolQuoteBefore - pool.quoteBalance(), traderReceived + maintainerPaid + taxPaid);
    }

    function testSellPaysMaintainerInQuoteAndMovesPoolBelowOne() public {
        uint256 sellAmount = ONE;
        uint256 maintainerQuoteBefore = quote.balanceOf(maintainer);
        uint256 poolQuoteBefore = pool.quoteBalance();
        uint256 traderQuoteBefore = quote.balanceOf(trader);
        uint256 minReceiveQuote = pool.querySellBaseToken(sellAmount);

        vm.prank(trader);
        uint256 traderReceived = pool.sellBaseToken(sellAmount, minReceiveQuote);

        uint256 maintainerPaid = quote.balanceOf(maintainer) - maintainerQuoteBefore;

        assertGt(maintainerPaid, 0);
        assertEq(poolQuoteBefore - pool.quoteBalance(), traderReceived + maintainerPaid);
        assertEq(quote.balanceOf(trader) - traderQuoteBefore, traderReceived);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.BELOW_ONE));
    }
}

contract MinimalDodoPMMControlsTest is AMMTestBase {
    function testEnableTaxRequiresRecipient() public {
        vm.expectRevert(bytes("TAX_RECIPIENT_NOT_SET"));
        pool.enableTax();
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
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));
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

    function testTaxRecipientCannotBeClearedWhileTaxEnabled() public {
        pool.setTaxRecipient(taxRecipient);
        pool.enableTax();

        vm.expectRevert(bytes("TAX_RECIPIENT_NOT_SET"));
        pool.setTaxRecipient(address(0));

        pool.disableTax();
        pool.setTaxRecipient(address(0));
        assertEq(pool.taxRecipient(), address(0));
    }
}

contract MinimalDodoPMMDividendTest is AMMTestBase {
    function testClaimQuoteDividendsAddsClaimedQuoteAsSurplusReserve() public {
        MockDividendDistributor dividend = new MockDividendDistributor(quote);
        quote.mint(address(dividend), 25 * ONE);
        dividend.setClaimAmount(25 * ONE);

        uint256 actualQuoteBefore = quote.balanceOf(address(pool));
        uint256 quoteBalanceBefore = pool.quoteBalance();
        uint256 targetQuoteBefore = pool.targetQuoteTokenAmount();
        uint256 midPriceBefore = pool.getMidPrice();
        uint256 sellQuoteBefore = pool.querySellBaseToken(ONE);

        uint256 claimed = pool.claimQuoteDividends(address(dividend), type(uint256).max);

        assertEq(claimed, 25 * ONE);
        assertEq(quote.balanceOf(address(pool)) - actualQuoteBefore, 25 * ONE);
        assertEq(pool.quoteBalance(), quoteBalanceBefore + 25 * ONE);
        assertEq(pool.targetQuoteTokenAmount(), targetQuoteBefore);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));
        assertGt(pool.getMidPrice(), midPriceBefore);
        assertGt(pool.querySellBaseToken(ONE), sellQuoteBefore);
        _assertTrackedBalancesAtMostActual();
    }

    function testClaimQuoteDividendsWhileAlreadyUnbalancedPreservesStatusAndTargets() public {
        uint256 buyQuote = pool.queryBuyBaseToken(ONE);

        vm.prank(trader);
        pool.buyBaseToken(ONE, buyQuote);

        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));
        uint256 targetBaseBefore = pool.targetBaseTokenAmount();
        uint256 targetQuoteBefore = pool.targetQuoteTokenAmount();

        MockDividendDistributor dividend = new MockDividendDistributor(quote);
        quote.mint(address(dividend), 5 * ONE);
        dividend.setClaimAmount(5 * ONE);

        pool.claimQuoteDividends(address(dividend), type(uint256).max);

        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));
        assertEq(pool.targetBaseTokenAmount(), targetBaseBefore);
        assertEq(pool.targetQuoteTokenAmount(), targetQuoteBefore);
        _assertTrackedBalancesAtMostActual();
    }

    function testPendingQuoteDividendsReadsPoolPendingAmount() public {
        MockDividendDistributor dividend = new MockDividendDistributor(quote);
        dividend.setPendingAmount(11 * ONE);

        assertEq(pool.pendingQuoteDividends(address(dividend), 3), 11 * ONE);
    }

    function testClaimQuoteDividendsChecksOwnerDistributorAndStablecoin() public {
        MockDividendDistributor dividend = new MockDividendDistributor(quote);

        vm.prank(outsider);
        vm.expectRevert(bytes("NOT_OWNER"));
        pool.claimQuoteDividends(address(dividend), type(uint256).max);

        vm.expectRevert(bytes("INVALID_DIVIDEND_DISTRIBUTOR"));
        pool.claimQuoteDividends(address(0), type(uint256).max);

        MockDividendDistributor wrongDividend = new MockDividendDistributor(base);
        vm.expectRevert(bytes("DIVIDEND_TOKEN_NOT_QUOTE"));
        pool.claimQuoteDividends(address(wrongDividend), type(uint256).max);
    }

    function testClaimQuoteDividendsRejectsZeroClaim() public {
        MockDividendDistributor dividend = new MockDividendDistributor(quote);

        vm.expectRevert(bytes("NO_DIVIDEND_CLAIMED"));
        pool.claimQuoteDividends(address(dividend), type(uint256).max);
    }
}
