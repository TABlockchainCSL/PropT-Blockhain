// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {RStatus} from "../../src/amm/types/PMMTypes.sol";
import {AMMTestBase, MockERC20} from "./helpers/AMMTestBase.sol";

contract PropertyPMMHandler is Test {
    uint256 internal constant ONE = 1e18;

    PropertyPMM public pool;
    MockERC20 public base;
    MockERC20 public quote;

    address public owner;
    address public supervisor;
    address public maintainer;
    address public taxRecipient;
    address[] public actors;

    uint256 public provideCalls;
    uint256 public withdrawCalls;
    uint256 public buyCalls;
    uint256 public sellCalls;
    uint256 public transferCalls;
    uint256 public configCalls;
    uint256 public valuationCalls;
    uint256 public pauseCalls;

    constructor(
        PropertyPMM pool_,
        MockERC20 base_,
        MockERC20 quote_,
        address owner_,
        address supervisor_,
        address maintainer_,
        address taxRecipient_,
        address[] memory actors_
    ) {
        pool = pool_;
        base = base_;
        quote = quote_;
        owner = owner_;
        supervisor = supervisor_;
        maintainer = maintainer_;
        taxRecipient = taxRecipient_;
        actors = actors_;
    }

    function provideLiquidity(uint256 actorSeed, uint96 rawBaseAmount, uint96 rawQuoteAmount) external {
        provideCalls++;
        if (pool.totalSupply() == 0 || pool.rStatus() != RStatus.ONE) {
            return;
        }

        address actor = _actor(actorSeed);
        uint256 baseAmount = bound(uint256(rawBaseAmount), 1e12, 5 * ONE);
        uint256 quoteAmount = bound(uint256(rawQuoteAmount), 1e12, 500 * ONE);
        base.mint(actor, baseAmount);
        quote.mint(actor, quoteAmount);

        vm.startPrank(actor);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        try pool.provideLiquidity(baseAmount, quoteAmount, 0) {} catch {}
        vm.stopPrank();
    }

    function withdrawLiquidity(uint256 actorSeed, uint96 rawShares) external {
        withdrawCalls++;
        address actor = _actor(actorSeed);
        uint256 balance = pool.balanceOf(actor);
        if (balance == 0) {
            return;
        }

        uint256 shares = bound(uint256(rawShares), 1, balance);
        vm.prank(actor);
        try pool.withdrawLiquidity(shares, 0, 0) {} catch {}
    }

    function buyBaseToken(uint256 actorSeed, uint96 rawAmount) external {
        buyCalls++;
        if (!pool.tradingEnabled() || !pool.buyingEnabled() || pool.baseBalance() <= 2) {
            return;
        }

        address actor = _actor(actorSeed);
        uint256 amount = bound(uint256(rawAmount), 1, _min(pool.baseBalance() / 4, ONE));
        try pool.queryBuyBaseToken(amount) returns (uint256 maxPayQuote) {
            quote.mint(actor, maxPayQuote);
            vm.startPrank(actor);
            quote.approve(address(pool), type(uint256).max);
            try pool.buyBaseToken(amount, maxPayQuote) {} catch {}
            vm.stopPrank();
        } catch {}
    }

    function sellBaseToken(uint256 actorSeed, uint96 rawAmount) external {
        sellCalls++;
        if (!pool.tradingEnabled() || !pool.sellingEnabled() || pool.quoteBalance() == 0) {
            return;
        }

        address actor = _actor(actorSeed);
        uint256 amount = bound(uint256(rawAmount), 1, ONE);
        try pool.querySellBaseToken(amount) returns (uint256 minReceiveQuote) {
            base.mint(actor, amount);
            vm.startPrank(actor);
            base.approve(address(pool), type(uint256).max);
            try pool.sellBaseToken(amount, minReceiveQuote) {} catch {}
            vm.stopPrank();
        } catch {}
    }

    function transferLp(uint256 fromSeed, uint256 toSeed, uint96 rawAmount) external {
        transferCalls++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = pool.balanceOf(from);
        if (balance == 0 || to == address(0)) {
            return;
        }

        uint256 amount = bound(uint256(rawAmount), 1, balance);
        vm.prank(from);
        try pool.transfer(to, amount) {} catch {}
    }

    function updateValuation(uint96 rawPrice, uint64 rawAge) external {
        valuationCalls++;
        uint256 price = bound(uint256(rawPrice), 1, 1000 * ONE);
        uint256 maxAge = _min(pool.valuationMaxStaleness(), block.timestamp);
        uint256 age = maxAge == 0 ? 0 : bound(uint256(rawAge), 0, maxAge);
        vm.prank(owner);
        pool.setValuationPriceWithTimestamp(price, block.timestamp - age);
    }

    function updateFeesAndTaxes(uint96 rawLpFee, uint96 rawMaintFee, uint96 rawTaxFee) external {
        configCalls++;
        uint256 newLpFee = bound(uint256(rawLpFee), 0, 5e16);
        uint256 newMaintFee = bound(uint256(rawMaintFee), 0, 5e16);
        uint256 newTaxFee = bound(uint256(rawTaxFee), 0, 5e16);

        vm.startPrank(owner);
        pool.setMaintainer(maintainer);
        pool.setLpFeeRate(newLpFee);
        pool.setMaintainerFeeRate(newMaintFee);
        pool.setTaxRecipient(taxRecipient);
        pool.setBuyTaxRate(newTaxFee);
        pool.setSellTaxRate(newTaxFee);
        if (!pool.taxEnabled()) {
            pool.enableTax();
        }
        vm.stopPrank();
    }

    function toggleTrading(uint8 rawMode) external {
        pauseCalls++;
        uint8 mode = uint8(bound(uint256(rawMode), 0, 5));
        if (mode == 0) {
            vm.prank(supervisor);
            try pool.disableTrading() {} catch {}
        } else if (mode == 1) {
            vm.prank(owner);
            try pool.enableTrading() {} catch {}
        } else if (mode == 2) {
            vm.prank(supervisor);
            try pool.disableBuying() {} catch {}
        } else if (mode == 3) {
            vm.prank(owner);
            try pool.enableBuying() {} catch {}
        } else if (mode == 4) {
            vm.prank(supervisor);
            try pool.disableSelling() {} catch {}
        } else {
            vm.prank(owner);
            try pool.enableSelling() {} catch {}
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function _actor(uint256 actorSeed) internal view returns (address) {
        return actors[bound(actorSeed, 0, actors.length - 1)];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract PropertyPMMInvariantTest is AMMTestBase {
    PropertyPMMHandler internal handler;

    function setUp() public override {
        vm.warp(365 days);
        super.setUp();

        address[] memory actors = _actorSet();
        handler = new PropertyPMMHandler(pool, base, quote, address(this), supervisor, maintainer, taxRecipient, actors);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.provideLiquidity.selector;
        selectors[1] = handler.withdrawLiquidity.selector;
        selectors[2] = handler.buyBaseToken.selector;
        selectors[3] = handler.sellBaseToken.selector;
        selectors[4] = handler.transferLp.selector;
        selectors[5] = handler.updateValuation.selector;
        selectors[6] = handler.updateFeesAndTaxes.selector;
        selectors[7] = handler.toggleTrading.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantTrackedBalancesNeverExceedActualBalances() public {
        _assertTrackedBalancesAtMostActual();
    }

    function invariantEmptyPoolStateIsReset() public {
        if (pool.totalSupply() == 0) {
            _assertEmptyPoolState();
        }
    }

    function invariantNonEmptyPoolHasTrackedReserves() public {
        if (pool.totalSupply() > 0) {
            assertGt(pool.baseBalance(), 0);
            assertGt(pool.quoteBalance(), 0);
        }
    }

    function invariantFeeAndKParametersStayWithinBounds() public {
        assertGt(pool.k(), 0);
        assertLt(pool.k(), ONE);
        assertLt(pool.buyTaxRate(), ONE);
        assertLt(pool.lpFeeRate() + pool.maintainerFeeRate() + pool.sellTaxRate(), ONE);
    }

    function invariantActorLpBalancesSumToTotalSupply() public {
        assertEq(_sumLpBalances(_actorSet()), pool.totalSupply());
    }

    function invariantQueriesAreBoundedWhenTheySucceed() public {
        if (pool.totalSupply() == 0) {
            return;
        }

        uint256 buyAmount = _min(pool.baseBalance() / 10, ONE);
        if (buyAmount > 0) {
            try pool.queryBuyBaseToken(buyAmount) returns (uint256 payQuote) {
                if (pool.getValuationPrice() >= ONE) {
                    assertGt(payQuote, 0);
                }
            } catch {}
        }

        uint256 sellAmount = ONE;
        try pool.querySellBaseToken(sellAmount) returns (uint256 receiveQuote) {
            assertLe(receiveQuote, pool.quoteBalance());
        } catch {}
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
