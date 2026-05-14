// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {DecimalMath} from "../libraries/DecimalMath.sol";
import {MathHelpers} from "../libraries/MathHelpers.sol";
import {ValuationMath} from "../libraries/ValuationMath.sol";
import {PricingState} from "../types/PMMTypes.sol";
import {AMMRoles} from "./AMMRoles.sol";

abstract contract AMMConfig is AMMRoles {
    uint256 public constant DEFAULT_ORACLE_MAX_STALENESS = 180 days;
    uint256 public constant DEFAULT_MAX_K = 7e17;

    address public maintainer;
    address public taxRecipient;
    IPriceOracle public oracle;

    bool public taxEnabled;

    uint256 public lpFeeRate;
    uint256 public maintainerFeeRate;
    uint256 public buyTaxRate;
    uint256 public sellTaxRate;
    uint256 public k;
    uint256 public maxK;
    uint256 public kGrowthPerSecond;
    uint256 public oracleMaxStaleness;
    uint256 public minOraclePrice;
    uint256 public maxOraclePrice;

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event MaintainerUpdated(address indexed oldMaintainer, address indexed newMaintainer);
    event OracleValidationUpdated(
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
        address oracle_,
        uint256 lpFeeRate_,
        uint256 maintainerFeeRate_,
        uint256 k_
    ) AMMRoles(owner_, supervisor_) {
        require(oracle_ != address(0), "INVALID_ORACLE");

        maintainer = maintainer_;
        oracle = IPriceOracle(oracle_);
        lpFeeRate = lpFeeRate_;
        maintainerFeeRate = maintainerFeeRate_;
        k = k_;
        maxK = k_ > DEFAULT_MAX_K ? k_ : DEFAULT_MAX_K;
        kGrowthPerSecond = MathHelpers.ceilDiv(maxK - k_, DEFAULT_ORACLE_MAX_STALENESS);
        oracleMaxStaleness = DEFAULT_ORACLE_MAX_STALENESS;
        minOraclePrice = 1;
        maxOraclePrice = type(uint256).max;
        _checkParameters();
    }

    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "INVALID_ORACLE");
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IPriceOracle(newOracle);
    }

    function setMaintainer(address newMaintainer) external onlyOwner {
        require(newMaintainer != address(0) || maintainerFeeRate == 0, "MAINTAINER_NOT_SET");
        emit MaintainerUpdated(maintainer, newMaintainer);
        maintainer = newMaintainer;
    }

    function setOracleValidation(uint256 newMaxStaleness, uint256 newMinPrice, uint256 newMaxPrice) external onlyOwner {
        require(newMaxStaleness > 0, "INVALID_ORACLE_STALENESS");
        require(newMinPrice > 0, "INVALID_MIN_ORACLE_PRICE");
        require(newMaxPrice >= newMinPrice, "INVALID_MAX_ORACLE_PRICE");

        emit OracleValidationUpdated(
            oracleMaxStaleness, newMaxStaleness, minOraclePrice, newMinPrice, maxOraclePrice, newMaxPrice
        );

        oracleMaxStaleness = newMaxStaleness;
        minOraclePrice = newMinPrice;
        maxOraclePrice = newMaxPrice;
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

    function getOraclePrice() public view returns (uint256) {
        (uint256 price,) = _getValidatedOracle();
        return price;
    }

    function getEffectiveK() external view returns (uint256) {
        (, uint256 updatedAt) = _getValidatedOracle();
        return _getEffectiveK(updatedAt);
    }

    function _getPricingState() internal view returns (PricingState memory pricing) {
        uint256 updatedAt;
        (pricing.price, updatedAt) = _getValidatedOracle();
        pricing.effectiveK = _getEffectiveK(updatedAt);
    }

    function _getValidatedOracle() internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = oracle.getPrice();
        require(price > 0, "INVALID_ORACLE_PRICE");
        require(price >= minOraclePrice && price <= maxOraclePrice, "ORACLE_PRICE_OUT_OF_RANGE");
        require(updatedAt != 0, "INVALID_ORACLE_TIMESTAMP");
        require(updatedAt <= block.timestamp, "ORACLE_TIMESTAMP_IN_FUTURE");
        require(block.timestamp - updatedAt <= oracleMaxStaleness, "STALE_ORACLE_PRICE");
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
