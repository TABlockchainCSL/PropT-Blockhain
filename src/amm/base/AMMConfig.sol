// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {DecimalMath} from "../libraries/DecimalMath.sol";
import {MathHelpers} from "../libraries/MathHelpers.sol";
import {ValuationMath} from "../libraries/ValuationMath.sol";
import {PricingState} from "../types/PMMTypes.sol";
import {AMMRoles} from "./AMMRoles.sol";

abstract contract AMMConfig is AMMRoles {
    uint256 public constant DEFAULT_VALUATION_MAX_STALENESS = 180 days;
    uint256 public constant DEFAULT_MAX_K = 7e17;

    address public maintainer;
    address public taxRecipient;

    bool public taxEnabled;

    uint256 public lpFeeRate;
    uint256 public maintainerFeeRate;
    uint256 public buyTaxRate;
    uint256 public sellTaxRate;
    uint256 public k;
    uint256 public maxK;
    uint256 public kGrowthPerSecond;
    uint256 public valuationPrice;
    uint256 public valuationUpdatedAt;
    uint256 public valuationMaxStaleness;
    uint256 public minValuationPrice;
    uint256 public maxValuationPrice;

    event ValuationUpdated(uint256 oldPrice, uint256 newPrice, uint256 oldUpdatedAt, uint256 newUpdatedAt);
    event MaintainerUpdated(address indexed oldMaintainer, address indexed newMaintainer);
    event ValuationValidationUpdated(
        uint256 oldMaxStaleness,
        uint256 newMaxStaleness,
        uint256 oldMinPrice,
        uint256 newMinPrice,
        uint256 oldMaxPrice,
        uint256 newMaxPrice
    );
    event TaxRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TaxEnabledUpdated(bool oldEnabled, bool newEnabled);
    event BuyTaxRateUpdated(uint256 oldRate, uint256 newRate);
    event SellTaxRateUpdated(uint256 oldRate, uint256 newRate);
    event LpFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event MaintainerFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event KUpdated(uint256 oldK, uint256 newK);
    event AgeAdjustedKUpdated(uint256 oldMaxK, uint256 newMaxK, uint256 oldGrowth, uint256 newGrowth);

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

        maintainer = maintainer_;
        valuationPrice = initialValuationPrice_;
        valuationUpdatedAt = block.timestamp;
        lpFeeRate = lpFeeRate_;
        maintainerFeeRate = maintainerFeeRate_;
        k = k_;
        maxK = k_ > DEFAULT_MAX_K ? k_ : DEFAULT_MAX_K;
        kGrowthPerSecond = MathHelpers.ceilDiv(maxK - k_, DEFAULT_VALUATION_MAX_STALENESS);
        valuationMaxStaleness = DEFAULT_VALUATION_MAX_STALENESS;
        minValuationPrice = 1;
        maxValuationPrice = type(uint256).max;
        _checkParameters();
    }

    function setValuationPrice(uint256 newPrice) external onlyOwner {
        _setValuationPrice(newPrice, block.timestamp);
    }

    function setValuationPriceWithTimestamp(uint256 newPrice, uint256 newUpdatedAt) external onlyOwner {
        _setValuationPrice(newPrice, newUpdatedAt);
    }

    function setMaintainer(address newMaintainer) external onlyOwner {
        require(newMaintainer != address(0) || maintainerFeeRate == 0, "MAINTAINER_NOT_SET");
        emit MaintainerUpdated(maintainer, newMaintainer);
        maintainer = newMaintainer;
    }

    function setValuationValidation(uint256 newMaxStaleness, uint256 newMinPrice, uint256 newMaxPrice)
        external
        onlyOwner
    {
        require(newMaxStaleness > 0, "INVALID_VALUATION_STALENESS");
        require(newMinPrice > 0, "INVALID_MIN_VALUATION_PRICE");
        require(newMaxPrice >= newMinPrice, "INVALID_MAX_VALUATION_PRICE");

        emit ValuationValidationUpdated(
            valuationMaxStaleness, newMaxStaleness, minValuationPrice, newMinPrice, maxValuationPrice, newMaxPrice
        );

        valuationMaxStaleness = newMaxStaleness;
        minValuationPrice = newMinPrice;
        maxValuationPrice = newMaxPrice;
    }

    function setLpFeeRate(uint256 newLpFeeRate) external onlyOwner {
        emit LpFeeRateUpdated(lpFeeRate, newLpFeeRate);
        lpFeeRate = newLpFeeRate;
        _checkParameters();
    }

    function setMaintainerFeeRate(uint256 newMaintainerFeeRate) external onlyOwner {
        emit MaintainerFeeRateUpdated(maintainerFeeRate, newMaintainerFeeRate);
        maintainerFeeRate = newMaintainerFeeRate;
        _checkParameters();
    }

    function setBuyTaxRate(uint256 newBuyTaxRate) external onlyOwner {
        emit BuyTaxRateUpdated(buyTaxRate, newBuyTaxRate);
        buyTaxRate = newBuyTaxRate;
        _checkParameters();
    }

    function setSellTaxRate(uint256 newSellTaxRate) external onlyOwner {
        emit SellTaxRateUpdated(sellTaxRate, newSellTaxRate);
        sellTaxRate = newSellTaxRate;
        _checkParameters();
    }

    function setTaxRecipient(address newTaxRecipient) external onlyOwner {
        require(newTaxRecipient != address(0) || !taxEnabled, "TAX_RECIPIENT_NOT_SET");
        emit TaxRecipientUpdated(taxRecipient, newTaxRecipient);
        taxRecipient = newTaxRecipient;
    }

    function setK(uint256 newK) external onlyOwner {
        emit KUpdated(k, newK);
        k = newK;
        _checkParameters();
    }

    function setAgeAdjustedK(uint256 newMaxK, uint256 newGrowthPerSecond) external onlyOwner {
        emit AgeAdjustedKUpdated(maxK, newMaxK, kGrowthPerSecond, newGrowthPerSecond);
        maxK = newMaxK;
        kGrowthPerSecond = newGrowthPerSecond;
        _checkParameters();
    }

    function enableTax() external onlyOwner {
        require(taxRecipient != address(0), "TAX_RECIPIENT_NOT_SET");
        emit TaxEnabledUpdated(taxEnabled, true);
        taxEnabled = true;
    }

    function disableTax() external onlyOwner {
        emit TaxEnabledUpdated(taxEnabled, false);
        taxEnabled = false;
    }

    function getValuationPrice() public view returns (uint256) {
        (uint256 price,) = _getValidatedValuation();
        return price;
    }

    function getEffectiveK() external view returns (uint256) {
        (, uint256 updatedAt) = _getValidatedValuation();
        return _getEffectiveK(updatedAt);
    }

    function _getPricingState() internal view returns (PricingState memory pricing) {
        uint256 updatedAt;
        (pricing.price, updatedAt) = _getValidatedValuation();
        pricing.effectiveK = _getEffectiveK(updatedAt);
    }

    function _getValidatedValuation() internal view returns (uint256 price, uint256 updatedAt) {
        price = valuationPrice;
        updatedAt = valuationUpdatedAt;
        require(price > 0, "INVALID_VALUATION_PRICE");
        require(price >= minValuationPrice && price <= maxValuationPrice, "VALUATION_PRICE_OUT_OF_RANGE");
        require(updatedAt != 0, "INVALID_VALUATION_TIMESTAMP");
        require(updatedAt <= block.timestamp, "VALUATION_TIMESTAMP_IN_FUTURE");
        require(block.timestamp - updatedAt <= valuationMaxStaleness, "STALE_VALUATION_PRICE");
    }

    function _setValuationPrice(uint256 newPrice, uint256 newUpdatedAt) internal {
        require(newPrice > 0, "INVALID_VALUATION_PRICE");
        require(newPrice >= minValuationPrice && newPrice <= maxValuationPrice, "VALUATION_PRICE_OUT_OF_RANGE");
        require(newUpdatedAt != 0, "INVALID_VALUATION_TIMESTAMP");
        require(newUpdatedAt <= block.timestamp, "VALUATION_TIMESTAMP_IN_FUTURE");

        emit ValuationUpdated(valuationPrice, newPrice, valuationUpdatedAt, newUpdatedAt);
        valuationPrice = newPrice;
        valuationUpdatedAt = newUpdatedAt;
    }

    function _getEffectiveK(uint256 updatedAt) internal view returns (uint256) {
        return ValuationMath.effectiveK(k, maxK, kGrowthPerSecond, updatedAt, block.timestamp);
    }

    function _checkParameters() internal view {
        require(k > 0, "K=0");
        require(k < DecimalMath.ONE, "K>=1");
        require(maxK >= k, "MAX_K<K");
        require(maxK < DecimalMath.ONE, "MAX_K>=1");
        require(buyTaxRate < DecimalMath.ONE, "BUY_TAX_RATE>=1");
        require(lpFeeRate + maintainerFeeRate + sellTaxRate < DecimalMath.ONE, "FEE_RATE>=1");
        require(maintainer != address(0) || maintainerFeeRate == 0, "MAINTAINER_NOT_SET");
    }
}
