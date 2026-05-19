// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MinimalDodoPMM} from "../../../src/amm/MinimalDodoPMM.sol";
import {IERC20Minimal} from "../../../src/amm/interfaces/IERC20Minimal.sol";
import {RStatus} from "../../../src/amm/types/PMMTypes.sol";

contract MockERC20 is IERC20Minimal {
    string public name;
    string public symbol;
    uint8 public immutable DECIMALS;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        DECIMALS = decimals_;
    }

    function decimals() external view returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

}

abstract contract AMMTestBase is Test {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant INITIAL_BASE = 10 * ONE;
    uint256 internal constant INITIAL_QUOTE = 1000 * ONE;
    uint256 internal constant INITIAL_PRICE = 100 * ONE;
    uint256 internal constant DEFAULT_LP_FEE = 2e15;
    uint256 internal constant DEFAULT_MAINTAINER_FEE = 1e15;
    uint256 internal constant DEFAULT_K = 1e17;

    MockERC20 internal base;
    MockERC20 internal quote;
    MockERC20 internal stray;
    MinimalDodoPMM internal pool;

    address internal lpProvider = address(0x1000);
    address internal supervisor = address(0x1001);
    address internal maintainer = address(0x1002);
    address internal trader = address(0x1003);
    address internal taxRecipient = address(0x1004);
    address internal lpReceiver = address(0x1005);
    address internal outsider = address(0x1006);
    address internal secondProvider = address(0x1007);
    address internal thirdProvider = address(0x1008);

    function setUp() public virtual {
        _deployDefaultPool();
        _seedInitialLiquidity();
        _mintAndApprove(trader, 10 * ONE, 1000 * ONE);
    }

    function _deployDefaultPool() internal {
        base = new MockERC20("Base", "BASE", 18);
        quote = new MockERC20("Quote", "QUOTE", 18);
        stray = new MockERC20("Stray", "STRAY", 18);

        pool = new MinimalDodoPMM(
            address(this),
            supervisor,
            maintainer,
            address(base),
            address(quote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            "Modern DODO LP",
            "mDLP"
        );
    }

    function _seedInitialLiquidity() internal {
        _mintAndApprove(lpProvider, INITIAL_BASE, INITIAL_QUOTE);
        vm.startPrank(lpProvider);
        pool.provideLiquidity(INITIAL_BASE, INITIAL_QUOTE, 0);
        vm.stopPrank();
        pool.enableTrading();
    }

    function _mintAndApprove(address user, uint256 baseAmount, uint256 quoteAmount) internal {
        base.mint(user, baseAmount);
        quote.mint(user, quoteAmount);

        vm.startPrank(user);
        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _newPoolWithTokens(address baseToken_, address quoteToken_, address maintainer_)
        internal
        returns (MinimalDodoPMM)
    {
        return new MinimalDodoPMM(
            address(this),
            supervisor,
            maintainer_,
            baseToken_,
            quoteToken_,
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            "Bad",
            "BAD"
        );
    }

    function _assertTrackedBalancesAtMostActual() internal {
        assertLe(pool.baseBalance(), base.balanceOf(address(pool)));
        assertLe(pool.quoteBalance(), quote.balanceOf(address(pool)));
    }

    function _assertEmptyPoolState() internal {
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.baseBalance(), 0);
        assertEq(pool.quoteBalance(), 0);
        assertEq(pool.targetBaseTokenAmount(), 0);
        assertEq(pool.targetQuoteTokenAmount(), 0);
        assertEq(uint256(pool.rStatus()), uint256(RStatus.ONE));
        assertFalse(pool.tradingEnabled());
    }

    function _actorSet() internal view returns (address[] memory actors) {
        actors = new address[](7);
        actors[0] = lpProvider;
        actors[1] = trader;
        actors[2] = lpReceiver;
        actors[3] = secondProvider;
        actors[4] = thirdProvider;
        actors[5] = taxRecipient;
        actors[6] = maintainer;
    }

    function _sumLpBalances(address[] memory actors) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.balanceOf(actors[i]);
        }
    }
}
