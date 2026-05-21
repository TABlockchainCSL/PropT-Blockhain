// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {AMMConfig} from "./base/AMMConfig.sol";
import {AMMLPDividends} from "./base/AMMLPDividends.sol";
import {PMMQuoter} from "./libraries/PMMQuoter.sol";
import {BuyQuote, PoolState, RStatus, SellQuote, TargetState} from "./types/PMMTypes.sol";
import {IKYCRegistry} from "../interfaces/IKYCRegistry.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Interface for claiming quote-token dividends.
interface IDividendDistributionMinimal {
    function stablecoin() external view returns (address);
    function claimDividends(uint256 maxEpochs) external;
    function pendingDividends(address investor, uint256 maxEpochs) external view returns (uint256);
}

/// @notice Minimal property-token surface needed to infer the KYC registry.
interface IPropertyTokenKYC {
    function kycRegistry() external view returns (IKYCRegistry);
}

/// @title PropertyPMM
/// @notice PMM pool for trading property tokens against a quote token. Quote = Stablecoin, Base = PropertyToken.
/// @dev LP shares are ERC20 tokens; reserves are tracked internally in 18-decimal WAD units.
contract PropertyPMM is ERC20, AMMConfig, AMMLPDividends, ReentrancyGuard {
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice Token sold by the pool (Property Token).
    IERC20Metadata public immutable baseToken;
    /// @notice Quote token used to price trades (Stablecoin).
    IERC20Metadata public immutable quoteToken;
    /// @notice KYC registry inferred from the base property token.
    IKYCRegistry public immutable kycRegistry;

    /// Decimal Adjustment for supporting non 18-decimal tokens.

    /// @notice Native decimals of the base token.
    uint8 public immutable baseTokenDecimals;
    /// @notice Native decimals of the quote token.
    uint8 public immutable quoteTokenDecimals;

    /// @notice Multiplier converting base token amounts to 18 decimals.
    uint256 public immutable baseTokenScale;
    /// @notice Multiplier converting quote token amounts to 18 decimals.
    uint256 public immutable quoteTokenScale;

    /// Pause flags for emergencies and circuit breakers.

    /// @notice Global switch for all swaps.
    bool public tradingEnabled;
    /// @notice Directional switch for buyBaseToken.
    bool public buyingEnabled;
    /// @notice Directional switch for sellBaseToken.
    bool public sellingEnabled;

    /// Pricing and inventory state variables.

    /// @notice PMM inventory status relative to the guide price (Discount, Premium, Balanced to Valuation).
    RStatus public rStatus;

    /// @notice Current target base inventory in WAD units.
    uint256 public targetBaseTokenAmount;
    /// @notice Current target quote inventory in WAD units.
    uint256 public targetQuoteTokenAmount;

    /// @notice Tracked base reserve in WAD units.
    uint256 public baseBalance;
    /// @notice Tracked quote reserve in WAD units.
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
    event QuoteDividendsClaimed(address indexed dividendDistributor, uint256 quoteAmount);

    error InvalidKYCRegistry();
    error SenderNotAuthorized(address sender);
    error RecipientNotAuthorized(address recipient);

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
        uint256 initialValuationPrice_,
        uint256 lpFeeRate_,
        uint256 maintainerFeeRate_,
        uint256 k_,
        string memory shareName_,
        string memory shareSymbol_
    )
        ERC20(shareName_, shareSymbol_)
        AMMConfig(owner_, supervisor_, maintainer_, initialValuationPrice_, lpFeeRate_, maintainerFeeRate_, k_)
    {
        require(baseToken_ != address(0), "INVALID_BASE_TOKEN");
        require(quoteToken_ != address(0), "INVALID_QUOTE_TOKEN");
        require(baseToken_ != quoteToken_, "IDENTICAL_TOKENS");

        IKYCRegistry registry = IPropertyTokenKYC(baseToken_).kycRegistry();
        if (address(registry) == address(0)) revert InvalidKYCRegistry();

        uint8 baseDecimals_ = IERC20Metadata(baseToken_).decimals();
        uint8 quoteDecimals_ = IERC20Metadata(quoteToken_).decimals();
        require(baseDecimals_ <= TOKEN_DECIMALS, "BASE_DECIMALS_GT_18");
        require(quoteDecimals_ <= TOKEN_DECIMALS, "QUOTE_DECIMALS_GT_18");

        baseToken = IERC20Metadata(baseToken_);
        quoteToken = IERC20Metadata(quoteToken_);
        kycRegistry = registry;
        baseTokenDecimals = baseDecimals_;
        quoteTokenDecimals = quoteDecimals_;
        baseTokenScale = 10 ** (TOKEN_DECIMALS - baseDecimals_);
        quoteTokenScale = 10 ** (TOKEN_DECIMALS - quoteDecimals_);
        buyingEnabled = true;
        sellingEnabled = true;
        rStatus = RStatus.ONE;
    }

    /// @notice Enable swaps once the pool is funded and valuation is clear.
    function enableTrading() external onlyOwner {
        require(!valuationCircuitBreakerTripped, "VALUATION_CIRCUIT_BREAKER_ACTIVE");
        require(baseBalance > 0 && quoteBalance > 0 && totalSupply() > 0, "POOL_NOT_FUNDED");
        emit TradingEnabledUpdated(tradingEnabled, true);
        tradingEnabled = true;
    }

    /// @notice Pause all swaps.
    function disableTrading() external onlySupervisorOrOwner {
        emit TradingEnabledUpdated(tradingEnabled, false);
        tradingEnabled = false;
    }

    /// @notice Enable base-token buys.
    function enableBuying() external onlyOwner {
        emit BuyingEnabledUpdated(buyingEnabled, true);
        buyingEnabled = true;
    }

    /// @notice Pause base-token buys.
    function disableBuying() external onlySupervisorOrOwner {
        emit BuyingEnabledUpdated(buyingEnabled, false);
        buyingEnabled = false;
    }

    /// @notice Enable base-token sells.
    function enableSelling() external onlyOwner {
        emit SellingEnabledUpdated(sellingEnabled, true);
        sellingEnabled = true;
    }

    /// @notice Pause base-token sells.
    function disableSelling() external onlySupervisorOrOwner {
        emit SellingEnabledUpdated(sellingEnabled, false);
        sellingEnabled = false;
    }

    /// @notice Recover excess or stray tokens without touching tracked reserves.
    function recoverToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(0), "INVALID_TOKEN");
        require(to != address(0), "INVALID_RECEIVER");

        if (token == address(baseToken)) {
            require(
                baseToken.balanceOf(address(this)) >= _baseTokenFromWadUp(baseBalance) + amount,
                "BASE_BALANCE_NOT_ENOUGH"
            );
        } else if (token == address(quoteToken)) {
            require(
                quoteToken.balanceOf(address(this))
                    >= _quoteTokenFromWadUp(quoteBalance) + totalPendingLpQuoteDividends + amount,
                "QUOTE_BALANCE_NOT_ENOUGH"
            );
        }

        require(IERC20(token).transfer(to, amount), "TOKEN_TRANSFER_FAILED");
        emit TokenRecovered(token, to, amount);
    }

    /// @notice Return pending quote-token dividends for this pool.
    function pendingQuoteDividends(address dividendDistributor, uint256 maxEpochs) external view returns (uint256) {
        require(dividendDistributor != address(0), "INVALID_DIVIDEND_DISTRIBUTOR");
        return IDividendDistributionMinimal(dividendDistributor).pendingDividends(address(this), maxEpochs);
    }

    /// @notice Claim quote-token dividends and account them to LP shares.
    function claimQuoteDividends(address dividendDistributor, uint256 maxEpochs)
        external
        onlyOwner
        nonReentrant
        returns (uint256 quoteAmount)
    {
        require(dividendDistributor != address(0), "INVALID_DIVIDEND_DISTRIBUTOR");
        IDividendDistributionMinimal distributor = IDividendDistributionMinimal(dividendDistributor);
        require(distributor.stablecoin() == address(quoteToken), "DIVIDEND_TOKEN_NOT_QUOTE");

        uint256 balanceBefore = quoteToken.balanceOf(address(this));
        distributor.claimDividends(maxEpochs);
        quoteAmount = quoteToken.balanceOf(address(this)) - balanceBefore;
        require(quoteAmount > 0, "NO_DIVIDEND_CLAIMED");

        _accountLpQuoteDividends(quoteAmount);

        emit QuoteDividendsClaimed(dividendDistributor, quoteAmount);
    }

    /// @notice Claim quote-token dividends earned by LP shares.
    function claimLpQuoteDividends() external nonReentrant returns (uint256 quoteAmount) {
        _checkLpAuthorized(msg.sender, true);
        quoteAmount = _claimLpQuoteDividends(msg.sender);
        require(quoteToken.transfer(msg.sender, quoteAmount), "QUOTE_TRANSFER_FAILED");
    }

    /// @notice Add liquidity and mint PMM LP shares.
    function provideLiquidity(uint256 baseAmountMax, uint256 quoteAmountMax, uint256 minShares)
        external
        nonReentrant
        returns (uint256 sharesMinted, uint256 baseAmount, uint256 quoteAmount)
    {
        require(baseAmountMax > 0 && quoteAmountMax > 0, "NO_LIQUIDITY");

        uint256 baseAmountMaxWad = _baseTokenToWad(baseAmountMax);
        uint256 quoteAmountMaxWad = _quoteTokenToWad(quoteAmountMax);
        uint256 baseAmountWad;
        uint256 quoteAmountWad;
        uint256 supply = totalSupply();
        if (supply == 0) {
            baseAmountWad = baseAmountMaxWad;
            quoteAmountWad = quoteAmountMaxWad;
            sharesMinted = FixedPointMathLib.sqrt(baseAmountWad * quoteAmountWad);
        } else {
            uint256 sharesFromBase = FixedPointMathLib.fullMulDiv(baseAmountMaxWad, supply, baseBalance);
            uint256 sharesFromQuote = FixedPointMathLib.fullMulDiv(quoteAmountMaxWad, supply, quoteBalance);
            sharesMinted = sharesFromBase < sharesFromQuote ? sharesFromBase : sharesFromQuote;
            baseAmountWad = FixedPointMathLib.fullMulDiv(sharesMinted, baseBalance, supply);
            quoteAmountWad = FixedPointMathLib.fullMulDiv(sharesMinted, quoteBalance, supply);
        }
        require(sharesMinted >= minShares, "INSUFFICIENT_SHARES");
        require(sharesMinted > 0 && baseAmountWad > 0 && quoteAmountWad > 0, "ZERO_SHARES");

        baseAmount = _baseTokenTransferIn(msg.sender, baseAmountWad);
        quoteAmount = _quoteTokenTransferIn(msg.sender, quoteAmountWad);
        if (supply == 0) {
            targetBaseTokenAmount += baseAmountWad;
            targetQuoteTokenAmount += quoteAmountWad;
        } else {
            targetBaseTokenAmount += FixedPointMathLib.fullMulDiv(targetBaseTokenAmount, sharesMinted, supply);
            targetQuoteTokenAmount += FixedPointMathLib.fullMulDiv(targetQuoteTokenAmount, sharesMinted, supply);
        }
        _mint(msg.sender, sharesMinted);

        emit LiquidityProvided(msg.sender, baseAmount, quoteAmount, sharesMinted);
    }

    /// @notice Burn PMM LP shares and withdraw proportional reserves.
    function withdrawLiquidity(uint256 sharesBurned, uint256 minBaseAmount, uint256 minQuoteAmount)
        external
        nonReentrant
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        require(sharesBurned > 0, "ZERO_SHARES");
        require(sharesBurned <= balanceOf(msg.sender), "INSUFFICIENT_SHARES");

        uint256 supply = totalSupply();
        uint256 baseTarget = targetBaseTokenAmount;
        uint256 quoteTarget = targetQuoteTokenAmount;
        uint256 baseAmountWad = FixedPointMathLib.fullMulDiv(baseBalance, sharesBurned, supply);
        uint256 quoteAmountWad = FixedPointMathLib.fullMulDiv(quoteBalance, sharesBurned, supply);
        baseAmount = _baseTokenFromWadDown(baseAmountWad);
        quoteAmount = _quoteTokenFromWadDown(quoteAmountWad);
        require(baseAmount >= minBaseAmount, "BASE_AMOUNT_NOT_ENOUGH");
        require(quoteAmount >= minQuoteAmount, "QUOTE_AMOUNT_NOT_ENOUGH");

        _burn(msg.sender, sharesBurned);
        if (totalSupply() == 0) {
            _resetEmptyPool();
        } else {
            targetBaseTokenAmount = baseTarget - FixedPointMathLib.fullMulDiv(baseTarget, sharesBurned, supply);
            targetQuoteTokenAmount = quoteTarget - FixedPointMathLib.fullMulDiv(quoteTarget, sharesBurned, supply);
        }
        _baseTokenTransferOut(msg.sender, baseAmountWad);
        _quoteTokenTransferOut(msg.sender, quoteAmountWad);

        emit LiquidityWithdrawn(msg.sender, baseAmount, quoteAmount, sharesBurned);
    }

    /// @notice Quote how much quote token a base-token sell would receive.
    function querySellBaseToken(uint256 amount) external view returns (uint256 receiveQuote) {
        SellQuote memory quote = PMMQuoter.querySellBaseToken(_poolState(), _getPricingState(), _baseTokenToWad(amount));
        return _quoteTokenFromWadDown(quote.receiveQuote);
    }

    /// @notice Quote how much quote token a base-token buy would cost.
    function queryBuyBaseToken(uint256 amount) external view returns (uint256 payQuote) {
        BuyQuote memory quote = PMMQuoter.queryBuyBaseToken(_poolState(), _getPricingState(), _baseTokenToWad(amount));
        return _quoteTokenFromWadUp(quote.payQuote) + _quoteTokenFromWadUp(quote.buyTaxQuote);
    }

    /// @notice Sell base token to the pool for quote token.
    function sellBaseToken(uint256 amount, uint256 minReceiveQuote)
        external
        nonReentrant
        whenTradingEnabled
        whenSellingEnabled
        returns (uint256 receiveQuote)
    {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 amountWad = _baseTokenToWad(amount);
        SellQuote memory quote = PMMQuoter.querySellBaseToken(_poolState(), _getPricingState(), amountWad);
        receiveQuote = _quoteTokenFromWadDown(quote.receiveQuote);
        require(receiveQuote >= minReceiveQuote, "SELL_BASE_RECEIVE_NOT_ENOUGH");

        _quoteTokenTransferOut(msg.sender, quote.receiveQuote);
        _baseTokenTransferIn(msg.sender, amountWad);
        _chargeSellFees(quote);
        _applySellState(quote);

        emit SellBaseToken(msg.sender, amount, receiveQuote);
    }

    /// @notice Buy base token from the pool with quote token.
    function buyBaseToken(uint256 amount, uint256 maxPayQuote)
        external
        nonReentrant
        whenTradingEnabled
        whenBuyingEnabled
        returns (uint256 totalPayQuote)
    {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 amountWad = _baseTokenToWad(amount);
        BuyQuote memory quote = PMMQuoter.queryBuyBaseToken(_poolState(), _getPricingState(), amountWad);
        totalPayQuote = _quoteTokenFromWadUp(quote.payQuote) + _quoteTokenFromWadUp(quote.buyTaxQuote);
        require(totalPayQuote <= maxPayQuote, "BUY_BASE_COST_TOO_MUCH");

        _baseTokenTransferOut(msg.sender, amountWad);
        _quoteTokenTransferIn(msg.sender, quote.payQuote);
        _chargeBuyFees(quote);
        _applyBuyState(quote);

        emit BuyBaseToken(msg.sender, amount, totalPayQuote);
    }

    /// @notice Return the PMM target reserves for the current inventory state.
    function getExpectedTarget() public view returns (uint256 baseTarget, uint256 quoteTarget) {
        if (rStatus == RStatus.ONE) {
            return (targetBaseTokenAmount, targetQuoteTokenAmount);
        }
        TargetState memory target = PMMQuoter.expectedTarget(_poolState(), _getPricingState());
        return (target.baseTarget, target.quoteTarget);
    }

    /// @notice Return the current PMM mid price.
    function getMidPrice() external view returns (uint256 midPrice) {
        return PMMQuoter.midPrice(_poolState(), _getPricingState());
    }

    function _update(address from, address to, uint256 value) internal override {
        _settleLpQuoteDividends(from);
        if (to != from) {
            _settleLpQuoteDividends(to);
        }

        if (from != address(0)) {
            _checkLpAuthorized(from, true);
        }
        if (to != address(0)) {
            _checkLpAuthorized(to, false);
        }

        super._update(from, to, value);

        _syncLpQuoteDividendDebt(from);
        if (to != from) {
            _syncLpQuoteDividendDebt(to);
        }
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

    function _onValuationCircuitBreaker() internal override {
        if (tradingEnabled) {
            emit TradingEnabledUpdated(tradingEnabled, false);
            tradingEnabled = false;
        }
    }

    function _lpTotalSupply() internal view override returns (uint256) {
        return totalSupply();
    }

    function _lpBalanceOf(address lp) internal view override returns (uint256) {
        return balanceOf(lp);
    }

    function _checkLpAuthorized(address account, bool isSender) internal view {
        if (kycRegistry.isApprovedContract(account)) {
            return;
        }

        if (!kycRegistry.isVerified(account)) {
            if (isSender) {
                revert SenderNotAuthorized(account);
            }
            revert RecipientNotAuthorized(account);
        }
    }

    function _chargeSellFees(SellQuote memory quote) internal {
        if (quote.maintainerFeeQuote > 0) {
            uint256 maintainerFee = _quoteTokenTransferOut(maintainer, quote.maintainerFeeQuote);
            emit ChargeMaintainerFee(maintainer, false, maintainerFee);
        }

        if (quote.sellTaxQuote > 0) {
            uint256 sellTax = _quoteTokenTransferOut(taxRecipient, quote.sellTaxQuote);
            emit ChargeTax(taxRecipient, sellTax, false);
        }
    }

    function _chargeBuyFees(BuyQuote memory quote) internal {
        if (quote.buyTaxQuote > 0) {
            uint256 buyTax = _quoteTokenTransferFrom(msg.sender, taxRecipient, quote.buyTaxQuote);
            emit ChargeTax(taxRecipient, buyTax, true);
        }

        if (quote.maintainerFeeBase > 0) {
            uint256 maintainerFee = _baseTokenTransferOut(maintainer, quote.maintainerFeeBase);
            emit ChargeMaintainerFee(maintainer, true, maintainerFee);
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

    function _baseTokenTransferIn(address from, uint256 amountWad) internal returns (uint256 amount) {
        amount = _baseTokenFromWadUp(amountWad);
        uint256 balanceBefore = baseToken.balanceOf(address(this));
        require(baseToken.transferFrom(from, address(this), amount), "BASE_TRANSFER_FROM_FAILED");
        uint256 received = baseToken.balanceOf(address(this)) - balanceBefore;
        require(received == amount, "BASE_TRANSFER_IN_MISMATCH");
        baseBalance += amountWad;
    }

    function _quoteTokenTransferIn(address from, uint256 amountWad) internal returns (uint256 amount) {
        amount = _quoteTokenFromWadUp(amountWad);
        uint256 balanceBefore = quoteToken.balanceOf(address(this));
        require(quoteToken.transferFrom(from, address(this), amount), "QUOTE_TRANSFER_FROM_FAILED");
        uint256 received = quoteToken.balanceOf(address(this)) - balanceBefore;
        require(received == amount, "QUOTE_TRANSFER_IN_MISMATCH");
        quoteBalance += amountWad;
    }

    function _baseTokenTransferOut(address to, uint256 amountWad) internal returns (uint256 amount) {
        amount = _baseTokenFromWadDown(amountWad);
        uint256 balanceBefore = baseToken.balanceOf(address(this));
        baseBalance -= amountWad;
        require(baseToken.transfer(to, amount), "BASE_TRANSFER_FAILED");
        require(balanceBefore - baseToken.balanceOf(address(this)) == amount, "BASE_TRANSFER_OUT_MISMATCH");
    }

    function _quoteTokenTransferOut(address to, uint256 amountWad) internal returns (uint256 amount) {
        amount = _quoteTokenFromWadDown(amountWad);
        uint256 balanceBefore = quoteToken.balanceOf(address(this));
        quoteBalance -= amountWad;
        require(quoteToken.transfer(to, amount), "QUOTE_TRANSFER_FAILED");
        require(balanceBefore - quoteToken.balanceOf(address(this)) == amount, "QUOTE_TRANSFER_OUT_MISMATCH");
    }

    function _quoteTokenTransferFrom(address from, address to, uint256 amountWad) internal returns (uint256 amount) {
        amount = _quoteTokenFromWadUp(amountWad);
        require(quoteToken.transferFrom(from, to, amount), "QUOTE_TRANSFER_FROM_FAILED");
    }

    function _baseTokenToWad(uint256 amount) internal view returns (uint256) {
        return amount * baseTokenScale;
    }

    function _quoteTokenToWad(uint256 amount) internal view returns (uint256) {
        return amount * quoteTokenScale;
    }

    function _baseTokenFromWadDown(uint256 amountWad) internal view returns (uint256) {
        return amountWad / baseTokenScale;
    }

    function _quoteTokenFromWadDown(uint256 amountWad) internal view returns (uint256) {
        return amountWad / quoteTokenScale;
    }

    function _baseTokenFromWadUp(uint256 amountWad) internal view returns (uint256) {
        return FixedPointMathLib.divUp(amountWad, baseTokenScale);
    }

    function _quoteTokenFromWadUp(uint256 amountWad) internal view returns (uint256) {
        return FixedPointMathLib.divUp(amountWad, quoteTokenScale);
    }
}
