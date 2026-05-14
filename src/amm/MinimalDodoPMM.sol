// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AMMConfig} from "./base/AMMConfig.sol";
import {EmbeddedLPToken} from "./base/EmbeddedLPToken.sol";
import {ReentrancyGuardLite} from "./base/ReentrancyGuardLite.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {MathHelpers} from "./libraries/MathHelpers.sol";
import {PMMQuoter} from "./libraries/PMMQuoter.sol";
import {BuyQuote, PoolState, RStatus, SellQuote, TargetState} from "./types/PMMTypes.sol";

contract MinimalDodoPMM is EmbeddedLPToken, AMMConfig, ReentrancyGuardLite {
    uint8 public constant TOKEN_DECIMALS = 18;

    IERC20Minimal public immutable baseToken;
    IERC20Minimal public immutable quoteToken;

    bool public tradingEnabled;
    bool public buyingEnabled;
    bool public sellingEnabled;

    RStatus public rStatus;
    uint256 public targetBaseTokenAmount;
    uint256 public targetQuoteTokenAmount;
    uint256 public baseBalance;
    uint256 public quoteBalance;

    event LiquidityProvided(address indexed provider, uint256 baseAmount, uint256 quoteAmount, uint256 sharesMinted);
    event LiquidityWithdrawn(address indexed receiver, uint256 baseAmount, uint256 quoteAmount, uint256 sharesBurned);
    event BuyBaseToken(address indexed buyer, uint256 receiveBase, uint256 payQuote);
    event SellBaseToken(address indexed seller, uint256 payBase, uint256 receiveQuote);
    event ChargeMaintainerFee(address indexed maintainer, bool isBaseToken, uint256 amount);
    event ChargeTax(address indexed recipient, uint256 amount, bool isBuy);
    event TradingEnabledUpdated(bool oldValue, bool newValue);
    event BuyingEnabledUpdated(bool oldValue, bool newValue);
    event SellingEnabledUpdated(bool oldValue, bool newValue);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

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
    )
        EmbeddedLPToken(shareName_, shareSymbol_)
        AMMConfig(owner_, supervisor_, maintainer_, oracle_, lpFeeRate_, maintainerFeeRate_, k_)
    {
        require(baseToken_ != address(0), "INVALID_BASE_TOKEN");
        require(quoteToken_ != address(0), "INVALID_QUOTE_TOKEN");
        require(baseToken_ != quoteToken_, "IDENTICAL_TOKENS");
        require(IERC20Minimal(baseToken_).decimals() == TOKEN_DECIMALS, "BASE_DECIMALS_NOT_18");
        require(IERC20Minimal(quoteToken_).decimals() == TOKEN_DECIMALS, "QUOTE_DECIMALS_NOT_18");

        baseToken = IERC20Minimal(baseToken_);
        quoteToken = IERC20Minimal(quoteToken_);
        buyingEnabled = true;
        sellingEnabled = true;
        rStatus = RStatus.ONE;
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

    function recoverToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
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

    function provideLiquidity(uint256 baseAmountMax, uint256 quoteAmountMax, uint256 minShares)
        external
        nonReentrant
        returns (uint256 sharesMinted, uint256 baseAmount, uint256 quoteAmount)
    {
        require(baseAmountMax > 0 && quoteAmountMax > 0, "NO_LIQUIDITY");
        require(rStatus == RStatus.ONE, "NOT_BALANCED");

        if (totalSupply == 0) {
            baseAmount = baseAmountMax;
            quoteAmount = quoteAmountMax;
            sharesMinted = MathHelpers.sqrt(baseAmount * quoteAmount);
        } else {
            uint256 sharesFromBase = (baseAmountMax * totalSupply) / baseBalance;
            uint256 sharesFromQuote = (quoteAmountMax * totalSupply) / quoteBalance;
            sharesMinted = sharesFromBase < sharesFromQuote ? sharesFromBase : sharesFromQuote;
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

    function withdrawLiquidity(uint256 sharesBurned, uint256 minBaseAmount, uint256 minQuoteAmount)
        external
        nonReentrant
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        require(sharesBurned > 0, "ZERO_SHARES");
        require(sharesBurned <= balanceOf[msg.sender], "INSUFFICIENT_SHARES");

        uint256 supply = totalSupply;
        uint256 baseTarget = targetBaseTokenAmount;
        uint256 quoteTarget = targetQuoteTokenAmount;
        baseAmount = (baseBalance * sharesBurned) / supply;
        quoteAmount = (quoteBalance * sharesBurned) / supply;
        require(baseAmount >= minBaseAmount, "BASE_AMOUNT_NOT_ENOUGH");
        require(quoteAmount >= minQuoteAmount, "QUOTE_AMOUNT_NOT_ENOUGH");

        _burn(msg.sender, sharesBurned);
        if (totalSupply == 0) {
            _resetEmptyPool();
        } else {
            targetBaseTokenAmount = baseTarget - ((baseTarget * sharesBurned) / supply);
            targetQuoteTokenAmount = quoteTarget - ((quoteTarget * sharesBurned) / supply);
        }
        _baseTokenTransferOut(msg.sender, baseAmount);
        _quoteTokenTransferOut(msg.sender, quoteAmount);

        emit LiquidityWithdrawn(msg.sender, baseAmount, quoteAmount, sharesBurned);
    }

    function querySellBaseToken(uint256 amount) external view returns (uint256 receiveQuote) {
        SellQuote memory quote = PMMQuoter.querySellBaseToken(_poolState(), _getPricingState(), amount);
        return quote.receiveQuote;
    }

    function queryBuyBaseToken(uint256 amount) external view returns (uint256 payQuote) {
        BuyQuote memory quote = PMMQuoter.queryBuyBaseToken(_poolState(), _getPricingState(), amount);
        return quote.payQuote + quote.buyTaxQuote;
    }

    function sellBaseToken(uint256 amount, uint256 minReceiveQuote)
        external
        nonReentrant
        whenTradingEnabled
        whenSellingEnabled
        returns (uint256 receiveQuote)
    {
        require(amount > 0, "ZERO_AMOUNT");
        SellQuote memory quote = PMMQuoter.querySellBaseToken(_poolState(), _getPricingState(), amount);
        require(quote.receiveQuote >= minReceiveQuote, "SELL_BASE_RECEIVE_NOT_ENOUGH");

        _quoteTokenTransferOut(msg.sender, quote.receiveQuote);
        _baseTokenTransferIn(msg.sender, amount);
        _chargeSellFees(quote);
        _applySellState(quote);

        emit SellBaseToken(msg.sender, amount, quote.receiveQuote);
        return quote.receiveQuote;
    }

    function buyBaseToken(uint256 amount, uint256 maxPayQuote)
        external
        nonReentrant
        whenTradingEnabled
        whenBuyingEnabled
        returns (uint256 totalPayQuote)
    {
        require(amount > 0, "ZERO_AMOUNT");
        BuyQuote memory quote = PMMQuoter.queryBuyBaseToken(_poolState(), _getPricingState(), amount);
        totalPayQuote = quote.payQuote + quote.buyTaxQuote;
        require(totalPayQuote <= maxPayQuote, "BUY_BASE_COST_TOO_MUCH");

        _baseTokenTransferOut(msg.sender, amount);
        _quoteTokenTransferIn(msg.sender, quote.payQuote);
        _chargeBuyFees(quote);
        _applyBuyState(quote);

        emit BuyBaseToken(msg.sender, amount, totalPayQuote);
    }

    function getExpectedTarget() public view returns (uint256 baseTarget, uint256 quoteTarget) {
        if (rStatus == RStatus.ONE) {
            return (targetBaseTokenAmount, targetQuoteTokenAmount);
        }
        TargetState memory target = PMMQuoter.expectedTarget(_poolState(), _getPricingState());
        return (target.baseTarget, target.quoteTarget);
    }

    function getMidPrice() external view returns (uint256 midPrice) {
        return PMMQuoter.midPrice(_poolState(), _getPricingState());
    }

    function _poolState() internal view returns (PoolState memory pool) {
        pool.rStatus = rStatus;
        pool.baseBalance = baseBalance;
        pool.quoteBalance = quoteBalance;
        pool.targetBaseTokenAmount = targetBaseTokenAmount;
        pool.targetQuoteTokenAmount = targetQuoteTokenAmount;
        pool.lpFeeRate = lpFeeRate;
        pool.maintainerFeeRate = maintainerFeeRate;
        pool.buyTaxRate = buyTaxRate;
        pool.sellTaxRate = sellTaxRate;
        pool.taxEnabled = taxEnabled;
        pool.taxRecipient = taxRecipient;
    }

    function _resetEmptyPool() internal {
        targetBaseTokenAmount = 0;
        targetQuoteTokenAmount = 0;
        rStatus = RStatus.ONE;
        if (tradingEnabled) {
            emit TradingEnabledUpdated(tradingEnabled, false);
            tradingEnabled = false;
        }
    }

    function _chargeSellFees(SellQuote memory quote) internal {
        if (quote.maintainerFeeQuote > 0) {
            _quoteTokenTransferOut(maintainer, quote.maintainerFeeQuote);
            emit ChargeMaintainerFee(maintainer, false, quote.maintainerFeeQuote);
        }

        if (quote.sellTaxQuote > 0) {
            _quoteTokenTransferOut(taxRecipient, quote.sellTaxQuote);
            emit ChargeTax(taxRecipient, quote.sellTaxQuote, false);
        }
    }

    function _chargeBuyFees(BuyQuote memory quote) internal {
        if (quote.buyTaxQuote > 0) {
            _quoteTokenTransferFrom(msg.sender, taxRecipient, quote.buyTaxQuote);
            emit ChargeTax(taxRecipient, quote.buyTaxQuote, true);
        }

        if (quote.maintainerFeeBase > 0) {
            _baseTokenTransferOut(maintainer, quote.maintainerFeeBase);
            emit ChargeMaintainerFee(maintainer, true, quote.maintainerFeeBase);
        }
    }

    function _applySellState(SellQuote memory quote) internal {
        targetBaseTokenAmount = quote.newBaseTarget;
        targetQuoteTokenAmount = quote.newQuoteTarget + quote.lpFeeQuote;
        rStatus = quote.newRStatus;
    }

    function _applyBuyState(BuyQuote memory quote) internal {
        targetBaseTokenAmount = quote.newBaseTarget + quote.lpFeeBase;
        targetQuoteTokenAmount = quote.newQuoteTarget;
        rStatus = quote.newRStatus;
    }

    function _baseTokenTransferIn(address from, uint256 amount) internal {
        uint256 balanceBefore = baseToken.balanceOf(address(this));
        require(baseToken.transferFrom(from, address(this), amount), "BASE_TRANSFER_FROM_FAILED");
        uint256 received = baseToken.balanceOf(address(this)) - balanceBefore;
        require(received == amount, "BASE_TRANSFER_IN_MISMATCH");
        baseBalance += received;
    }

    function _quoteTokenTransferIn(address from, uint256 amount) internal {
        uint256 balanceBefore = quoteToken.balanceOf(address(this));
        require(quoteToken.transferFrom(from, address(this), amount), "QUOTE_TRANSFER_FROM_FAILED");
        uint256 received = quoteToken.balanceOf(address(this)) - balanceBefore;
        require(received == amount, "QUOTE_TRANSFER_IN_MISMATCH");
        quoteBalance += received;
    }

    function _baseTokenTransferOut(address to, uint256 amount) internal {
        uint256 balanceBefore = baseToken.balanceOf(address(this));
        baseBalance -= amount;
        require(baseToken.transfer(to, amount), "BASE_TRANSFER_FAILED");
        require(balanceBefore - baseToken.balanceOf(address(this)) == amount, "BASE_TRANSFER_OUT_MISMATCH");
    }

    function _quoteTokenTransferOut(address to, uint256 amount) internal {
        uint256 balanceBefore = quoteToken.balanceOf(address(this));
        quoteBalance -= amount;
        require(quoteToken.transfer(to, amount), "QUOTE_TRANSFER_FAILED");
        require(balanceBefore - quoteToken.balanceOf(address(this)) == amount, "QUOTE_TRANSFER_OUT_MISMATCH");
    }

    function _quoteTokenTransferFrom(address from, address to, uint256 amount) internal {
        require(quoteToken.transferFrom(from, to, amount), "QUOTE_TRANSFER_FROM_FAILED");
    }
}
