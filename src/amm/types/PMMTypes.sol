// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice PMM reserve state.
/// - ONE: pool is balanced at the guide price.
/// - ABOVE_ONE: base inventory is depleted after net buys, so marginal price is above the guide price (Premium).
/// - BELOW_ONE: quote inventory is depleted after net sells, so marginal price is below the guide price (Discount).
enum RStatus {
    ONE,
    ABOVE_ONE,
    BELOW_ONE
}

/// @notice Oracle price and effective K used for PMM quotes.
struct PricingState {
    uint256 price;
    uint256 effectiveK;
}

/// @notice PMM target reserves for base and quote tokens.
struct TargetState {
    uint256 baseTarget;
    uint256 quoteTarget;
}

/// @notice Snapshot of pool reserves, targets, fees, and tax settings.
struct PoolState {
    RStatus rStatus;
    uint256 baseBalance;
    uint256 quoteBalance;
    uint256 targetBaseTokenAmount;
    uint256 targetQuoteTokenAmount;
    uint256 lpFeeRate;
    uint256 maintainerFeeRate;
    uint256 buyTaxRate;
    uint256 sellTaxRate;
    bool taxEnabled;
    address taxRecipient;
}

/// @notice Result of a base-token sell quote.
struct SellQuote {
    uint256 receiveQuote;
    uint256 lpFeeQuote;
    uint256 maintainerFeeQuote;
    uint256 sellTaxQuote;
    RStatus newRStatus;
    uint256 newQuoteTarget;
    uint256 newBaseTarget;
}

/// @notice Result of a base-token buy quote.
struct BuyQuote {
    uint256 payQuote;
    uint256 lpFeeBase;
    uint256 maintainerFeeBase;
    uint256 buyTaxQuote;
    RStatus newRStatus;
    uint256 newQuoteTarget;
    uint256 newBaseTarget;
}
