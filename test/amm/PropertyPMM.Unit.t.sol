// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {RStatus} from "../../src/amm/types/PMMTypes.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {DividendDistribution} from "../../src/dividend/DividendDistribution.sol";
import {KYCRegistry} from "../../src/core/KYCRegistry.sol";
import {PropertyToken} from "../../src/core/PropertyToken.sol";
import {AMMTestBase, MockERC20, MockDividendDistributor} from "./helpers/AMMTestBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract PropertyPMMDeploymentConfigTest is AMMTestBase {
    function testConstructorRejectsInvalidPoolConfiguration() public {
        MockDividendDistributor identicalDividend = new MockDividendDistributor(address(base), address(base));
        vm.expectRevert(bytes("IDENTICAL_TOKENS"));
        _newPoolWithTokensAndDistributor(address(base), address(base), maintainer, address(identicalDividend));

        MockDividendDistributor zeroMaintainerDividend = new MockDividendDistributor(address(base), address(quote));
        vm.expectRevert(bytes("MAINTAINER_NOT_SET"));
        _newPoolWithTokensAndDistributor(address(base), address(quote), address(0), address(zeroMaintainerDividend));
    }

    function testConstructorSupportsNon18DecimalTokensAndRejectsOver18Decimals() public {
        MockERC20 sixBase = new MockERC20("Six Base", "SIXB", 6);
        MockERC20 sixDecimals = new MockERC20("Six", "SIX", 6);
        _setTokenKycRegistry(address(sixBase));
        PropertyPMM sixDecimalPool = _newPoolWithTokens(address(sixBase), address(sixDecimals), maintainer);

        assertEq(sixDecimalPool.baseTokenDecimals(), 6);
        assertEq(sixDecimalPool.quoteTokenDecimals(), 6);
        assertEq(sixDecimalPool.baseTokenScale(), 1e12);
        assertEq(sixDecimalPool.quoteTokenScale(), 1e12);

        MockERC20 nineteenDecimals = new MockERC20("Nineteen", "NINE", 19);
        _setTokenKycRegistry(address(nineteenDecimals));

        MockDividendDistributor badBaseDividend = new MockDividendDistributor(address(nineteenDecimals), address(quote));
        vm.expectRevert(bytes("BASE_DECIMALS_GT_18"));
        _newPoolWithTokensAndDistributor(
            address(nineteenDecimals), address(quote), maintainer, address(badBaseDividend)
        );

        MockDividendDistributor badQuoteDividend = new MockDividendDistributor(address(base), address(nineteenDecimals));
        vm.expectRevert(bytes("QUOTE_DECIMALS_GT_18"));
        _newPoolWithTokensAndDistributor(
            address(base), address(nineteenDecimals), maintainer, address(badQuoteDividend)
        );
    }

    function testConstructorInfersKycRegistryFromBaseToken() public {
        assertEq(address(pool.kycRegistry()), address(kyc));

        MockERC20 unconfiguredBase = new MockERC20("No KYC", "NKYC", 18);
        vm.expectRevert(PropertyPMM.InvalidKYCRegistry.selector);
        new PropertyPMM(
            address(this),
            supervisor,
            maintainer,
            address(unconfiguredBase),
            address(quote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            address(dividendDistributor)
        );
    }

    function testConstructorStoresAndValidatesFixedDividendDistributor() public {
        assertEq(address(pool.dividendDistributor()), address(dividendDistributor));

        vm.expectRevert(bytes("INVALID_DIVIDEND_DISTRIBUTOR"));
        new PropertyPMM(
            address(this),
            supervisor,
            maintainer,
            address(base),
            address(quote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            address(0)
        );

        MockDividendDistributor wrongBase = new MockDividendDistributor(address(stray), address(quote));
        vm.expectRevert(bytes("DIVIDEND_TOKEN_NOT_BASE"));
        new PropertyPMM(
            address(this),
            supervisor,
            maintainer,
            address(base),
            address(quote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            address(wrongBase)
        );

        MockDividendDistributor wrongQuote = new MockDividendDistributor(address(base), address(stray));
        vm.expectRevert(bytes("DIVIDEND_TOKEN_NOT_QUOTE"));
        new PropertyPMM(
            address(this),
            supervisor,
            maintainer,
            address(base),
            address(quote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            address(wrongQuote)
        );
    }

    function testLpTransfersRequireKycOrApprovedContract() public {
        uint256 transferAmount = pool.balanceOf(lpProvider) / 4;

        vm.prank(lpProvider);
        vm.expectRevert(abi.encodeWithSelector(PropertyPMM.RecipientNotAuthorized.selector, outsider));
        pool.transfer(outsider, transferAmount);

        kyc.setApprovedContract(address(stray), true);
        vm.prank(lpProvider);
        assertTrue(pool.transfer(address(stray), transferAmount));

        vm.prank(lpProvider);
        assertTrue(pool.transfer(lpReceiver, transferAmount));

        kyc.setVerified(lpReceiver, false);
        vm.prank(lpReceiver);
        vm.expectRevert(abi.encodeWithSelector(PropertyPMM.SenderNotAuthorized.selector, lpReceiver));
        pool.transfer(lpProvider, transferAmount);
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
        vm.expectRevert(bytes("NOT_SUPERVISOR_OR_OWNER"));
        pool.disableTrading();

        vm.expectRevert(bytes("BUY_TAX_RATE>=1"));
        pool.setBuyTaxRate(ONE);

        vm.expectRevert(bytes("FEE_RATE>=1"));
        pool.setSellTaxRate(997e15);

        pool.setMaintainerFeeRate(0);
        pool.setMaintainer(address(0));

        vm.expectRevert(bytes("MAINTAINER_NOT_SET"));
        pool.setMaintainerFeeRate(1);

        vm.expectRevert(bytes("INVALID_VALUATION_DELTA_BPS"));
        pool.setValuationValidation(1 hours, 10_001);

        vm.expectRevert(bytes("INVALID_VALUATION_STALENESS"));
        pool.setValuationValidation(0, 2_000);
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

contract PropertyPMMValuationTest is AMMTestBase {
    function testValuationRejectsZeroStaleAndFuturePrices() public {
        vm.expectRevert(bytes("INVALID_VALUATION_PRICE"));
        pool.setValuationPrice(0);

        pool.setValuationPrice(INITIAL_PRICE);
        vm.warp(block.timestamp + pool.valuationMaxStaleness() + 1);
        vm.expectRevert(bytes("STALE_VALUATION_PRICE"));
        pool.queryBuyBaseToken(ONE);

        vm.expectRevert(bytes("VALUATION_TIMESTAMP_IN_FUTURE"));
        pool.setValuationPriceWithTimestamp(INITIAL_PRICE, block.timestamp + 1);
    }

    function testValuationCircuitBreakerPausesTradingUntilPendingAccepted() public {
        pool.setValuationValidation(1 hours, 1_000);

        pool.setValuationPrice(INITIAL_PRICE);
        pool.setValuationPrice(112 * ONE);

        assertTrue(pool.valuationCircuitBreakerTripped());
        assertEq(pool.pendingValuationPrice(), 112 * ONE);
        assertEq(pool.pendingValuationUpdatedAt(), block.timestamp);
        assertEq(pool.getValuationPrice(), INITIAL_PRICE);
        assertFalse(pool.tradingEnabled());

        vm.expectRevert(bytes("VALUATION_CIRCUIT_BREAKER_ACTIVE"));
        pool.setValuationPrice(105 * ONE);

        vm.expectRevert(bytes("VALUATION_CIRCUIT_BREAKER_ACTIVE"));
        pool.enableTrading();

        pool.acceptPendingValuation();
        assertFalse(pool.valuationCircuitBreakerTripped());
        assertEq(pool.pendingValuationPrice(), 0);
        assertEq(pool.pendingValuationUpdatedAt(), 0);
        assertEq(pool.getValuationPrice(), 112 * ONE);

        pool.enableTrading();
        assertTrue(pool.tradingEnabled());
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

    function testAgedValuationDoesNotChangeFixedSizeQuotesWithinFreshnessWindow() public {
        pool.setValuationPrice(INITIAL_PRICE);

        uint256 freshBuyQuote = pool.queryBuyBaseToken(ONE);
        uint256 freshSellQuote = pool.querySellBaseToken(ONE);

        vm.warp(block.timestamp + 100);

        assertEq(pool.queryBuyBaseToken(ONE), freshBuyQuote);
        assertEq(pool.querySellBaseToken(ONE), freshSellQuote);
    }
}

contract PropertyPMMLiquidityTest is AMMTestBase {
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
        _setTokenKycRegistry(address(hugeBase));
        PropertyPMM hugePool = _newPoolWithTokens(address(hugeBase), address(hugeQuote), maintainer);

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
        _setTokenKycRegistry(address(sixBase));
        PropertyPMM sixPool = _newPoolWithTokens(address(sixBase), address(sixQuote), maintainer);

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

contract PropertyPMMTradingTaxTest is AMMTestBase {
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
        
        // Assert accumulation
        assertEq(pool.pendingTaxQuote(), expectedTax);
        assertEq(quote.balanceOf(taxRecipient) - taxQuoteBefore, 0);

        // Claim and assert final transfer
        pool.claimTax();
        assertEq(quote.balanceOf(taxRecipient) - taxQuoteBefore, expectedTax);
        assertEq(pool.pendingTaxQuote(), 0);
    }

    function testBuyPaysMaintainerInBaseAndMovesPoolAboveOne() public {
        uint256 buyAmount = ONE;
        uint256 maintainerBaseBefore = base.balanceOf(maintainer);
        uint256 poolBaseBefore = pool.baseBalance();
        uint256 totalPaid = pool.queryBuyBaseToken(buyAmount);

        vm.prank(trader);
        pool.buyBaseToken(buyAmount, totalPaid);

        // Check accumulation
        uint256 maintainerBasePending = pool.pendingMaintainerFeeBase();
        assertGt(maintainerBasePending, 0);
        assertEq(base.balanceOf(maintainer) - maintainerBaseBefore, 0);

        // Tracked pool base balance + pending maintainer fee + buyAmount must equal poolBaseBefore.
        assertEq(pool.baseBalance() + buyAmount + maintainerBasePending, poolBaseBefore);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));

        // Claim and verify
        pool.claimMaintainerFees();
        assertEq(base.balanceOf(maintainer) - maintainerBaseBefore, maintainerBasePending);
        assertEq(pool.pendingMaintainerFeeBase(), 0);
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
        assertEq(taxPaid, 0);
        assertEq(maintainerPaid, 0);

        uint256 expectedMaintainer = pool.pendingMaintainerFeeQuote();
        uint256 expectedTax = pool.pendingTaxQuote();
        assertGt(expectedTax, 0);

        // Check that pool quote balance is correctly adjusted internally
        assertEq(poolQuoteBefore - pool.quoteBalance(), traderReceived + expectedMaintainer + expectedTax);

        // Claim and verify
        pool.claimMaintainerFees();
        pool.claimTax();

        assertEq(quote.balanceOf(maintainer) - maintainerQuoteBefore, expectedMaintainer);
        assertEq(quote.balanceOf(taxRecipient) - taxQuoteBefore, expectedTax);
        assertEq(pool.pendingMaintainerFeeQuote(), 0);
        assertEq(pool.pendingTaxQuote(), 0);
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

        assertEq(maintainerPaid, 0);
        uint256 expectedMaintainer = pool.pendingMaintainerFeeQuote();
        assertGt(expectedMaintainer, 0);

        assertEq(poolQuoteBefore - pool.quoteBalance(), traderReceived + expectedMaintainer);
        assertEq(quote.balanceOf(trader) - traderQuoteBefore, traderReceived);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.BELOW_ONE));

        // Claim and verify
        pool.claimMaintainerFees();
        assertEq(quote.balanceOf(maintainer) - maintainerQuoteBefore, expectedMaintainer);
        assertEq(pool.pendingMaintainerFeeQuote(), 0);
    }
}

contract PropertyPMMControlsTest is AMMTestBase {
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

contract PropertyPMMDividendTest is AMMTestBase {
    function testClaimQuoteDividendsAccountsClaimedQuoteToLPs() public {
        quote.mint(address(dividendDistributor), 25 * ONE);
        dividendDistributor.setClaimAmount(25 * ONE);

        uint256 actualQuoteBefore = quote.balanceOf(address(pool));
        uint256 quoteBalanceBefore = pool.quoteBalance();
        uint256 targetQuoteBefore = pool.targetQuoteTokenAmount();
        uint256 midPriceBefore = pool.getMidPrice();
        uint256 sellQuoteBefore = pool.querySellBaseToken(ONE);
        uint256 lpQuoteBefore = quote.balanceOf(lpProvider);

        vm.prank(supervisor);
        uint256 claimed = pool.claimQuoteDividends(type(uint256).max);

        assertEq(claimed, 25 * ONE);
        assertEq(quote.balanceOf(address(pool)) - actualQuoteBefore, 25 * ONE);
        assertEq(pool.quoteBalance(), quoteBalanceBefore);
        assertEq(pool.targetQuoteTokenAmount(), targetQuoteBefore);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ONE));
        assertEq(pool.getMidPrice(), midPriceBefore);
        assertEq(pool.querySellBaseToken(ONE), sellQuoteBefore);
        assertEq(pool.pendingLpQuoteDividends(lpProvider), 25 * ONE);
        assertEq(pool.totalPendingLpQuoteDividends(), 25 * ONE);

        vm.prank(lpProvider);
        uint256 lpClaimed = pool.claimLpQuoteDividends();

        assertEq(lpClaimed, 25 * ONE);
        assertEq(quote.balanceOf(lpProvider) - lpQuoteBefore, 25 * ONE);
        assertEq(pool.pendingLpQuoteDividends(lpProvider), 0);
        assertEq(pool.totalPendingLpQuoteDividends(), 0);
        _assertTrackedBalancesAtMostActual();
    }

    function testClaimQuoteDividendsRestrictedToDistributorOrOwner() public {
        quote.mint(address(dividendDistributor), 10 * ONE);
        dividendDistributor.setClaimAmount(10 * ONE);

        // A random account cannot trigger accounting (anti-JIT gate).
        vm.prank(outsider);
        vm.expectRevert(bytes("CLAIM_NOT_AUTHORIZED"));
        pool.claimQuoteDividends(type(uint256).max);

        // Supervisor (authorized non-owner) can.
        vm.prank(supervisor);
        uint256 claimed = pool.claimQuoteDividends(type(uint256).max);
        assertEq(claimed, 10 * ONE);
        assertEq(pool.pendingLpQuoteDividends(lpProvider), 10 * ONE);
    }

    function testClaimQuoteDividendsWhileAlreadyUnbalancedPreservesStatusAndTargets() public {
        uint256 buyQuote = pool.queryBuyBaseToken(ONE);

        vm.prank(trader);
        pool.buyBaseToken(ONE, buyQuote);

        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));
        uint256 targetBaseBefore = pool.targetBaseTokenAmount();
        uint256 targetQuoteBefore = pool.targetQuoteTokenAmount();
        uint256 quoteBalanceBefore = pool.quoteBalance();
        uint256 midPriceBefore = pool.getMidPrice();

        quote.mint(address(dividendDistributor), 5 * ONE);
        dividendDistributor.setClaimAmount(5 * ONE);

        pool.claimQuoteDividends(type(uint256).max);

        assertEq(uint256(pool.rStatus()), uint256(RStatus.ABOVE_ONE));
        assertEq(pool.targetBaseTokenAmount(), targetBaseBefore);
        assertEq(pool.targetQuoteTokenAmount(), targetQuoteBefore);
        assertEq(pool.quoteBalance(), quoteBalanceBefore);
        assertEq(pool.getMidPrice(), midPriceBefore);
        assertEq(pool.pendingLpQuoteDividends(lpProvider), 5 * ONE);
        _assertTrackedBalancesAtMostActual();
    }

    function testLpDividendAccountingFollowsSharesAndTransfers() public {
        _mintAndApprove(secondProvider, 5 * ONE, 500 * ONE);

        vm.prank(secondProvider);
        pool.provideLiquidity(5 * ONE, 500 * ONE, 0);

        quote.mint(address(dividendDistributor), 45 * ONE);
        dividendDistributor.setClaimAmount(30 * ONE);

        pool.claimQuoteDividends(type(uint256).max);

        assertEq(pool.pendingLpQuoteDividends(lpProvider), 20 * ONE);
        assertEq(pool.pendingLpQuoteDividends(secondProvider), 10 * ONE);

        uint256 transferredShares = pool.balanceOf(secondProvider);
        vm.prank(secondProvider);
        pool.transfer(lpReceiver, transferredShares);

        assertEq(pool.pendingLpQuoteDividends(secondProvider), 10 * ONE);
        assertEq(pool.pendingLpQuoteDividends(lpReceiver), 0);

        dividendDistributor.setClaimAmount(15 * ONE);
        pool.claimQuoteDividends(type(uint256).max);

        assertEq(pool.pendingLpQuoteDividends(lpProvider), 30 * ONE);
        assertEq(pool.pendingLpQuoteDividends(secondProvider), 10 * ONE);
        assertEq(pool.pendingLpQuoteDividends(lpReceiver), 5 * ONE);
        assertEq(pool.totalPendingLpQuoteDividends(), 45 * ONE);
    }

    function testWithdrawLiquidityDoesNotErasePendingLpDividends() public {
        quote.mint(address(dividendDistributor), 25 * ONE);
        dividendDistributor.setClaimAmount(25 * ONE);

        pool.claimQuoteDividends(type(uint256).max);

        uint256 shares = pool.balanceOf(lpProvider);
        vm.prank(lpProvider);
        pool.withdrawLiquidity(shares, 0, 0);

        assertEq(pool.balanceOf(lpProvider), 0);
        assertEq(pool.pendingLpQuoteDividends(lpProvider), 25 * ONE);

        uint256 lpQuoteBefore = quote.balanceOf(lpProvider);
        vm.prank(lpProvider);
        uint256 claimed = pool.claimLpQuoteDividends();

        assertEq(claimed, 25 * ONE);
        assertEq(quote.balanceOf(lpProvider) - lpQuoteBefore, 25 * ONE);
        assertEq(pool.pendingLpQuoteDividends(lpProvider), 0);
    }

    function testPendingQuoteDividendsReadsPoolPendingAmount() public {
        dividendDistributor.setPendingAmount(11 * ONE);

        assertEq(pool.pendingQuoteDividends(3), 11 * ONE);
    }

    function testClaimQuoteDividendsUsesFixedDistributorAndRejectsOldRedirectSelector() public {
        // Called as owner (address(this)); the point here is the fixed distributor
        // and rejection of the old redirect selector, not the caller gate.
        vm.expectRevert(bytes("NO_DIVIDEND_CLAIMED"));
        pool.claimQuoteDividends(type(uint256).max);

        MockDividendDistributor otherDividend = new MockDividendDistributor(address(base), address(quote));
        quote.mint(address(otherDividend), 25 * ONE);
        otherDividend.setClaimAmount(25 * ONE);

        uint256 poolQuoteBefore = quote.balanceOf(address(pool));
        (bool ok,) = address(pool)
            .call(
                abi.encodeWithSignature(
                    "claimQuoteDividends(address,uint256)", address(otherDividend), type(uint256).max
                )
            );
        assertFalse(ok);
        assertEq(quote.balanceOf(address(pool)), poolQuoteBefore);
        assertEq(quote.balanceOf(address(otherDividend)), 25 * ONE);
    }

    function testClaimQuoteDividendsRejectsZeroClaim() public {
        vm.expectRevert(bytes("NO_DIVIDEND_CLAIMED"));
        pool.claimQuoteDividends(type(uint256).max);
    }

    function testClaimLpQuoteDividendsChecksPendingAndRecoverProtection() public {
        quote.mint(address(dividendDistributor), 25 * ONE);
        dividendDistributor.setClaimAmount(25 * ONE);

        vm.prank(lpProvider);
        vm.expectRevert(bytes("NO_LP_DIVIDEND"));
        pool.claimLpQuoteDividends();

        pool.claimQuoteDividends(type(uint256).max);

        vm.expectRevert(bytes("QUOTE_BALANCE_NOT_ENOUGH"));
        pool.recoverToken(address(quote), address(this), 1);

        quote.mint(address(pool), ONE);
        uint256 ownerQuoteBefore = quote.balanceOf(address(this));
        pool.recoverToken(address(quote), address(this), ONE);
        assertEq(quote.balanceOf(address(this)) - ownerQuoteBefore, ONE);
        assertEq(pool.pendingLpQuoteDividends(lpProvider), 25 * ONE);
    }

    function testClaimLpQuoteDividendsRequiresAuthorizedLp() public {
        kyc.setVerified(outsider, true);
        kyc.setApprovedContract(address(stray), true);
        uint256 transferAmount = pool.balanceOf(lpProvider) / 4;

        vm.prank(lpProvider);
        pool.transfer(outsider, transferAmount);

        vm.prank(lpProvider);
        pool.transfer(address(stray), transferAmount);

        kyc.setVerified(outsider, false);

        quote.mint(address(dividendDistributor), 40 * ONE);
        dividendDistributor.setClaimAmount(40 * ONE);

        pool.claimQuoteDividends(type(uint256).max);
        assertEq(pool.pendingLpQuoteDividends(outsider), 10 * ONE);
        assertEq(pool.pendingLpQuoteDividends(address(stray)), 10 * ONE);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PropertyPMM.SenderNotAuthorized.selector, outsider));
        pool.claimLpQuoteDividends();

        uint256 quoteBefore = quote.balanceOf(address(stray));
        vm.prank(address(stray));
        assertEq(pool.claimLpQuoteDividends(), 10 * ONE);
        assertEq(quote.balanceOf(address(stray)) - quoteBefore, 10 * ONE);
    }

    function testClaimQuoteDividendsWorksWithRealDividendDistributionForApprovedPool() public {
        KYCRegistry realKycImpl = new KYCRegistry();
        ERC1967Proxy realKycProxy = new ERC1967Proxy(address(realKycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        KYCRegistry realKyc = KYCRegistry(address(realKycProxy));
        address publicCaller = address(0xBEEF);
        realKyc.addUser(address(this));
        realKyc.addUser(publicCaller);

        PropertyToken realBaseImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(realBaseImpl), address(this));
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize, ("Real Base", "RBASE", 1000 * ONE, 1, address(realKyc), address(this))
            )
        );
        PropertyToken realBase = PropertyToken(address(tokenProxy));
        MockERC20 realQuote = new MockERC20("Real Quote", "RQUOTE", 18);
        DividendDistribution realDividend =
            new DividendDistribution(address(realBase), address(realQuote), address(realKyc), address(this));
        PropertyPMM realPool = new PropertyPMM(
            address(this),
            supervisor,
            maintainer,
            address(realBase),
            address(realQuote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            address(realDividend)
        );

        realKyc.addApprovedContract(address(realPool));
        realQuote.mint(address(this), 200 * ONE);
        realBase.approve(address(realPool), type(uint256).max);
        realQuote.approve(address(realPool), type(uint256).max);
        realPool.provideLiquidity(100 * ONE, 100 * ONE, 0);
        vm.roll(block.number + 1);

        realQuote.approve(address(realDividend), 100 * ONE);
        realDividend.depositDividends(100 * ONE);

        assertEq(realPool.pendingQuoteDividends(type(uint256).max), 10 * ONE);

        // A public (non-owner/supervisor) caller can no longer trigger accounting.
        vm.prank(publicCaller);
        vm.expectRevert(bytes("CLAIM_NOT_AUTHORIZED"));
        realPool.claimQuoteDividends(type(uint256).max);

        // Owner (address(this)) triggers it instead.
        uint256 claimed = realPool.claimQuoteDividends(type(uint256).max);

        assertEq(claimed, 10 * ONE);
        assertEq(realPool.pendingLpQuoteDividends(address(this)), 10 * ONE);
        assertEq(realPool.totalPendingLpQuoteDividends(), 10 * ONE);
    }
}
