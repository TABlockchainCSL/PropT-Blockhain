// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/StdUtils.sol";
import "forge-std/StdCheats.sol";
import "forge-std/Base.sol";

import {InitialSale} from "../../src/sale/InitialSale.sol";
import {PropertyToken} from "../../src/core/PropertyToken.sol";
import {TestnetERC20} from "../../src/amm/testnet/TestnetERC20.sol";

/// @title InitialSaleHandler
/// @notice Mediates fuzzer calls to InitialSale so invariant runs exercise a realistic
///         action space: owner deposits, KYC-verified buys by several actors, proceeds
///         withdrawals, pause/resume, and unsold withdrawals. Tracks ghost totals the
///         invariants read to prove solvency and accounting conservation.
contract InitialSaleHandler is CommonBase, StdCheats, StdUtils {
    InitialSale public immutable sale;
    PropertyToken public immutable propertyToken;
    TestnetERC20 public immutable paymentToken;
    address public immutable owner;

    address[] internal _buyers;

    // --- Ghost state (read by invariant assertions) ---
    uint256 public ghostDeposited; // cumulative tokens deposited into inventory
    uint256 public ghostWithdrawnUnsold; // cumulative unsold tokens pulled back out
    uint256 public ghostPaymentIn; // cumulative payment collected from buys
    uint256 public ghostPaymentOut; // cumulative proceeds withdrawn to treasury

    constructor(
        InitialSale _sale,
        PropertyToken _propertyToken,
        TestnetERC20 _paymentToken,
        address _owner,
        address[] memory buyers
    ) {
        sale = _sale;
        propertyToken = _propertyToken;
        paymentToken = _paymentToken;
        owner = _owner;
        _buyers = buyers;
    }

    function deposit(uint256 amount) external {
        uint256 ownerBal = propertyToken.balanceOf(owner);
        if (ownerBal == 0) return;
        amount = bound(amount, 1, ownerBal);

        vm.prank(owner);
        sale.deposit(amount);
        ghostDeposited += amount;
    }

    function buy(uint256 actorSeed, uint256 amount) external {
        uint256 available = sale.tokensAvailable();
        if (available == 0 || !sale.saleActive()) return;
        // Stay above the rounding floor so quote() never returns zero.
        if (available < 1e10) return;
        amount = bound(amount, 1e10, available);

        address buyer = _buyers[actorSeed % _buyers.length];
        uint256 pay = sale.quote(amount);
        if (pay == 0) return;

        vm.prank(buyer);
        sale.buy(amount);
        ghostPaymentIn += pay;
    }

    function withdrawProceeds(uint256 amount) external {
        uint256 avail = paymentToken.balanceOf(address(sale));
        if (avail == 0) return;
        amount = bound(amount, 1, avail);

        vm.prank(owner);
        sale.withdrawProceeds(amount);
        ghostPaymentOut += amount;
    }

    function withdrawUnsold(uint256 amount) external {
        if (sale.saleActive()) return; // only allowed while paused
        uint256 available = sale.tokensAvailable();
        if (available == 0) return;
        amount = bound(amount, 1, available);

        vm.prank(owner);
        sale.withdrawUnsold(owner, amount);
        ghostWithdrawnUnsold += amount;
    }

    function setSaleActive(bool active) external {
        vm.prank(owner);
        sale.setSaleActive(active);
    }
}
