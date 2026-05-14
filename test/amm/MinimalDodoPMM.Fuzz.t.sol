// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {MinimalDodoPMM} from "../../src/amm/MinimalDodoPMM.sol";
import {MathHelpers} from "../../src/amm/libraries/MathHelpers.sol";
import {RStatus} from "../../src/amm/types/PMMTypes.sol";
import {AMMTestBase, MockERC20} from "./helpers/AMMTestBase.sol";

contract MinimalDodoPMMFuzzTest is AMMTestBase {
    function testFuzzQuoteQueriesGrowWithOrderSize(uint96 rawSmall, uint96 rawLarge) public view {
        uint256 small = bound(uint256(rawSmall), 1, ONE);
        uint256 large = bound(uint256(rawLarge), small + 1, 2 * ONE);

        assertLt(pool.queryBuyBaseToken(small), pool.queryBuyBaseToken(large));
        assertLt(pool.querySellBaseToken(small), pool.querySellBaseToken(large));
    }

    function testFuzzEffectiveKAlwaysWithinBounds(uint64 rawAge, uint96 rawGrowth, uint96 rawMaxK) public {
        uint256 maxK = bound(uint256(rawMaxK), pool.k(), ONE - 1);
        uint256 growth = bound(uint256(rawGrowth), 0, 1e15);
        uint256 age = bound(uint256(rawAge), 0, pool.oracleMaxStaleness());

        pool.setAgeAdjustedK(maxK, growth);
        oracle.setPrice(INITIAL_PRICE);
        vm.warp(block.timestamp + age);

        uint256 effectiveK = pool.getEffectiveK();
        assertGe(effectiveK, pool.k());
        assertLe(effectiveK, pool.maxK());
    }

    function testFuzzAgedValuationDoesNotImproveFixedSizeBuy(uint96 rawAmount, uint64 rawAge) public {
        uint256 amount = bound(uint256(rawAmount), 1, ONE);
        uint256 age = bound(uint256(rawAge), 1, 1 days);
        pool.setAgeAdjustedK(7e17, 1e12);
        oracle.setPrice(INITIAL_PRICE);

        uint256 freshQuote = pool.queryBuyBaseToken(amount);
        vm.warp(block.timestamp + age);

        uint256 agedQuote = pool.queryBuyBaseToken(amount);
        assertGe(agedQuote + 1, freshQuote);
    }

    function testFuzzAgedValuationDoesNotImproveFixedSizeSell(uint96 rawAmount, uint64 rawAge) public {
        uint256 amount = bound(uint256(rawAmount), 1, ONE);
        uint256 age = bound(uint256(rawAge), 1, 1 days);
        pool.setAgeAdjustedK(7e17, 1e12);
        oracle.setPrice(INITIAL_PRICE);

        uint256 freshQuote = pool.querySellBaseToken(amount);
        vm.warp(block.timestamp + age);

        uint256 agedQuote = pool.querySellBaseToken(amount);
        assertLe(agedQuote, freshQuote + 1);
    }

    function testFuzzFirstLiquidityMintEqualsSqrt(uint96 rawBaseAmount, uint96 rawQuoteAmount) public {
        uint256 baseAmount = bound(uint256(rawBaseAmount), 1e12, 1000 * ONE);
        uint256 quoteAmount = bound(uint256(rawQuoteAmount), 1e12, 100_000 * ONE);
        MockERC20 freshBase = new MockERC20("Fresh Base", "FB", 18);
        MockERC20 freshQuote = new MockERC20("Fresh Quote", "FQ", 18);
        MinimalDodoPMM freshPool = _newPoolWithTokens(address(freshBase), address(freshQuote), maintainer);

        freshBase.mint(secondProvider, baseAmount);
        freshQuote.mint(secondProvider, quoteAmount);

        vm.startPrank(secondProvider);
        freshBase.approve(address(freshPool), type(uint256).max);
        freshQuote.approve(address(freshPool), type(uint256).max);
        (uint256 sharesMinted, uint256 baseAdded, uint256 quoteAdded) =
            freshPool.provideLiquidity(baseAmount, quoteAmount, 0);
        vm.stopPrank();

        assertEq(sharesMinted, MathHelpers.sqrt(baseAmount * quoteAmount));
        assertEq(baseAdded, baseAmount);
        assertEq(quoteAdded, quoteAmount);
        assertEq(freshPool.balanceOf(secondProvider), sharesMinted);
    }

    function testFuzzSecondLiquidityNeverConsumesMoreThanMax(uint96 rawBaseMax, uint96 rawQuoteMax) public {
        uint256 baseMax = bound(uint256(rawBaseMax), 1e12, 20 * ONE);
        uint256 quoteMax = bound(uint256(rawQuoteMax), 1e12, 2000 * ONE);
        _mintAndApprove(secondProvider, baseMax, quoteMax);

        vm.prank(secondProvider);
        (uint256 sharesMinted, uint256 baseAdded, uint256 quoteAdded) = pool.provideLiquidity(baseMax, quoteMax, 0);

        assertLe(baseAdded, baseMax);
        assertLe(quoteAdded, quoteMax);
        assertEq(pool.balanceOf(secondProvider), sharesMinted);
        assertEq(pool.totalSupply(), 100 * ONE + sharesMinted);
        if (sharesMinted > 0) {
            assertGt(baseAdded, 0);
            assertGt(quoteAdded, 0);
        }
    }

    function testFuzzWithdrawReturnsProportionalReserves(uint96 rawShares) public {
        uint256 shares = bound(uint256(rawShares), 1, pool.balanceOf(lpProvider));
        uint256 supplyBefore = pool.totalSupply();
        uint256 baseBefore = pool.baseBalance();
        uint256 quoteBefore = pool.quoteBalance();
        uint256 expectedBase = (baseBefore * shares) / supplyBefore;
        uint256 expectedQuote = (quoteBefore * shares) / supplyBefore;

        vm.prank(lpProvider);
        (uint256 baseOut, uint256 quoteOut) = pool.withdrawLiquidity(shares, 0, 0);

        assertEq(baseOut, expectedBase);
        assertEq(quoteOut, expectedQuote);
        assertEq(pool.totalSupply(), supplyBefore - shares);
    }

    function testFuzzBuyTaxAccounting(uint96 rawAmount, uint96 rawTaxRate) public {
        uint256 amount = bound(uint256(rawAmount), 1, ONE);
        uint256 taxRate = bound(uint256(rawTaxRate), 1, 2e17);
        uint256 untaxedQuote = pool.queryBuyBaseToken(amount);

        pool.setTaxRecipient(taxRecipient);
        pool.setBuyTaxRate(taxRate);
        pool.enableTax();

        uint256 totalQuote = pool.queryBuyBaseToken(amount);
        uint256 expectedTax = (untaxedQuote * taxRate) / ONE;
        assertEq(totalQuote, untaxedQuote + expectedTax);

        uint256 taxBefore = quote.balanceOf(taxRecipient);
        vm.prank(trader);
        pool.buyBaseToken(amount, totalQuote);

        assertEq(quote.balanceOf(taxRecipient) - taxBefore, expectedTax);
    }

    function testFuzzSellFeeAccounting(uint96 rawAmount, uint96 rawTaxRate) public {
        uint256 amount = bound(uint256(rawAmount), 1, ONE);
        uint256 taxRate = bound(uint256(rawTaxRate), 0, 2e17);
        pool.setTaxRecipient(taxRecipient);
        pool.setSellTaxRate(taxRate);
        pool.enableTax();

        uint256 quoteBefore = pool.quoteBalance();
        uint256 traderBefore = quote.balanceOf(trader);
        uint256 maintainerBefore = quote.balanceOf(maintainer);
        uint256 taxBefore = quote.balanceOf(taxRecipient);
        uint256 minReceive = pool.querySellBaseToken(amount);

        vm.prank(trader);
        uint256 received = pool.sellBaseToken(amount, minReceive);

        uint256 traderReceived = quote.balanceOf(trader) - traderBefore;
        uint256 maintainerPaid = quote.balanceOf(maintainer) - maintainerBefore;
        uint256 taxPaid = quote.balanceOf(taxRecipient) - taxBefore;

        assertEq(received, traderReceived);
        assertEq(quoteBefore - pool.quoteBalance(), traderReceived + maintainerPaid + taxPaid);
    }

    function testFuzzValidParameterUpdatesAreAccepted(uint96 rawK, uint96 rawMaxK, uint96 rawLpFee, uint96 rawMaintFee)
        public
    {
        uint256 newK = bound(uint256(rawK), 1, 5e17);
        uint256 newMaxK = bound(uint256(rawMaxK), newK, ONE - 1);
        uint256 newLpFee = bound(uint256(rawLpFee), 0, 1e17);
        uint256 newMaintFee = bound(uint256(rawMaintFee), 0, 1e17);

        pool.setMaintainer(maintainer);
        pool.setK(newK);
        pool.setAgeAdjustedK(newMaxK, 0);
        pool.setLpFeeRate(newLpFee);
        pool.setMaintainerFeeRate(newMaintFee);

        assertEq(pool.k(), newK);
        assertEq(pool.maxK(), newMaxK);
        assertEq(pool.lpFeeRate(), newLpFee);
        assertEq(pool.maintainerFeeRate(), newMaintFee);
    }

    function testFuzzPoolStatusAfterBuyOrSell(uint96 rawAmount, bool buySide) public {
        uint256 amount = bound(uint256(rawAmount), 1, ONE);
        if (buySide) {
            uint256 maxPay = pool.queryBuyBaseToken(amount);
            vm.prank(trader);
            pool.buyBaseToken(amount, maxPay);
            assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));
        } else {
            uint256 minReceive = pool.querySellBaseToken(amount);
            vm.prank(trader);
            pool.sellBaseToken(amount, minReceive);
            assertEq(uint256(pool.rStatus()), uint256(RStatus.BELOW_ONE));
        }
    }
}
