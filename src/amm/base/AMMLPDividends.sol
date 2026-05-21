// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title AMMLPDividends
/// @notice Pull-based quote-token dividend accounting for PMM LP shares.
abstract contract AMMLPDividends {
    uint256 internal constant LP_DIVIDEND_PRECISION = 1e18;

    /// @notice Accumulated quote dividends per LP share.
    uint256 public accQuoteDividendPerShare;
    /// @notice Quote tokens reserved for LP dividend claims.
    uint256 public totalPendingLpQuoteDividends;

    /// @notice Per-account accumulator already counted for the LP.
    mapping(address => uint256) public lpDividendDebt;
    /// @notice Per-account quote dividends stored during LP balance changes.
    mapping(address => uint256) public lpAccruedQuoteDividends;

    event LpQuoteDividendsAccounted(
        uint256 quoteAmount, uint256 accountedAmount, uint256 totalShares, uint256 accQuoteDividendPerShare
    );
    event LpQuoteDividendsClaimed(address indexed lp, uint256 amount);

    /// @notice Return claimable quote dividends for an LP.
    function pendingLpQuoteDividends(address lp) public view returns (uint256) {
        uint256 accumulated = _accumulatedLpQuoteDividends(lp);
        uint256 debt = lpDividendDebt[lp];
        uint256 unsettled = accumulated > debt ? accumulated - debt : 0;
        return lpAccruedQuoteDividends[lp] + unsettled;
    }

    /// @dev Account fresh quote dividends against current LP supply.
    function _accountLpQuoteDividends(uint256 quoteAmount) internal {
        uint256 supply = _lpTotalSupply();
        require(supply > 0, "NO_LP_SUPPLY");

        uint256 dividendPerShare = FixedPointMathLib.fullMulDiv(quoteAmount, LP_DIVIDEND_PRECISION, supply);
        require(dividendPerShare > 0, "LP_DIVIDEND_TOO_SMALL");

        uint256 accountedAmount = FixedPointMathLib.fullMulDiv(dividendPerShare, supply, LP_DIVIDEND_PRECISION);
        accQuoteDividendPerShare += dividendPerShare;
        totalPendingLpQuoteDividends += accountedAmount;

        emit LpQuoteDividendsAccounted(quoteAmount, accountedAmount, supply, accQuoteDividendPerShare);
    }

    /// @dev Move generated dividends into stored accrued balance before LP balance changes.
    function _settleLpQuoteDividends(address lp) internal {
        if (lp == address(0)) {
            return;
        }

        uint256 accumulated = _accumulatedLpQuoteDividends(lp);
        uint256 debt = lpDividendDebt[lp];
        if (accumulated > debt) {
            lpAccruedQuoteDividends[lp] += accumulated - debt;
        }
        lpDividendDebt[lp] = accumulated;
    }

    /// @dev Sync debt after mint, burn, or transfer changes the LP balance.
    function _syncLpQuoteDividendDebt(address lp) internal {
        if (lp != address(0)) {
            lpDividendDebt[lp] = _accumulatedLpQuoteDividends(lp);
        }
    }

    /// @dev Settle and clear the caller's claimable quote dividend amount.
    function _claimLpQuoteDividends(address lp) internal returns (uint256 amount) {
        _settleLpQuoteDividends(lp);
        amount = lpAccruedQuoteDividends[lp];
        require(amount > 0, "NO_LP_DIVIDEND");

        lpAccruedQuoteDividends[lp] = 0;
        totalPendingLpQuoteDividends -= amount;

        emit LpQuoteDividendsClaimed(lp, amount);
    }

    function _accumulatedLpQuoteDividends(address lp) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(_lpBalanceOf(lp), accQuoteDividendPerShare, LP_DIVIDEND_PRECISION);
    }

    function _lpTotalSupply() internal view virtual returns (uint256);

    function _lpBalanceOf(address lp) internal view virtual returns (uint256);
}
