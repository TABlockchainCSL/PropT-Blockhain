// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {RStatus} from "../../src/amm/types/PMMTypes.sol";
import {AMMTestBase, MockERC20} from "./helpers/AMMTestBase.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract PropertyPMMFuzzTest is AMMTestBase {
    // Quotes and valuation behavior.
    function testFuzzQuoteQueriesGrowWithOrderSize(uint96 rawSmall, uint96 rawLarge) public {
        uint256 small = bound(uint256(rawSmall), 1, ONE);
        uint256 large = bound(uint256(rawLarge), small + 1, 2 * ONE);

        assertLt(pool.queryBuyBaseToken(small), pool.queryBuyBaseToken(large));
        assertLt(pool.querySellBaseToken(small), pool.querySellBaseToken(large));
    }

    function testFuzzAgedValuationDoesNotChangeFixedSizeBuy(uint96 rawAmount, uint64 rawAge) public {
        uint256 amount = bound(uint256(rawAmount), 1, ONE);
        uint256 age = bound(uint256(rawAge), 1, 1 days);
        pool.setValuationPrice(INITIAL_PRICE);

        uint256 freshQuote = pool.queryBuyBaseToken(amount);
        vm.warp(block.timestamp + age);

        uint256 agedQuote = pool.queryBuyBaseToken(amount);
        assertEq(agedQuote, freshQuote);
    }

    function testFuzzAgedValuationDoesNotChangeFixedSizeSell(uint96 rawAmount, uint64 rawAge) public {
        uint256 amount = bound(uint256(rawAmount), 1, ONE);
        uint256 age = bound(uint256(rawAge), 1, 1 days);
        pool.setValuationPrice(INITIAL_PRICE);

        uint256 freshQuote = pool.querySellBaseToken(amount);
        vm.warp(block.timestamp + age);

        uint256 agedQuote = pool.querySellBaseToken(amount);
        assertEq(agedQuote, freshQuote);
    }

    // Liquidity share accounting.
    function testFuzzFirstLiquidityMintEqualsSqrt(uint96 rawBaseAmount, uint96 rawQuoteAmount) public {
        uint256 baseAmount = bound(uint256(rawBaseAmount), 1e12, 1000 * ONE);
        uint256 quoteAmount = bound(uint256(rawQuoteAmount), 1e12, 100_000 * ONE);
        MockERC20 freshBase = new MockERC20("Fresh Base", "FB", 18);
        MockERC20 freshQuote = new MockERC20("Fresh Quote", "FQ", 18);
        _setTokenKycRegistry(address(freshBase));
        PropertyPMM freshPool = _newPoolWithTokens(address(freshBase), address(freshQuote), maintainer);

        freshBase.mint(secondProvider, baseAmount);
        freshQuote.mint(secondProvider, quoteAmount);

        vm.startPrank(secondProvider);
        freshBase.approve(address(freshPool), type(uint256).max);
        freshQuote.approve(address(freshPool), type(uint256).max);
        (uint256 sharesMinted, uint256 baseAdded, uint256 quoteAdded) =
            freshPool.provideLiquidity(baseAmount, quoteAmount, 0);
        vm.stopPrank();

        assertEq(sharesMinted, FixedPointMathLib.sqrt(baseAmount * quoteAmount));
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

    // Fee and tax accounting.
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

        // Tax should be accumulated in the pool, not transferred directly.
        assertEq(pool.pendingTaxQuote(), expectedTax);
        assertEq(quote.balanceOf(taxRecipient) - taxBefore, 0);

        // Claim tax and verify
        if (expectedTax > 0) {
            pool.claimTax();
            assertEq(quote.balanceOf(taxRecipient) - taxBefore, expectedTax);
            assertEq(pool.pendingTaxQuote(), 0);
        } else {
            vm.expectRevert(bytes("NO_TAX_TO_CLAIM"));
            pool.claimTax();
        }
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
        
        // Fee and tax should be accumulated, so no direct transfer yet.
        assertEq(maintainerPaid, 0);
        assertEq(taxPaid, 0);

        uint256 expectedMaintainerFee = pool.pendingMaintainerFeeQuote();
        uint256 expectedTax = pool.pendingTaxQuote();

        // The tracked quote balance should decrease by the sum of what was paid out to trader + fee + tax.
        assertEq(quoteBefore - pool.quoteBalance(), traderReceived + expectedMaintainerFee + expectedTax);

        // Claim and verify
        if (expectedMaintainerFee > 0) {
            pool.claimMaintainerFees();
            assertEq(quote.balanceOf(maintainer) - maintainerBefore, expectedMaintainerFee);
            assertEq(pool.pendingMaintainerFeeQuote(), 0);
        } else {
            vm.expectRevert(bytes("NO_FEES_TO_CLAIM"));
            pool.claimMaintainerFees();
        }

        if (expectedTax > 0) {
            pool.claimTax();
            assertEq(quote.balanceOf(taxRecipient) - taxBefore, expectedTax);
            assertEq(pool.pendingTaxQuote(), 0);
        } else {
            vm.expectRevert(bytes("NO_TAX_TO_CLAIM"));
            pool.claimTax();
        }
    }

    // Config and PMM status transitions.
    function testFuzzValidParameterUpdatesAreAccepted(uint96 rawLpFee, uint96 rawMaintFee) public {
        uint256 newLpFee = bound(uint256(rawLpFee), 0, 1e17);
        uint256 newMaintFee = bound(uint256(rawMaintFee), 0, 1e17);

        pool.setMaintainer(maintainer);
        pool.setLpFeeRate(newLpFee);
        pool.setMaintainerFeeRate(newMaintFee);

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
