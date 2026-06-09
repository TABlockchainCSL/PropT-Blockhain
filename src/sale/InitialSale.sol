// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title InitialSale
/// @notice Fixed-price primary sale for one PropertyToken paid with an ERC20 payment token.
/// @dev pricePerToken is quoted in payment-token units per 1e18 property-token units.
contract InitialSale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PROPERTY_TOKEN_UNIT = 1e18;

    IERC20 public immutable propertyToken;
    IERC20 public immutable paymentToken;
    uint256 public immutable pricePerToken;

    address public treasury;
    uint256 public tokensAvailable;
    uint256 public totalTokensSold;
    uint256 public totalPaymentCollected;
    bool public saleActive;

    event TokensDeposited(address indexed seller, uint256 amount);
    event TokensPurchased(address indexed buyer, uint256 tokenAmount, uint256 paymentAmount);
    event UnsoldTokensWithdrawn(address indexed to, uint256 amount);
    event ProceedsWithdrawn(address indexed treasury, uint256 amount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SaleActiveUpdated(bool oldValue, bool newValue);

    error ZeroAddress();
    error IdenticalTokens();
    error InvalidAmount();
    error InvalidPrice();
    error ZeroPayment();
    error SaleInactive();
    error SaleActive();
    error InsufficientInventory(uint256 requested, uint256 available);
    error InsufficientProceeds(uint256 requested, uint256 available);

    constructor(
        address propertyToken_,
        address paymentToken_,
        address treasury_,
        uint256 pricePerToken_,
        address owner_
    ) Ownable(owner_) {
        if (propertyToken_ == address(0) || paymentToken_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (propertyToken_ == paymentToken_) revert IdenticalTokens();
        if (pricePerToken_ == 0) revert InvalidPrice();

        propertyToken = IERC20(propertyToken_);
        paymentToken = IERC20(paymentToken_);
        treasury = treasury_;
        pricePerToken = pricePerToken_;
        saleActive = true;

        // Delegate the sale's voting units to the treasury so that dividends accruing
        // to unsold inventory are claimable by the issuer instead of being stranded in
        // DividendDistribution (which snapshots getPastVotes). As inventory sells, the
        // voting units transfer with the tokens, so the treasury's claimable share
        // always tracks the remaining unsold balance.
        IVotes(propertyToken_).delegate(treasury_);
    }

    /// @notice Returns the payment-token amount needed to buy a property-token amount.
    function quote(uint256 propertyTokenAmount) public view returns (uint256) {
        return Math.mulDiv(propertyTokenAmount, pricePerToken, PROPERTY_TOKEN_UNIT);
    }

    /// @notice Returns the current payment-token value of all unsold sale inventory.
    function remainingSaleValue() external view returns (uint256) {
        return quote(tokensAvailable);
    }

    /// @notice Returns payment-token proceeds currently held by the sale.
    function availableProceeds() external view returns (uint256) {
        return paymentToken.balanceOf(address(this));
    }

    /// @notice Deposit a specific amount of property tokens into sale inventory.
    function deposit(uint256 amount) external onlyOwner nonReentrant {
        _deposit(amount);
    }

    /// @notice Deposit the owner's whole current property-token balance into sale inventory.
    function depositAll() external onlyOwner nonReentrant returns (uint256 amount) {
        amount = propertyToken.balanceOf(msg.sender);
        _deposit(amount);
    }

    /// @notice Buy property tokens at the configured fixed price.
    function buy(uint256 amount) external nonReentrant returns (uint256 paymentAmount) {
        if (!saleActive) revert SaleInactive();
        if (amount == 0) revert InvalidAmount();
        if (amount > tokensAvailable) revert InsufficientInventory(amount, tokensAvailable);
        // Buyer KYC is enforced by PropertyToken._update on the safeTransfer below
        // (reverts RecipientNotAuthorized for a non-verified buyer), so we skip a
        // redundant isVerified() external call on every purchase.

        paymentAmount = quote(amount);
        if (paymentAmount == 0) revert ZeroPayment();

        tokensAvailable -= amount;
        totalTokensSold += amount;
        totalPaymentCollected += paymentAmount;

        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        propertyToken.safeTransfer(msg.sender, amount);

        emit TokensPurchased(msg.sender, amount, paymentAmount);
    }

    /// @notice Withdraw a specific amount of collected payment tokens to treasury.
    function withdrawProceeds(uint256 amount) external onlyOwner nonReentrant {
        _withdrawProceeds(amount);
    }

    /// @notice Withdraw all collected payment tokens to treasury.
    function withdrawAllProceeds() external onlyOwner nonReentrant returns (uint256 amount) {
        amount = paymentToken.balanceOf(address(this));
        _withdrawProceeds(amount);
    }

    /// @notice Withdraw unsold property tokens after the sale has been paused or closed.
    function withdrawUnsold(address to, uint256 amount) external onlyOwner nonReentrant {
        if (saleActive) revert SaleActive();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (amount > tokensAvailable) revert InsufficientInventory(amount, tokensAvailable);

        // Recipient authorization (KYC-verified or approved contract) is enforced by
        // PropertyToken._update on the transfer below.
        tokensAvailable -= amount;
        propertyToken.safeTransfer(to, amount);

        emit UnsoldTokensWithdrawn(to, amount);
    }

    /// @notice Update the treasury address used by proceeds withdrawals.
    /// @dev Re-delegates the sale's voting units to the new treasury so unsold-inventory
    ///      dividends keep flowing to the current issuer address.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        IVotes(address(propertyToken)).delegate(newTreasury);
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /// @notice Pause or resume purchases.
    function setSaleActive(bool active) external onlyOwner {
        bool oldValue = saleActive;
        saleActive = active;
        emit SaleActiveUpdated(oldValue, active);
    }

    function _deposit(uint256 amount) private {
        if (amount == 0) revert InvalidAmount();

        // The property token must list this sale as an approved contract for the
        // inbound transfer to succeed; PropertyToken._update enforces that and
        // reverts here otherwise, so no explicit registry check is needed.
        tokensAvailable += amount;
        propertyToken.safeTransferFrom(msg.sender, address(this), amount);

        emit TokensDeposited(msg.sender, amount);
    }

    function _withdrawProceeds(uint256 amount) private {
        if (amount == 0) revert InvalidAmount();

        uint256 available = paymentToken.balanceOf(address(this));
        if (amount > available) revert InsufficientProceeds(amount, available);

        paymentToken.safeTransfer(treasury, amount);

        emit ProceedsWithdrawn(treasury, amount);
    }
}
