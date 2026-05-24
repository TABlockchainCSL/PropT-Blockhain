// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {PricingState} from "../types/PMMTypes.sol";
import {AMMRoles} from "./AMMRoles.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title AMMConfig
/// @notice Shared fee, tax, K, and valuation controls for PMM pools.
/// @dev Prices, fee rates, and inventory math use 18-decimal fixed point values; valuation deltas use bps.
abstract contract AMMConfig is AMMRoles {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @notice Default maximum age accepted for the valuation price.
    uint256 public constant DEFAULT_VALUATION_MAX_STALENESS = 180 days;
    /// @notice Default max valuation move before trading is paused, in bps.
    uint256 public constant DEFAULT_MAX_VALUATION_DELTA_BPS = 2_000;
    /// @notice Address receiving maintainer fees.
    address public maintainer;
    /// @notice Address receiving buy and sell taxes.
    address public taxRecipient;

    /// @notice Whether buy and sell tax collection is enabled.
    bool public taxEnabled;

    /// @notice LP fee rate charged on swaps, scaled by 1e18.
    uint256 public lpFeeRate;
    /// @notice Maintainer fee rate charged on swaps, scaled by 1e18.
    uint256 public maintainerFeeRate;
    /// @notice Buy-side tax rate, scaled by 1e18.
    uint256 public buyTaxRate;
    /// @notice Sell-side tax rate, scaled by 1e18.
    uint256 public sellTaxRate;
    /// @notice Fixed PMM slippage parameter, scaled by 1e18.
    uint256 public k;
    /// @notice Active guide valuation price, scaled by 1e18.
    uint256 public valuationPrice;
    /// @notice Timestamp for the active valuation price.
    uint256 public valuationUpdatedAt;
    /// @notice Maximum accepted valuation age in seconds.
    uint256 public valuationMaxStaleness;
    /// @notice Max accepted valuation move from the active price, in bps.
    uint256 public maxValuationDeltaBps;
    /// @notice True when a pending valuation requires owner acceptance.
    bool public valuationCircuitBreakerTripped;
    /// @notice Valuation price waiting for manual acceptance.
    uint256 public pendingValuationPrice;
    /// @notice Timestamp for the pending valuation price.
    uint256 public pendingValuationUpdatedAt;

    event ValuationUpdated(uint256 oldPrice, uint256 newPrice, uint256 oldUpdatedAt, uint256 newUpdatedAt);
    event ValuationCircuitBreakerTripped(
        uint256 oldPrice, uint256 pendingPrice, uint256 oldUpdatedAt, uint256 pendingUpdatedAt, uint256 maxDeltaBps
    );
    event PendingValuationAccepted(uint256 oldPrice, uint256 newPrice, uint256 oldUpdatedAt, uint256 newUpdatedAt);
    event MaintainerUpdated(address indexed oldMaintainer, address indexed newMaintainer);
    event ValuationValidationUpdated(
        uint256 oldMaxStaleness, uint256 newMaxStaleness, uint256 oldMaxDeltaBps, uint256 newMaxDeltaBps
    );
    event TaxRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TaxEnabledUpdated(bool oldEnabled, bool newEnabled);
    event BuyTaxRateUpdated(uint256 oldRate, uint256 newRate);
    event SellTaxRateUpdated(uint256 oldRate, uint256 newRate);
    event LpFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event MaintainerFeeRateUpdated(uint256 oldRate, uint256 newRate);

    constructor(
        address owner_,
        address supervisor_,
        address maintainer_,
        uint256 initialValuationPrice_,
        uint256 lpFeeRate_,
        uint256 maintainerFeeRate_,
        uint256 k_
    ) AMMRoles(owner_, supervisor_) {
        require(initialValuationPrice_ > 0, "INVALID_VALUATION_PRICE");
        require(k_ > 0, "K=0");
        require(k_ < WAD, "K>=1");
        require(lpFeeRate_ + maintainerFeeRate_ < WAD, "FEE_RATE>=1");
        require(maintainer_ != address(0) || maintainerFeeRate_ == 0, "MAINTAINER_NOT_SET");

        maintainer = maintainer_;
        valuationPrice = initialValuationPrice_;
        valuationUpdatedAt = block.timestamp;
        lpFeeRate = lpFeeRate_;
        maintainerFeeRate = maintainerFeeRate_;
        k = k_;
        valuationMaxStaleness = DEFAULT_VALUATION_MAX_STALENESS;
        maxValuationDeltaBps = DEFAULT_MAX_VALUATION_DELTA_BPS;
    }

    /// @notice Submit a fresh valuation price using the current block timestamp.
    function setValuationPrice(uint256 newPrice) external onlyOwner {
        _setValuationPrice(newPrice, block.timestamp);
    }

    /// @notice Submit a valuation price with an explicit source timestamp.
    function setValuationPriceWithTimestamp(uint256 newPrice, uint256 newUpdatedAt) external onlyOwner {
        _setValuationPrice(newPrice, newUpdatedAt);
    }

    /// @notice Accept the pending valuation and clear the circuit breaker.
    function acceptPendingValuation() external onlyOwner {
        require(valuationCircuitBreakerTripped, "NO_PENDING_VALUATION");

        uint256 oldPrice = valuationPrice;
        uint256 oldUpdatedAt = valuationUpdatedAt;
        uint256 newPrice = pendingValuationPrice;
        uint256 newUpdatedAt = pendingValuationUpdatedAt;

        valuationCircuitBreakerTripped = false;
        pendingValuationPrice = 0;
        pendingValuationUpdatedAt = 0;
        valuationPrice = newPrice;
        valuationUpdatedAt = newUpdatedAt;

        emit ValuationUpdated(oldPrice, newPrice, oldUpdatedAt, newUpdatedAt);
        emit PendingValuationAccepted(oldPrice, newPrice, oldUpdatedAt, newUpdatedAt);
    }

    /// @notice Set the maintainer fee recipient.
    function setMaintainer(address newMaintainer) external onlyOwner {
        require(newMaintainer != address(0) || maintainerFeeRate == 0, "MAINTAINER_NOT_SET");
        emit MaintainerUpdated(maintainer, newMaintainer);
        maintainer = newMaintainer;
    }

    /// @notice Set valuation staleness and max percentage move checks.
    function setValuationValidation(uint256 newMaxStaleness, uint256 newMaxDeltaBps) external onlyOwner {
        require(newMaxStaleness > 0, "INVALID_VALUATION_STALENESS");
        require(newMaxDeltaBps <= BPS, "INVALID_VALUATION_DELTA_BPS");

        emit ValuationValidationUpdated(valuationMaxStaleness, newMaxStaleness, maxValuationDeltaBps, newMaxDeltaBps);

        valuationMaxStaleness = newMaxStaleness;
        maxValuationDeltaBps = newMaxDeltaBps;
    }

    /// @notice Set the LP fee rate.
    function setLpFeeRate(uint256 newLpFeeRate) external onlyOwner {
        require(newLpFeeRate + maintainerFeeRate + sellTaxRate < WAD, "FEE_RATE>=1");
        emit LpFeeRateUpdated(lpFeeRate, newLpFeeRate);
        lpFeeRate = newLpFeeRate;
    }

    /// @notice Set the maintainer fee rate.
    function setMaintainerFeeRate(uint256 newMaintainerFeeRate) external onlyOwner {
        require(maintainer != address(0) || newMaintainerFeeRate == 0, "MAINTAINER_NOT_SET");
        require(lpFeeRate + newMaintainerFeeRate + sellTaxRate < WAD, "FEE_RATE>=1");
        emit MaintainerFeeRateUpdated(maintainerFeeRate, newMaintainerFeeRate);
        maintainerFeeRate = newMaintainerFeeRate;
    }

    /// @notice Set the buy-side tax rate.
    function setBuyTaxRate(uint256 newBuyTaxRate) external onlyOwner {
        require(newBuyTaxRate < WAD, "BUY_TAX_RATE>=1");
        emit BuyTaxRateUpdated(buyTaxRate, newBuyTaxRate);
        buyTaxRate = newBuyTaxRate;
    }

    /// @notice Set the sell-side tax rate.
    function setSellTaxRate(uint256 newSellTaxRate) external onlyOwner {
        require(lpFeeRate + maintainerFeeRate + newSellTaxRate < WAD, "FEE_RATE>=1");
        emit SellTaxRateUpdated(sellTaxRate, newSellTaxRate);
        sellTaxRate = newSellTaxRate;
    }

    /// @notice Set the tax recipient.
    function setTaxRecipient(address newTaxRecipient) external onlyOwner {
        require(newTaxRecipient != address(0) || !taxEnabled, "TAX_RECIPIENT_NOT_SET");
        emit TaxRecipientUpdated(taxRecipient, newTaxRecipient);
        taxRecipient = newTaxRecipient;
    }

    /// @notice Enable buy and sell tax collection.
    function enableTax() external onlyOwner {
        require(taxRecipient != address(0), "TAX_RECIPIENT_NOT_SET");
        emit TaxEnabledUpdated(taxEnabled, true);
        taxEnabled = true;
    }

    /// @notice Disable buy and sell tax collection.
    function disableTax() external onlyOwner {
        emit TaxEnabledUpdated(taxEnabled, false);
        taxEnabled = false;
    }

    /// @notice Return the active valuation price after freshness checks.
    function getValuationPrice() public view returns (uint256) {
        (uint256 price,) = _getValidatedValuation();
        return price;
    }

    /// @notice Return the fixed PMM K parameter.
    function getEffectiveK() external view returns (uint256) {
        return k;
    }

    function _getPricingState() internal view returns (PricingState memory pricing) {
        (pricing.price,) = _getValidatedValuation();
        pricing.effectiveK = k;
    }

    /// @dev Reverts when the active valuation is invalid or stale.
    function _getValidatedValuation() internal view returns (uint256 price, uint256 updatedAt) {
        price = valuationPrice;
        updatedAt = valuationUpdatedAt;
        require(price > 0, "INVALID_VALUATION_PRICE");
        require(updatedAt != 0, "INVALID_VALUATION_TIMESTAMP");
        require(updatedAt <= block.timestamp, "VALUATION_TIMESTAMP_IN_FUTURE");
        require(block.timestamp - updatedAt <= valuationMaxStaleness, "STALE_VALUATION_PRICE");
    }

    /// @dev Trips the circuit breaker when the submitted price moves too far.
    function _setValuationPrice(uint256 newPrice, uint256 newUpdatedAt) internal {
        require(newPrice > 0, "INVALID_VALUATION_PRICE");
        require(newUpdatedAt != 0, "INVALID_VALUATION_TIMESTAMP");
        require(newUpdatedAt <= block.timestamp, "VALUATION_TIMESTAMP_IN_FUTURE");
        require(!valuationCircuitBreakerTripped, "VALUATION_CIRCUIT_BREAKER_ACTIVE");

        uint256 oldPrice = valuationPrice;
        uint256 oldUpdatedAt = valuationUpdatedAt;
        uint256 diff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        uint256 maxDiff = FixedPointMathLib.fullMulDiv(oldPrice, maxValuationDeltaBps, BPS);
        if (diff > maxDiff) {
            valuationCircuitBreakerTripped = true;
            pendingValuationPrice = newPrice;
            pendingValuationUpdatedAt = newUpdatedAt;
            emit ValuationCircuitBreakerTripped(oldPrice, newPrice, oldUpdatedAt, newUpdatedAt, maxValuationDeltaBps);
            _onValuationCircuitBreaker();
            return;
        }

        emit ValuationUpdated(oldPrice, newPrice, oldUpdatedAt, newUpdatedAt);
        valuationPrice = newPrice;
        valuationUpdatedAt = newUpdatedAt;
    }

    /// @dev Hook for child pools to pause trading when valuation review is needed.
    function _onValuationCircuitBreaker() internal virtual {}
}
