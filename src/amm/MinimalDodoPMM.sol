// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {DecimalMath} from "./libraries/DecimalMath.sol";
import {MathHelpers} from "./libraries/MathHelpers.sol";
import {PMMMath} from "./libraries/PMMMath.sol";

contract MinimalDodoPMM {
    enum RStatus {
        ONE,
        ABOVE_ONE,
        BELOW_ONE
    }

    address public owner;
    address public supervisor;
    address public maintainer;
    address public taxRecipient;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    IERC20Minimal public immutable baseToken;
    IERC20Minimal public immutable quoteToken;
    IPriceOracle public oracle;

    bool public tradingEnabled;
    bool public buyingEnabled;
    bool public sellingEnabled;
    bool public taxEnabled;

    uint256 public lpFeeRate;
    uint256 public maintainerFeeRate;
    uint256 public buyTaxRate;
    uint256 public sellTaxRate;
    uint256 public k;

    RStatus public rStatus;
    uint256 public targetBaseTokenAmount;
    uint256 public targetQuoteTokenAmount;
    uint256 public baseBalance;
    uint256 public quoteBalance;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool private entered;

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event SupervisorUpdated(address indexed oldSupervisor, address indexed newSupervisor);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event MaintainerUpdated(address indexed oldMaintainer, address indexed newMaintainer);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event LiquidityProvided(address indexed provider, uint256 baseAmount, uint256 quoteAmount, uint256 sharesMinted);
    event LiquidityWithdrawn(address indexed receiver, uint256 baseAmount, uint256 quoteAmount, uint256 sharesBurned);
    event BuyBaseToken(address indexed buyer, uint256 receiveBase, uint256 payQuote);
    event SellBaseToken(address indexed seller, uint256 payBase, uint256 receiveQuote);
    event ChargeMaintainerFee(address indexed maintainer, bool isBaseToken, uint256 amount);
    event ChargeTax(address indexed recipient, uint256 amount, bool isBuy);
    event TaxRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TaxEnabledUpdated(bool oldEnabled, bool newEnabled);
    event BuyTaxRateUpdated(uint256 oldRate, uint256 newRate);
    event SellTaxRateUpdated(uint256 oldRate, uint256 newRate);
    event LpFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event MaintainerFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event KUpdated(uint256 oldK, uint256 newK);
    event TradingEnabledUpdated(bool oldValue, bool newValue);
    event BuyingEnabledUpdated(bool oldValue, bool newValue);
    event SellingEnabledUpdated(bool oldValue, bool newValue);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlySupervisorOrOwner() {
        require(msg.sender == owner || msg.sender == supervisor, "NOT_SUPERVISOR_OR_OWNER");
        _;
    }

    modifier nonReentrant() {
        require(!entered, "REENTRANT");
        entered = true;
        _;
        entered = false;
    }

    modifier whenTradingEnabled() {
        require(tradingEnabled, "TRADE_NOT_ALLOWED");
        _;
    }

    modifier whenBuyingEnabled() {
        require(buyingEnabled, "BUYING_NOT_ALLOWED");
        _;
    }

    modifier whenSellingEnabled() {
        require(sellingEnabled, "SELLING_NOT_ALLOWED");
        _;
    }

    constructor(
        address owner_,
        address supervisor_,
        address maintainer_,
        address baseToken_,
        address quoteToken_,
        address oracle_,
        uint256 lpFeeRate_,
        uint256 maintainerFeeRate_,
        uint256 k_,
        string memory shareName_,
        string memory shareSymbol_
    ) {
        require(owner_ != address(0), "INVALID_OWNER");
        require(baseToken_ != address(0), "INVALID_BASE_TOKEN");
        require(quoteToken_ != address(0), "INVALID_QUOTE_TOKEN");
        require(oracle_ != address(0), "INVALID_ORACLE");

        owner = owner_;
        supervisor = supervisor_;
        maintainer = maintainer_;
        name = shareName_;
        symbol = shareSymbol_;
        baseToken = IERC20Minimal(baseToken_);
        quoteToken = IERC20Minimal(quoteToken_);
        oracle = IPriceOracle(oracle_);
        buyingEnabled = true;
        sellingEnabled = true;
        rStatus = RStatus.ONE;
        lpFeeRate = lpFeeRate_;
        maintainerFeeRate = maintainerFeeRate_;
        k = k_;
        _checkParameters();
        emit OwnershipTransferred(address(0), owner_);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "INVALID_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setSupervisor(address newSupervisor) external onlyOwner {
        emit SupervisorUpdated(supervisor, newSupervisor);
        supervisor = newSupervisor;
    }

    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "INVALID_ORACLE");
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IPriceOracle(newOracle);
    }

    function setMaintainer(address newMaintainer) external onlyOwner {
        emit MaintainerUpdated(maintainer, newMaintainer);
        maintainer = newMaintainer;
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

    function enableTrading() external onlyOwner {
        require(baseBalance > 0 && quoteBalance > 0 && totalSupply > 0, "POOL_NOT_FUNDED");
        emit TradingEnabledUpdated(tradingEnabled, true);
        tradingEnabled = true;
    }

    function disableTrading() external onlySupervisorOrOwner {
        emit TradingEnabledUpdated(tradingEnabled, false);
        tradingEnabled = false;
    }

    function enableBuying() external onlyOwner {
        emit BuyingEnabledUpdated(buyingEnabled, true);
        buyingEnabled = true;
    }

    function disableBuying() external onlySupervisorOrOwner {
        emit BuyingEnabledUpdated(buyingEnabled, false);
        buyingEnabled = false;
    }

    function enableSelling() external onlyOwner {
        emit SellingEnabledUpdated(sellingEnabled, true);
        sellingEnabled = true;
    }

    function disableSelling() external onlySupervisorOrOwner {
        emit SellingEnabledUpdated(sellingEnabled, false);
        sellingEnabled = false;
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

    function recoverToken(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "INVALID_TOKEN");
        require(to != address(0), "INVALID_RECEIVER");

        if (token == address(baseToken)) {
            require(baseToken.balanceOf(address(this)) >= baseBalance + amount, "BASE_BALANCE_NOT_ENOUGH");
        } else if (token == address(quoteToken)) {
            require(quoteToken.balanceOf(address(this)) >= quoteBalance + amount, "QUOTE_BALANCE_NOT_ENOUGH");
        }

        require(IERC20Minimal(token).transfer(to, amount), "TOKEN_TRANSFER_FAILED");
        emit TokenRecovered(token, to, amount);
    }

    function provideLiquidity(
        uint256 baseAmountMax,
        uint256 quoteAmountMax,
        uint256 minShares
    ) external nonReentrant returns (uint256 sharesMinted, uint256 baseAmount, uint256 quoteAmount) {
        require(baseAmountMax > 0 && quoteAmountMax > 0, "NO_LIQUIDITY");
        require(rStatus == RStatus.ONE, "NOT_BALANCED");

        if (totalSupply == 0) {
            baseAmount = baseAmountMax;
            quoteAmount = quoteAmountMax;
            sharesMinted = MathHelpers.sqrt(baseAmount * quoteAmount);
        } else {
            uint256 sharesFromBase = (baseAmountMax * totalSupply) / baseBalance;
            uint256 sharesFromQuote = (quoteAmountMax * totalSupply) / quoteBalance;
            sharesMinted = _min(sharesFromBase, sharesFromQuote);
            baseAmount = (sharesMinted * baseBalance) / totalSupply;
            quoteAmount = (sharesMinted * quoteBalance) / totalSupply;
        }
        require(sharesMinted >= minShares, "INSUFFICIENT_SHARES");
        require(sharesMinted > 0 && baseAmount > 0 && quoteAmount > 0, "ZERO_SHARES");

        _baseTokenTransferIn(msg.sender, baseAmount);
        _quoteTokenTransferIn(msg.sender, quoteAmount);
        targetBaseTokenAmount += baseAmount;
        targetQuoteTokenAmount += quoteAmount;
        _mint(msg.sender, sharesMinted);

        emit LiquidityProvided(msg.sender, baseAmount, quoteAmount, sharesMinted);
    }

    function withdrawLiquidity(
        uint256 sharesBurned,
        uint256 minBaseAmount,
        uint256 minQuoteAmount
    ) external nonReentrant returns (uint256 baseAmount, uint256 quoteAmount) {
        require(rStatus == RStatus.ONE, "NOT_BALANCED");
        require(sharesBurned > 0, "ZERO_SHARES");

        baseAmount = (baseBalance * sharesBurned) / totalSupply;
        quoteAmount = (quoteBalance * sharesBurned) / totalSupply;
        require(baseAmount >= minBaseAmount, "BASE_AMOUNT_NOT_ENOUGH");
        require(quoteAmount >= minQuoteAmount, "QUOTE_AMOUNT_NOT_ENOUGH");

        _burn(msg.sender, sharesBurned);
        targetBaseTokenAmount -= baseAmount;
        targetQuoteTokenAmount -= quoteAmount;
        _baseTokenTransferOut(msg.sender, baseAmount);
        _quoteTokenTransferOut(msg.sender, quoteAmount);

        emit LiquidityWithdrawn(msg.sender, baseAmount, quoteAmount, sharesBurned);
    }

    function querySellBaseToken(uint256 amount) external view returns (uint256 receiveQuote) {
        (receiveQuote, , , , , , ) = _querySellBaseToken(amount);
    }

    function queryBuyBaseToken(uint256 amount) external view returns (uint256 payQuote) {
        uint256 buyTaxQuote;
        (payQuote, , , buyTaxQuote, , , ) = _queryBuyBaseToken(amount);
        return payQuote + buyTaxQuote;
    }

    function sellBaseToken(
        uint256 amount,
        uint256 minReceiveQuote
    ) external nonReentrant whenTradingEnabled whenSellingEnabled returns (uint256 receiveQuote) {
        uint256 lpFeeQuote;
        uint256 maintainerFeeQuote;
        uint256 sellTaxQuote;
        RStatus newRStatus;
        uint256 newQuoteTarget;
        uint256 newBaseTarget;
        (
            receiveQuote,
            lpFeeQuote,
            maintainerFeeQuote,
            sellTaxQuote,
            newRStatus,
            newQuoteTarget,
            newBaseTarget
        ) = _querySellBaseToken(amount);
        require(receiveQuote >= minReceiveQuote, "SELL_BASE_RECEIVE_NOT_ENOUGH");

        _quoteTokenTransferOut(msg.sender, receiveQuote);
        _baseTokenTransferIn(msg.sender, amount);

        if (maintainerFeeQuote > 0) {
            _quoteTokenTransferOut(maintainer, maintainerFeeQuote);
            emit ChargeMaintainerFee(maintainer, false, maintainerFeeQuote);
        }

        if (sellTaxQuote > 0) {
            _quoteTokenTransferOut(taxRecipient, sellTaxQuote);
            emit ChargeTax(taxRecipient, sellTaxQuote, false);
        }

        targetBaseTokenAmount = newBaseTarget;
        targetQuoteTokenAmount = newQuoteTarget;
        rStatus = newRStatus;
        targetQuoteTokenAmount += lpFeeQuote;

        emit SellBaseToken(msg.sender, amount, receiveQuote);
    }

    function buyBaseToken(
        uint256 amount,
        uint256 maxPayQuote
    ) external nonReentrant whenTradingEnabled whenBuyingEnabled returns (uint256 totalPayQuote) {
        uint256 payQuote;
        uint256 lpFeeBase;
        uint256 maintainerFeeBase;
        uint256 buyTaxQuote;
        RStatus newRStatus;
        uint256 newQuoteTarget;
        uint256 newBaseTarget;
        (
            payQuote,
            lpFeeBase,
            maintainerFeeBase,
            buyTaxQuote,
            newRStatus,
            newQuoteTarget,
            newBaseTarget
        ) = _queryBuyBaseToken(amount);
        totalPayQuote = payQuote + buyTaxQuote;
        require(totalPayQuote <= maxPayQuote, "BUY_BASE_COST_TOO_MUCH");

        _baseTokenTransferOut(msg.sender, amount);
        _quoteTokenTransferIn(msg.sender, payQuote);

        if (buyTaxQuote > 0) {
            _quoteTokenTransferFrom(msg.sender, taxRecipient, buyTaxQuote);
            emit ChargeTax(taxRecipient, buyTaxQuote, true);
        }

        if (maintainerFeeBase > 0) {
            _baseTokenTransferOut(maintainer, maintainerFeeBase);
            emit ChargeMaintainerFee(maintainer, true, maintainerFeeBase);
        }

        targetBaseTokenAmount = newBaseTarget;
        targetQuoteTokenAmount = newQuoteTarget;
        rStatus = newRStatus;
        targetBaseTokenAmount += lpFeeBase;

        emit BuyBaseToken(msg.sender, amount, totalPayQuote);
    }

    function getExpectedTarget() public view returns (uint256 baseTarget, uint256 quoteTarget) {
        if (rStatus == RStatus.ONE) {
            return (targetBaseTokenAmount, targetQuoteTokenAmount);
        }
        if (rStatus == RStatus.BELOW_ONE) {
            return (targetBaseTokenAmount, quoteBalance + _rBelowBackToOne());
        }
        return (baseBalance + _rAboveBackToOne(), targetQuoteTokenAmount);
    }

    function getMidPrice() external view returns (uint256 midPrice) {
        (uint256 baseTarget, uint256 quoteTarget) = getExpectedTarget();
        if (rStatus == RStatus.BELOW_ONE) {
            uint256 belowRatio = DecimalMath.divFloor((quoteTarget * quoteTarget) / quoteBalance, quoteBalance);
            belowRatio = DecimalMath.ONE - k + DecimalMath.mul(k, belowRatio);
            return DecimalMath.divFloor(getOraclePrice(), belowRatio);
        }

        uint256 aboveRatio = DecimalMath.divFloor((baseTarget * baseTarget) / baseBalance, baseBalance);
        aboveRatio = DecimalMath.ONE - k + DecimalMath.mul(k, aboveRatio);
        return DecimalMath.mul(getOraclePrice(), aboveRatio);
    }

    function getOraclePrice() public view returns (uint256) {
        return oracle.getPrice();
    }

    function _querySellBaseToken(
        uint256 amount
    )
        internal
        view
        returns (
            uint256 receiveQuote,
            uint256 lpFeeQuote,
            uint256 maintainerFeeQuote,
            uint256 sellTaxQuote,
            RStatus newRStatus,
            uint256 newQuoteTarget,
            uint256 newBaseTarget
        )
    {
        (newBaseTarget, newQuoteTarget) = getExpectedTarget();

        if (rStatus == RStatus.ONE) {
            receiveQuote = _rOneSellBaseToken(amount, newQuoteTarget);
            newRStatus = RStatus.BELOW_ONE;
        } else if (rStatus == RStatus.ABOVE_ONE) {
            uint256 backToOnePayBase = newBaseTarget - baseBalance;
            uint256 backToOneReceiveQuote = quoteBalance - newQuoteTarget;

            if (amount < backToOnePayBase) {
                receiveQuote = _rAboveSellBaseToken(amount, baseBalance, newBaseTarget);
                newRStatus = RStatus.ABOVE_ONE;
                if (receiveQuote > backToOneReceiveQuote) {
                    receiveQuote = backToOneReceiveQuote;
                }
            } else if (amount == backToOnePayBase) {
                receiveQuote = backToOneReceiveQuote;
                newRStatus = RStatus.ONE;
            } else {
                receiveQuote = backToOneReceiveQuote + _rOneSellBaseToken(amount - backToOnePayBase, newQuoteTarget);
                newRStatus = RStatus.BELOW_ONE;
            }
        } else {
            receiveQuote = _rBelowSellBaseToken(amount, quoteBalance, newQuoteTarget);
            newRStatus = RStatus.BELOW_ONE;
        }

        lpFeeQuote = DecimalMath.mul(receiveQuote, lpFeeRate);
        maintainerFeeQuote = DecimalMath.mul(receiveQuote, maintainerFeeRate);
        sellTaxQuote = _getSellTaxQuote(receiveQuote);
        receiveQuote = receiveQuote - lpFeeQuote - maintainerFeeQuote - sellTaxQuote;
    }

    function _queryBuyBaseToken(
        uint256 amount
    )
        internal
        view
        returns (
            uint256 payQuote,
            uint256 lpFeeBase,
            uint256 maintainerFeeBase,
            uint256 buyTaxQuote,
            RStatus newRStatus,
            uint256 newQuoteTarget,
            uint256 newBaseTarget
        )
    {
        (newBaseTarget, newQuoteTarget) = getExpectedTarget();

        lpFeeBase = DecimalMath.mul(amount, lpFeeRate);
        maintainerFeeBase = DecimalMath.mul(amount, maintainerFeeRate);
        uint256 buyBaseAmount = amount + lpFeeBase + maintainerFeeBase;

        if (rStatus == RStatus.ONE) {
            payQuote = _rOneBuyBaseToken(buyBaseAmount, newBaseTarget);
            newRStatus = RStatus.ABOVE_ONE;
        } else if (rStatus == RStatus.ABOVE_ONE) {
            payQuote = _rAboveBuyBaseToken(buyBaseAmount, baseBalance, newBaseTarget);
            newRStatus = RStatus.ABOVE_ONE;
        } else {
            uint256 backToOnePayQuote = newQuoteTarget - quoteBalance;
            uint256 backToOneReceiveBase = baseBalance - newBaseTarget;

            if (buyBaseAmount < backToOneReceiveBase) {
                payQuote = _rBelowBuyBaseToken(buyBaseAmount, quoteBalance, newQuoteTarget);
                newRStatus = RStatus.BELOW_ONE;
            } else if (buyBaseAmount == backToOneReceiveBase) {
                payQuote = backToOnePayQuote;
                newRStatus = RStatus.ONE;
            } else {
                payQuote = backToOnePayQuote + _rOneBuyBaseToken(buyBaseAmount - backToOneReceiveBase, newBaseTarget);
                newRStatus = RStatus.ABOVE_ONE;
            }
        }

        buyTaxQuote = _getBuyTaxQuote(payQuote);
    }

    function _rOneSellBaseToken(uint256 amount, uint256 targetQuoteAmount) internal view returns (uint256) {
        uint256 q2 = PMMMath.solveQuadraticFunctionForTrade(
            targetQuoteAmount,
            targetQuoteAmount,
            DecimalMath.mul(getOraclePrice(), amount),
            false,
            k
        );
        return targetQuoteAmount - q2;
    }

    function _rOneBuyBaseToken(uint256 amount, uint256 targetBaseAmount) internal view returns (uint256) {
        require(amount < targetBaseAmount, "DODO_BASE_BALANCE_NOT_ENOUGH");
        return _rAboveIntegrate(targetBaseAmount, targetBaseAmount, targetBaseAmount - amount);
    }

    function _rBelowSellBaseToken(
        uint256 amount,
        uint256 currentQuoteBalance,
        uint256 targetQuoteAmount
    ) internal view returns (uint256) {
        uint256 q2 = PMMMath.solveQuadraticFunctionForTrade(
            targetQuoteAmount,
            currentQuoteBalance,
            DecimalMath.mul(getOraclePrice(), amount),
            false,
            k
        );
        return currentQuoteBalance - q2;
    }

    function _rBelowBuyBaseToken(
        uint256 amount,
        uint256 currentQuoteBalance,
        uint256 targetQuoteAmount
    ) internal view returns (uint256) {
        uint256 q2 = PMMMath.solveQuadraticFunctionForTrade(
            targetQuoteAmount,
            currentQuoteBalance,
            DecimalMath.mulCeil(getOraclePrice(), amount),
            true,
            k
        );
        return q2 - currentQuoteBalance;
    }

    function _rAboveBuyBaseToken(
        uint256 amount,
        uint256 currentBaseBalance,
        uint256 targetBaseAmount
    ) internal view returns (uint256) {
        require(amount < currentBaseBalance, "DODO_BASE_BALANCE_NOT_ENOUGH");
        return _rAboveIntegrate(targetBaseAmount, currentBaseBalance, currentBaseBalance - amount);
    }

    function _rAboveSellBaseToken(
        uint256 amount,
        uint256 currentBaseBalance,
        uint256 targetBaseAmount
    ) internal view returns (uint256) {
        return _rAboveIntegrate(targetBaseAmount, currentBaseBalance + amount, currentBaseBalance);
    }

    function _rBelowBackToOne() internal view returns (uint256) {
        uint256 spareBase = baseBalance - targetBaseTokenAmount;
        uint256 fairAmount = DecimalMath.mul(spareBase, getOraclePrice());
        uint256 newTargetQuote = PMMMath.solveQuadraticFunctionForTarget(quoteBalance, k, fairAmount);
        return newTargetQuote - quoteBalance;
    }

    function _rAboveBackToOne() internal view returns (uint256) {
        uint256 spareQuote = quoteBalance - targetQuoteTokenAmount;
        uint256 fairAmount = DecimalMath.divFloor(spareQuote, getOraclePrice());
        uint256 newTargetBase = PMMMath.solveQuadraticFunctionForTarget(baseBalance, k, fairAmount);
        return newTargetBase - baseBalance;
    }

    function _rAboveIntegrate(uint256 b0, uint256 b1, uint256 b2) internal view returns (uint256) {
        return PMMMath.generalIntegrate(b0, b1, b2, getOraclePrice(), k);
    }

    function _getSellTaxQuote(uint256 quoteAmount) internal view returns (uint256) {
        if (!taxEnabled || sellTaxRate == 0) {
            return 0;
        }
        require(taxRecipient != address(0), "INVALID_TAX_RECIPIENT");
        return DecimalMath.mul(quoteAmount, sellTaxRate);
    }

    function _getBuyTaxQuote(uint256 quoteAmount) internal view returns (uint256) {
        if (!taxEnabled || buyTaxRate == 0) {
            return 0;
        }
        require(taxRecipient != address(0), "INVALID_TAX_RECIPIENT");
        return DecimalMath.mul(quoteAmount, buyTaxRate);
    }

    function _baseTokenTransferIn(address from, uint256 amount) internal {
        require(baseToken.transferFrom(from, address(this), amount), "BASE_TRANSFER_FROM_FAILED");
        baseBalance += amount;
    }

    function _quoteTokenTransferIn(address from, uint256 amount) internal {
        require(quoteToken.transferFrom(from, address(this), amount), "QUOTE_TRANSFER_FROM_FAILED");
        quoteBalance += amount;
    }

    function _baseTokenTransferOut(address to, uint256 amount) internal {
        baseBalance -= amount;
        require(baseToken.transfer(to, amount), "BASE_TRANSFER_FAILED");
    }

    function _quoteTokenTransferOut(address to, uint256 amount) internal {
        quoteBalance -= amount;
        require(quoteToken.transfer(to, amount), "QUOTE_TRANSFER_FAILED");
    }

    function _quoteTokenTransferFrom(address from, address to, uint256 amount) internal {
        require(quoteToken.transferFrom(from, to, amount), "QUOTE_TRANSFER_FROM_FAILED");
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "INVALID_RECEIVER");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _checkParameters() internal view {
        require(k > 0, "K=0");
        require(k < DecimalMath.ONE, "K>=1");
        require(buyTaxRate < DecimalMath.ONE, "BUY_TAX_RATE>=1");
        require(lpFeeRate + maintainerFeeRate + sellTaxRate < DecimalMath.ONE, "FEE_RATE>=1");
    }
}
