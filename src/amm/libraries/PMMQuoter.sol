// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {PMMMath} from "./PMMMath.sol";
import {BuyQuote, PoolState, PricingState, RStatus, SellQuote, TargetState} from "../types/PMMTypes.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Pure quote engine for the PMM pool.
library PMMQuoter {
    uint256 private constant WAD = 1e18;

    /// @notice Return the target reserves implied by the current PMM state.
    function expectedTarget(PoolState memory pool, PricingState memory pricing)
        internal
        pure
        returns (TargetState memory target)
    {
        if (pool.rStatus == RStatus.ONE) {
            target.baseTarget = pool.targetBaseTokenAmount;
            target.quoteTarget = pool.targetQuoteTokenAmount;
            return target;
        }
        if (pool.rStatus == RStatus.BELOW_ONE) {
            target.baseTarget = pool.targetBaseTokenAmount;
            target.quoteTarget = pool.quoteBalance + _rBelowBackToOne(pool, pricing);
            return target;
        }
        target.baseTarget = pool.baseBalance + _rAboveBackToOne(pool, pricing);
        target.quoteTarget = pool.targetQuoteTokenAmount;
    }

    /// @notice Return the PMM marginal price for the current state.
    function midPrice(PoolState memory pool, PricingState memory pricing) internal pure returns (uint256) {
        TargetState memory target = expectedTarget(pool, pricing);
        if (pool.rStatus == RStatus.BELOW_ONE) {
            uint256 belowRatio = FixedPointMathLib.divWad(
                (target.quoteTarget * target.quoteTarget) / pool.quoteBalance, pool.quoteBalance
            );
            belowRatio = WAD - pricing.effectiveK + FixedPointMathLib.mulWad(pricing.effectiveK, belowRatio);
            return FixedPointMathLib.divWad(pricing.price, belowRatio);
        }

        uint256 aboveRatio =
            FixedPointMathLib.divWad((target.baseTarget * target.baseTarget) / pool.baseBalance, pool.baseBalance);
        aboveRatio = WAD - pricing.effectiveK + FixedPointMathLib.mulWad(pricing.effectiveK, aboveRatio);
        return FixedPointMathLib.mulWad(pricing.price, aboveRatio);
    }

    /// @notice Quote a base-token sell and its resulting PMM state.
    function querySellBaseToken(PoolState memory pool, PricingState memory pricing, uint256 amount)
        internal
        pure
        returns (SellQuote memory quote)
    {
        TargetState memory target = expectedTarget(pool, pricing);
        quote.newBaseTarget = target.baseTarget;
        quote.newQuoteTarget = target.quoteTarget;

        if (pool.rStatus == RStatus.ONE) {
            quote.receiveQuote = _rOneSellBaseToken(amount, quote.newQuoteTarget, pricing);
            quote.newRStatus = RStatus.BELOW_ONE;
        } else if (pool.rStatus == RStatus.ABOVE_ONE) {
            _quoteAboveOneSell(pool, pricing, amount, quote);
        } else {
            quote.receiveQuote = _rBelowSellBaseToken(amount, pool.quoteBalance, quote.newQuoteTarget, pricing);
            quote.newRStatus = RStatus.BELOW_ONE;
        }

        quote.lpFeeQuote = FixedPointMathLib.mulWad(quote.receiveQuote, pool.lpFeeRate);
        quote.maintainerFeeQuote = FixedPointMathLib.mulWad(quote.receiveQuote, pool.maintainerFeeRate);
        quote.sellTaxQuote = _taxQuote(pool, quote.receiveQuote, pool.sellTaxRate);
        quote.receiveQuote = quote.receiveQuote - quote.lpFeeQuote - quote.maintainerFeeQuote - quote.sellTaxQuote;
    }

    /// @notice Quote a base-token buy and its resulting PMM state.
    function queryBuyBaseToken(PoolState memory pool, PricingState memory pricing, uint256 amount)
        internal
        pure
        returns (BuyQuote memory quote)
    {
        TargetState memory target = expectedTarget(pool, pricing);
        quote.newBaseTarget = target.baseTarget;
        quote.newQuoteTarget = target.quoteTarget;

        quote.lpFeeBase = FixedPointMathLib.mulWad(amount, pool.lpFeeRate);
        quote.maintainerFeeBase = FixedPointMathLib.mulWad(amount, pool.maintainerFeeRate);
        uint256 buyBaseAmount = amount + quote.lpFeeBase + quote.maintainerFeeBase;

        if (pool.rStatus == RStatus.ONE) {
            quote.payQuote = _rOneBuyBaseToken(buyBaseAmount, quote.newBaseTarget, pricing);
            quote.newRStatus = RStatus.ABOVE_ONE;
        } else if (pool.rStatus == RStatus.ABOVE_ONE) {
            quote.payQuote = _rAboveBuyBaseToken(buyBaseAmount, pool.baseBalance, quote.newBaseTarget, pricing);
            quote.newRStatus = RStatus.ABOVE_ONE;
        } else {
            _quoteBelowOneBuy(pool, pricing, buyBaseAmount, quote);
        }

        quote.buyTaxQuote = _taxQuote(pool, quote.payQuote, pool.buyTaxRate);
    }

    function _quoteAboveOneSell(
        PoolState memory pool,
        PricingState memory pricing,
        uint256 amount,
        SellQuote memory quote
    ) private pure {
        uint256 backToOnePayBase = quote.newBaseTarget - pool.baseBalance;
        uint256 backToOneReceiveQuote = pool.quoteBalance - quote.newQuoteTarget;

        if (amount < backToOnePayBase) {
            quote.receiveQuote = _rAboveSellBaseToken(amount, pool.baseBalance, quote.newBaseTarget, pricing);
            quote.newRStatus = RStatus.ABOVE_ONE;
            if (quote.receiveQuote > backToOneReceiveQuote) {
                quote.receiveQuote = backToOneReceiveQuote;
            }
        } else if (amount == backToOnePayBase) {
            quote.receiveQuote = backToOneReceiveQuote;
            quote.newRStatus = RStatus.ONE;
        } else {
            quote.receiveQuote =
                backToOneReceiveQuote + _rOneSellBaseToken(amount - backToOnePayBase, quote.newQuoteTarget, pricing);
            quote.newRStatus = RStatus.BELOW_ONE;
        }
    }

    function _quoteBelowOneBuy(
        PoolState memory pool,
        PricingState memory pricing,
        uint256 buyBaseAmount,
        BuyQuote memory quote
    ) private pure {
        uint256 backToOnePayQuote = quote.newQuoteTarget - pool.quoteBalance;
        uint256 backToOneReceiveBase = pool.baseBalance - quote.newBaseTarget;

        if (buyBaseAmount < backToOneReceiveBase) {
            quote.payQuote = _rBelowBuyBaseToken(buyBaseAmount, pool.quoteBalance, quote.newQuoteTarget, pricing);
            quote.newRStatus = RStatus.BELOW_ONE;
        } else if (buyBaseAmount == backToOneReceiveBase) {
            quote.payQuote = backToOnePayQuote;
            quote.newRStatus = RStatus.ONE;
        } else {
            quote.payQuote = backToOnePayQuote
                + _rOneBuyBaseToken(buyBaseAmount - backToOneReceiveBase, quote.newBaseTarget, pricing);
            quote.newRStatus = RStatus.ABOVE_ONE;
        }
    }

    function _rOneSellBaseToken(uint256 amount, uint256 targetQuoteAmount, PricingState memory pricing)
        private
        pure
        returns (uint256)
    {
        uint256 q2 = PMMMath.solveQuadraticFunctionForTrade(
            targetQuoteAmount,
            targetQuoteAmount,
            FixedPointMathLib.mulWad(pricing.price, amount),
            false,
            pricing.effectiveK
        );
        return targetQuoteAmount - q2;
    }

    function _rOneBuyBaseToken(uint256 amount, uint256 targetBaseAmount, PricingState memory pricing)
        private
        pure
        returns (uint256)
    {
        require(amount < targetBaseAmount, "DODO_BASE_BALANCE_NOT_ENOUGH");
        return _rAboveIntegrate(targetBaseAmount, targetBaseAmount, targetBaseAmount - amount, pricing);
    }

    function _rBelowSellBaseToken(
        uint256 amount,
        uint256 currentQuoteBalance,
        uint256 targetQuoteAmount,
        PricingState memory pricing
    ) private pure returns (uint256) {
        uint256 q2 = PMMMath.solveQuadraticFunctionForTrade(
            targetQuoteAmount,
            currentQuoteBalance,
            FixedPointMathLib.mulWad(pricing.price, amount),
            false,
            pricing.effectiveK
        );
        return currentQuoteBalance - q2;
    }

    function _rBelowBuyBaseToken(
        uint256 amount,
        uint256 currentQuoteBalance,
        uint256 targetQuoteAmount,
        PricingState memory pricing
    ) private pure returns (uint256) {
        uint256 q2 = PMMMath.solveQuadraticFunctionForTrade(
            targetQuoteAmount,
            currentQuoteBalance,
            FixedPointMathLib.mulWadUp(pricing.price, amount),
            true,
            pricing.effectiveK
        );
        return q2 - currentQuoteBalance;
    }

    function _rAboveBuyBaseToken(
        uint256 amount,
        uint256 currentBaseBalance,
        uint256 targetBaseAmount,
        PricingState memory pricing
    ) private pure returns (uint256) {
        require(amount < currentBaseBalance, "DODO_BASE_BALANCE_NOT_ENOUGH");
        return _rAboveIntegrate(targetBaseAmount, currentBaseBalance, currentBaseBalance - amount, pricing);
    }

    function _rAboveSellBaseToken(
        uint256 amount,
        uint256 currentBaseBalance,
        uint256 targetBaseAmount,
        PricingState memory pricing
    ) private pure returns (uint256) {
        return _rAboveIntegrate(targetBaseAmount, currentBaseBalance + amount, currentBaseBalance, pricing);
    }

    function _rBelowBackToOne(PoolState memory pool, PricingState memory pricing) private pure returns (uint256) {
        uint256 spareBase = pool.baseBalance - pool.targetBaseTokenAmount;
        uint256 fairAmount = FixedPointMathLib.mulWad(spareBase, pricing.price);
        uint256 newTargetQuote =
            PMMMath.solveQuadraticFunctionForTarget(pool.quoteBalance, pricing.effectiveK, fairAmount);
        return newTargetQuote - pool.quoteBalance;
    }

    function _rAboveBackToOne(PoolState memory pool, PricingState memory pricing) private pure returns (uint256) {
        uint256 spareQuote = pool.quoteBalance - pool.targetQuoteTokenAmount;
        uint256 fairAmount = FixedPointMathLib.divWad(spareQuote, pricing.price);
        uint256 newTargetBase =
            PMMMath.solveQuadraticFunctionForTarget(pool.baseBalance, pricing.effectiveK, fairAmount);
        return newTargetBase - pool.baseBalance;
    }

    function _rAboveIntegrate(uint256 b0, uint256 b1, uint256 b2, PricingState memory pricing)
        private
        pure
        returns (uint256)
    {
        return PMMMath.generalIntegrate(b0, b1, b2, pricing.price, pricing.effectiveK);
    }

    function _taxQuote(PoolState memory pool, uint256 quoteAmount, uint256 taxRate) private pure returns (uint256) {
        if (!pool.taxEnabled || taxRate == 0) {
            return 0;
        }
        require(pool.taxRecipient != address(0), "INVALID_TAX_RECIPIENT");
        return FixedPointMathLib.mulWad(quoteAmount, taxRate);
    }
}
