// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {RStatus} from "../../src/amm/types/PMMTypes.sol";
import {AMMTestBase, MockERC20, MockOracle} from "./helpers/AMMTestBase.sol";

contract MinimalDodoPMMUnitTest is AMMTestBase {
    function testEnableTaxRequiresRecipient() public {
        vm.expectRevert(bytes("TAX_RECIPIENT_NOT_SET"));
        pool.enableTax();
    }

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

    function testConstructorRejectsInvalidPoolConfiguration() public {
        vm.expectRevert(bytes("IDENTICAL_TOKENS"));
        _newPoolWithTokens(address(base), address(base), maintainer);

        vm.expectRevert(bytes("MAINTAINER_NOT_SET"));
        _newPoolWithTokens(address(base), address(quote), address(0));
    }

    function testConstructorRejectsNon18DecimalTokens() public {
        MockERC20 sixDecimals = new MockERC20("Six", "SIX", 6);

        vm.expectRevert(bytes("BASE_DECIMALS_NOT_18"));
        _newPoolWithTokens(address(sixDecimals), address(quote), maintainer);

        vm.expectRevert(bytes("QUOTE_DECIMALS_NOT_18"));
        _newPoolWithTokens(address(base), address(sixDecimals), maintainer);
    }

    function testOracleRejectsZeroStaleFutureAndOutOfRangePrices() public {
        oracle.setPrice(0);
        vm.expectRevert(bytes("INVALID_ORACLE_PRICE"));
        pool.queryBuyBaseToken(ONE);

        oracle.setPrice(INITIAL_PRICE);
        vm.warp(block.timestamp + pool.oracleMaxStaleness() + 1);
        vm.expectRevert(bytes("STALE_ORACLE_PRICE"));
        pool.queryBuyBaseToken(ONE);

        oracle.setPriceWithTimestamp(INITIAL_PRICE, block.timestamp + 1);
        vm.expectRevert(bytes("ORACLE_TIMESTAMP_IN_FUTURE"));
        pool.queryBuyBaseToken(ONE);

        oracle.setPrice(INITIAL_PRICE);
        pool.setOracleValidation(1 hours, 90 * ONE, 110 * ONE);
        oracle.setPrice(120 * ONE);
        vm.expectRevert(bytes("ORACLE_PRICE_OUT_OF_RANGE"));
        pool.queryBuyBaseToken(ONE);
    }

    function testValuationExpiryBoundary() public {
        oracle.setPrice(INITIAL_PRICE);
        uint256 updatedAt = block.timestamp;

        vm.warp(updatedAt + pool.oracleMaxStaleness());
        assertGt(pool.queryBuyBaseToken(ONE), 0);

        vm.warp(updatedAt + pool.oracleMaxStaleness() + 1);
        vm.expectRevert(bytes("STALE_ORACLE_PRICE"));
        pool.queryBuyBaseToken(ONE);
    }

    function testSetOracleRejectsZeroAndUsesNewOracle() public {
        vm.expectRevert(bytes("INVALID_ORACLE"));
        pool.setOracle(address(0));

        MockOracle newOracle = new MockOracle();
        newOracle.setPrice(111 * ONE);
        pool.setOracle(address(newOracle));
        assertEq(pool.getOraclePrice(), 111 * ONE);
    }

    function testInitialPoolStateTracksTargetsAndMidPrice() public view {
        (uint256 expectedBaseTarget, uint256 expectedQuoteTarget) = pool.getExpectedTarget();

        assertEq(pool.totalSupply(), 100 * ONE);
        assertEq(pool.baseBalance(), INITIAL_BASE);
        assertEq(pool.quoteBalance(), INITIAL_QUOTE);
        assertEq(pool.targetBaseTokenAmount(), INITIAL_BASE);
        assertEq(pool.targetQuoteTokenAmount(), INITIAL_QUOTE);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ONE));
        assertEq(expectedBaseTarget, INITIAL_BASE);
        assertEq(expectedQuoteTarget, INITIAL_QUOTE);
        assertEq(pool.getOraclePrice(), INITIAL_PRICE);
        assertEq(pool.getEffectiveK(), pool.k());
        assertEq(pool.getMidPrice(), INITIAL_PRICE);
        _assertTrackedBalancesAtMostActual();
    }

    function testEffectiveKGrowsWithValuationAgeAndCapsAtMaxK() public {
        uint256 baseK = pool.k();
        uint256 maxK = 7e17;
        uint256 growthPerSecond = 1e15;
        pool.setAgeAdjustedK(maxK, growthPerSecond);

        oracle.setPrice(INITIAL_PRICE);
        assertEq(pool.getEffectiveK(), baseK);

        vm.warp(block.timestamp + 100);
        assertEq(pool.getEffectiveK(), baseK + (100 * growthPerSecond));

        vm.warp(block.timestamp + 1000);
        assertEq(pool.getEffectiveK(), maxK);
    }

    function testZeroGrowthFreezesEffectiveK() public {
        pool.setAgeAdjustedK(7e17, 0);
        oracle.setPrice(INITIAL_PRICE);
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
        oracle.setPrice(INITIAL_PRICE);

        uint256 freshBuyQuote = pool.queryBuyBaseToken(ONE);
        uint256 freshSellQuote = pool.querySellBaseToken(ONE);

        vm.warp(block.timestamp + 100);

        assertGt(pool.queryBuyBaseToken(ONE), freshBuyQuote);
        assertLt(pool.querySellBaseToken(ONE), freshSellQuote);
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

    function testLpTokenTransferFromUsesAllowance() public {
        uint256 transferAmount = pool.balanceOf(lpProvider) / 4;

        vm.prank(lpProvider);
        assertTrue(pool.approve(outsider, transferAmount));

        vm.prank(outsider);
        assertTrue(pool.transferFrom(lpProvider, lpReceiver, transferAmount));

        assertEq(pool.balanceOf(lpReceiver), transferAmount);
        assertEq(pool.allowance(lpProvider, outsider), 0);
    }

    function testLpTokenTransferFromWithMaxAllowanceDoesNotDecreaseAllowance() public {
        uint256 transferAmount = pool.balanceOf(lpProvider) / 4;

        vm.prank(lpProvider);
        pool.approve(outsider, type(uint256).max);

        vm.prank(outsider);
        assertTrue(pool.transferFrom(lpProvider, lpReceiver, transferAmount));

        assertEq(pool.allowance(lpProvider, outsider), type(uint256).max);
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

        vm.expectRevert(bytes("INVALID_MIN_ORACLE_PRICE"));
        pool.setOracleValidation(1 hours, 0, 100 * ONE);

        vm.expectRevert(bytes("INVALID_MAX_ORACLE_PRICE"));
        pool.setOracleValidation(1 hours, 100 * ONE, 99 * ONE);

        vm.expectRevert(bytes("INVALID_ORACLE_STALENESS"));
        pool.setOracleValidation(0, 1, 100 * ONE);
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
