// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PropertyPMM} from "../../src/amm/PropertyPMM.sol";
import {AMMConfig} from "../../src/amm/base/AMMConfig.sol";
import {AMMRoles} from "../../src/amm/base/AMMRoles.sol";
import {TestnetERC20} from "../../src/amm/testnet/TestnetERC20.sol";
import {PMMQuoter} from "../../src/amm/libraries/PMMQuoter.sol";
import {BuyQuote, PoolState, PricingState, RStatus, SellQuote} from "../../src/amm/types/PMMTypes.sol";
import {AMMTestBase} from "./helpers/AMMTestBase.sol";

// Harnesses used only to exercise internal/library and failure-only branches.
contract AMMConfigHarness is AMMConfig {
    constructor(address owner_, address supervisor_, address maintainer_, uint256 initialValuationPrice_)
        AMMConfig(owner_, supervisor_, maintainer_, initialValuationPrice_, 2e15, 1e15, 1e17)
    {}

    function setRawValuation(uint256 price, uint256 updatedAt) external {
        valuationPrice = price;
        valuationUpdatedAt = updatedAt;
    }

    function validatedValuation() external view returns (uint256 price, uint256 updatedAt) {
        return _getValidatedValuation();
    }
}

contract AMMRolesHarness is AMMRoles {
    constructor(address owner_, address supervisor_) AMMRoles(owner_, supervisor_) {}

    function ownerOnly() external onlyOwner {}

    function supervisorOrOwnerOnly() external onlySupervisorOrOwner {}

    function catchesOwnerOnlyRevert() external returns (bool) {
        (bool ok,) = address(this).call(abi.encodeCall(this.ownerOnly, ()));
        return ok;
    }
}

contract ConfigurableERC20 {
    enum Behavior {
        Normal,
        ReturnFalse,
        TransferLess
    }

    string public name;
    string public symbol;
    uint8 public constant DECIMALS = 18;
    address public kycRegistry;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    Behavior public transferBehavior;
    Behavior public transferFromBehavior;
    address public failTransferFromTo;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function setKycRegistry(address newKycRegistry) external {
        kycRegistry = newKycRegistry;
    }

    function setTransferBehavior(Behavior behavior) external {
        transferBehavior = behavior;
    }

    function setTransferFromBehavior(Behavior behavior) external {
        transferFromBehavior = behavior;
    }

    function setFailTransferFromTo(address to) external {
        failTransferFromTo = to;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (transferBehavior == Behavior.ReturnFalse) {
            return false;
        }

        uint256 sent = transferBehavior == Behavior.TransferLess ? amount - 1 : amount;
        balanceOf[msg.sender] -= sent;
        balanceOf[to] += sent;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == failTransferFromTo || transferFromBehavior == Behavior.ReturnFalse) {
            return false;
        }

        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        uint256 received = transferFromBehavior == Behavior.TransferLess ? amount - 1 : amount;
        balanceOf[from] -= amount;
        balanceOf[to] += received;
        return true;
    }
}

contract PMMQuoterHarness {
    function querySellBaseToken(PoolState memory pool, PricingState memory pricing, uint256 amount)
        external
        pure
        returns (SellQuote memory)
    {
        return PMMQuoter.querySellBaseToken(pool, pricing, amount);
    }

    function queryBuyBaseToken(PoolState memory pool, PricingState memory pricing, uint256 amount)
        external
        pure
        returns (BuyQuote memory)
    {
        return PMMQuoter.queryBuyBaseToken(pool, pricing, amount);
    }
}

// PMM edge cases that would make the main unit suite noisy.
contract PropertyPMMEdgeCasesTest is AMMTestBase {
    PMMQuoterHarness internal quoter;

    function setUp() public override {
        super.setUp();
        quoter = new PMMQuoterHarness();
    }

    function testRoleManagementAndConstructorGuards() public {
        vm.expectRevert(bytes("INVALID_OWNER"));
        new PropertyPMM(
            address(0),
            supervisor,
            maintainer,
            address(base),
            address(quote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            "Bad",
            "BAD"
        );

        vm.expectRevert(bytes("INVALID_BASE_TOKEN"));
        new PropertyPMM(
            address(this),
            supervisor,
            maintainer,
            address(0),
            address(quote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            "Bad",
            "BAD"
        );

        vm.expectRevert(bytes("INVALID_QUOTE_TOKEN"));
        new PropertyPMM(
            address(this),
            supervisor,
            maintainer,
            address(base),
            address(0),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            "Bad",
            "BAD"
        );

        vm.expectRevert(bytes("INVALID_OWNER"));
        pool.transferOwnership(address(0));

        pool.transferOwnership(secondProvider);
        assertEq(pool.owner(), secondProvider);

        vm.prank(secondProvider);
        pool.setSupervisor(outsider);
        assertEq(pool.supervisor(), outsider);

        vm.prank(secondProvider);
        pool.disableTrading();
        assertFalse(pool.tradingEnabled());
    }

    function testEnableTradingRequiresFundedPool() public {
        PropertyPMM freshPool = _newPoolWithTokens(address(base), address(quote), maintainer);

        vm.expectRevert(bytes("POOL_NOT_FUNDED"));
        freshPool.enableTrading();
    }

    function testUnbalancedTargetAndMidPriceBranches() public {
        uint256 buyQuote = pool.queryBuyBaseToken(ONE);

        vm.prank(trader);
        pool.buyBaseToken(ONE, buyQuote);

        (uint256 aboveBaseTarget, uint256 aboveQuoteTarget) = pool.getExpectedTarget();
        assertGt(aboveBaseTarget, pool.baseBalance());
        assertEq(aboveQuoteTarget, pool.targetQuoteTokenAmount());

        _deployDefaultPool();
        _seedInitialLiquidity();
        _mintAndApprove(trader, 10 * ONE, 1000 * ONE);

        uint256 midPriceBefore = pool.getMidPrice();
        uint256 sellQuote = pool.querySellBaseToken(ONE);

        vm.prank(trader);
        pool.sellBaseToken(ONE, sellQuote);

        (uint256 belowBaseTarget, uint256 belowQuoteTarget) = pool.getExpectedTarget();
        assertEq(belowBaseTarget, pool.targetBaseTokenAmount());
        assertGt(belowQuoteTarget, pool.quoteBalance());
        assertLt(pool.getMidPrice(), midPriceBefore);
    }

    function testExactRebalanceQuoteBranches() public {
        uint256 buyQuote = pool.queryBuyBaseToken(ONE);

        vm.prank(trader);
        pool.buyBaseToken(ONE, buyQuote);

        (uint256 aboveBaseTarget,) = pool.getExpectedTarget();
        uint256 sellBackToOneAmount = aboveBaseTarget - pool.baseBalance();
        assertGt(pool.querySellBaseToken(sellBackToOneAmount), 0);

        _deployDefaultPool();
        _seedInitialLiquidity();
        _mintAndApprove(trader, 10 * ONE, 1000 * ONE);
        pool.setLpFeeRate(0);
        pool.setMaintainerFeeRate(0);

        uint256 sellQuote = pool.querySellBaseToken(ONE);
        vm.prank(trader);
        pool.sellBaseToken(ONE, sellQuote);

        (uint256 belowBaseTarget,) = pool.getExpectedTarget();
        uint256 buyBackToOneAmount = pool.baseBalance() - belowBaseTarget;
        assertGt(pool.queryBuyBaseToken(buyBackToOneAmount), 0);
    }

    function testQuoterClampAndInvalidTaxRecipientBranches() public {
        PoolState memory abovePool = PoolState({
            rStatus: RStatus.ABOVE_ONE,
            baseBalance: 10 * ONE,
            quoteBalance: 1001 * ONE,
            targetBaseTokenAmount: 10 * ONE,
            targetQuoteTokenAmount: 1000 * ONE,
            lpFeeRate: 0,
            maintainerFeeRate: 0,
            buyTaxRate: 0,
            sellTaxRate: 0,
            taxEnabled: false,
            taxRecipient: address(0)
        });
        PricingState memory pricing = PricingState({price: ONE, effectiveK: 9e17});

        SellQuote memory clampedQuote = quoter.querySellBaseToken(abovePool, pricing, 923_279_883_161_444_969);
        assertEq(clampedQuote.receiveQuote, ONE);

        PoolState memory taxedPool = PoolState({
            rStatus: RStatus.ONE,
            baseBalance: 10 * ONE,
            quoteBalance: 1000 * ONE,
            targetBaseTokenAmount: 10 * ONE,
            targetQuoteTokenAmount: 1000 * ONE,
            lpFeeRate: 0,
            maintainerFeeRate: 0,
            buyTaxRate: 1,
            sellTaxRate: 0,
            taxEnabled: true,
            taxRecipient: address(0)
        });

        vm.expectRevert(bytes("INVALID_TAX_RECIPIENT"));
        quoter.queryBuyBaseToken(taxedPool, pricing, ONE);
    }

    function testRecoverLiquidityAndUserInputGuardBranches() public {
        vm.expectRevert(bytes("INVALID_TOKEN"));
        pool.recoverToken(address(0), address(this), 1);

        vm.expectRevert(bytes("INVALID_RECEIVER"));
        pool.recoverToken(address(stray), address(0), 1);

        ConfigurableERC20 badStray = new ConfigurableERC20("Bad Stray", "BST");
        badStray.mint(address(pool), ONE);
        badStray.setTransferBehavior(ConfigurableERC20.Behavior.ReturnFalse);

        vm.expectRevert(bytes("TOKEN_TRANSFER_FAILED"));
        pool.recoverToken(address(badStray), address(this), ONE);

        quote.mint(address(pool), ONE);
        uint256 quoteBefore = quote.balanceOf(address(this));
        pool.recoverToken(address(quote), address(this), ONE);
        assertEq(quote.balanceOf(address(this)) - quoteBefore, ONE);

        vm.expectRevert(bytes("INVALID_DIVIDEND_DISTRIBUTOR"));
        pool.pendingQuoteDividends(address(0), 1);

        _mintAndApprove(secondProvider, 5 * ONE, 500 * ONE);
        vm.prank(secondProvider);
        vm.expectRevert(bytes("INSUFFICIENT_SHARES"));
        pool.provideLiquidity(5 * ONE, 500 * ONE, 51 * ONE);

        _mintAndApprove(thirdProvider, 1, 1);
        vm.prank(thirdProvider);
        vm.expectRevert(bytes("ZERO_SHARES"));
        pool.provideLiquidity(1, 1, 0);

        vm.prank(outsider);
        vm.expectRevert(bytes("INSUFFICIENT_SHARES"));
        pool.withdrawLiquidity(1, 0, 0);

        uint256 sellQuote = pool.querySellBaseToken(ONE);
        vm.prank(trader);
        vm.expectRevert(bytes("SELL_BASE_RECEIVE_NOT_ENOUGH"));
        pool.sellBaseToken(ONE, sellQuote + 1);
    }

    function testTransferInFailureBranches() public {
        (PropertyPMM baseFalsePool, ConfigurableERC20 baseFalse,) = _freshConfigurablePool();
        baseFalse.setTransferFromBehavior(ConfigurableERC20.Behavior.ReturnFalse);
        _approveConfigurableLiquidity(baseFalsePool, baseFalse, ConfigurableERC20(address(baseFalsePool.quoteToken())));
        vm.prank(secondProvider);
        vm.expectRevert(bytes("BASE_TRANSFER_FROM_FAILED"));
        baseFalsePool.provideLiquidity(ONE, 100 * ONE, 0);

        (PropertyPMM baseMismatchPool, ConfigurableERC20 baseMismatch,) = _freshConfigurablePool();
        baseMismatch.setTransferFromBehavior(ConfigurableERC20.Behavior.TransferLess);
        _approveConfigurableLiquidity(
            baseMismatchPool, baseMismatch, ConfigurableERC20(address(baseMismatchPool.quoteToken()))
        );
        vm.prank(secondProvider);
        vm.expectRevert(bytes("BASE_TRANSFER_IN_MISMATCH"));
        baseMismatchPool.provideLiquidity(ONE, 100 * ONE, 0);

        (PropertyPMM quoteFalsePool,, ConfigurableERC20 quoteFalse) = _freshConfigurablePool();
        quoteFalse.setTransferFromBehavior(ConfigurableERC20.Behavior.ReturnFalse);
        _approveConfigurableLiquidity(
            quoteFalsePool, ConfigurableERC20(address(quoteFalsePool.baseToken())), quoteFalse
        );
        vm.prank(secondProvider);
        vm.expectRevert(bytes("QUOTE_TRANSFER_FROM_FAILED"));
        quoteFalsePool.provideLiquidity(ONE, 100 * ONE, 0);

        (PropertyPMM quoteMismatchPool,, ConfigurableERC20 quoteMismatch) = _freshConfigurablePool();
        quoteMismatch.setTransferFromBehavior(ConfigurableERC20.Behavior.TransferLess);
        _approveConfigurableLiquidity(
            quoteMismatchPool, ConfigurableERC20(address(quoteMismatchPool.baseToken())), quoteMismatch
        );
        vm.prank(secondProvider);
        vm.expectRevert(bytes("QUOTE_TRANSFER_IN_MISMATCH"));
        quoteMismatchPool.provideLiquidity(ONE, 100 * ONE, 0);
    }

    function testTransferOutAndTaxTransferFailureBranches() public {
        (PropertyPMM baseFalsePool, ConfigurableERC20 baseFalse,) = _seedConfigurablePool();
        uint256 buyQuote = baseFalsePool.queryBuyBaseToken(ONE);
        baseFalse.setTransferBehavior(ConfigurableERC20.Behavior.ReturnFalse);
        vm.prank(trader);
        vm.expectRevert(bytes("BASE_TRANSFER_FAILED"));
        baseFalsePool.buyBaseToken(ONE, buyQuote);

        (PropertyPMM baseMismatchPool, ConfigurableERC20 baseMismatch,) = _seedConfigurablePool();
        buyQuote = baseMismatchPool.queryBuyBaseToken(ONE);
        baseMismatch.setTransferBehavior(ConfigurableERC20.Behavior.TransferLess);
        vm.prank(trader);
        vm.expectRevert(bytes("BASE_TRANSFER_OUT_MISMATCH"));
        baseMismatchPool.buyBaseToken(ONE, buyQuote);

        (PropertyPMM quoteFalsePool,, ConfigurableERC20 quoteFalse) = _seedConfigurablePool();
        uint256 sellQuote = quoteFalsePool.querySellBaseToken(ONE);
        quoteFalse.setTransferBehavior(ConfigurableERC20.Behavior.ReturnFalse);
        vm.prank(trader);
        vm.expectRevert(bytes("QUOTE_TRANSFER_FAILED"));
        quoteFalsePool.sellBaseToken(ONE, sellQuote);

        (PropertyPMM quoteMismatchPool,, ConfigurableERC20 quoteMismatch) = _seedConfigurablePool();
        sellQuote = quoteMismatchPool.querySellBaseToken(ONE);
        quoteMismatch.setTransferBehavior(ConfigurableERC20.Behavior.TransferLess);
        vm.prank(trader);
        vm.expectRevert(bytes("QUOTE_TRANSFER_OUT_MISMATCH"));
        quoteMismatchPool.sellBaseToken(ONE, sellQuote);

        (PropertyPMM taxPool,, ConfigurableERC20 taxQuote) = _seedConfigurablePool();
        taxPool.setTaxRecipient(taxRecipient);
        taxPool.setBuyTaxRate(1e16);
        taxPool.enableTax();
        buyQuote = taxPool.queryBuyBaseToken(ONE);
        taxQuote.setFailTransferFromTo(taxRecipient);
        vm.prank(trader);
        vm.expectRevert(bytes("QUOTE_TRANSFER_FROM_FAILED"));
        taxPool.buyBaseToken(ONE, buyQuote);
    }

    function testConfigQuoterAndRoleBranches() public {
        vm.expectRevert(bytes("INVALID_VALUATION_PRICE"));
        new AMMConfigHarness(address(this), supervisor, maintainer, 0);

        vm.expectRevert(bytes("MAINTAINER_NOT_SET"));
        pool.setMaintainer(address(0));

        AMMConfigHarness config = new AMMConfigHarness(address(this), supervisor, maintainer, INITIAL_PRICE);

        config.setRawValuation(0, block.timestamp);
        vm.expectRevert(bytes("INVALID_VALUATION_PRICE"));
        config.validatedValuation();

        config.setRawValuation(INITIAL_PRICE, 0);
        vm.expectRevert(bytes("INVALID_VALUATION_TIMESTAMP"));
        config.validatedValuation();

        config.setRawValuation(INITIAL_PRICE, block.timestamp + 1);
        vm.expectRevert(bytes("VALUATION_TIMESTAMP_IN_FUTURE"));
        config.validatedValuation();

        vm.expectRevert(bytes("INVALID_VALUATION_DELTA_BPS"));
        config.setValuationValidation(1 hours, 10_001);

        vm.expectRevert(bytes("NO_PENDING_VALUATION"));
        config.acceptPendingValuation();

        config.setValuationValidation(1 hours, 1_000);
        config.setValuationPrice(120 * ONE);
        assertTrue(config.valuationCircuitBreakerTripped());
        assertEq(config.pendingValuationPrice(), 120 * ONE);
        config.acceptPendingValuation();
        assertFalse(config.valuationCircuitBreakerTripped());
        assertEq(config.getValuationPrice(), 120 * ONE);

        vm.expectRevert(bytes("INVALID_VALUATION_TIMESTAMP"));
        config.setValuationPriceWithTimestamp(INITIAL_PRICE, 0);

        PoolState memory balancedPool = PoolState({
            rStatus: RStatus.ONE,
            baseBalance: 10 * ONE,
            quoteBalance: 1000 * ONE,
            targetBaseTokenAmount: 10 * ONE,
            targetQuoteTokenAmount: 1000 * ONE,
            lpFeeRate: 0,
            maintainerFeeRate: 0,
            buyTaxRate: 0,
            sellTaxRate: 0,
            taxEnabled: false,
            taxRecipient: address(0)
        });
        PricingState memory pricing = PricingState({price: INITIAL_PRICE, effectiveK: DEFAULT_K});

        vm.expectRevert(bytes("DODO_BASE_BALANCE_NOT_ENOUGH"));
        quoter.queryBuyBaseToken(balancedPool, pricing, 10 * ONE);

        balancedPool.rStatus = RStatus.ABOVE_ONE;
        balancedPool.baseBalance = 5 * ONE;
        balancedPool.quoteBalance = 1200 * ONE;
        balancedPool.targetQuoteTokenAmount = 1000 * ONE;
        vm.expectRevert(bytes("DODO_BASE_BALANCE_NOT_ENOUGH"));
        quoter.queryBuyBaseToken(balancedPool, pricing, 5 * ONE);

        AMMRolesHarness roles = new AMMRolesHarness(address(this), supervisor);
        roles.ownerOnly();
        assertFalse(roles.catchesOwnerOnlyRevert());
        vm.prank(outsider);
        vm.expectRevert(bytes("NOT_OWNER"));
        roles.ownerOnly();
        roles.supervisorOrOwnerOnly();
        vm.prank(supervisor);
        roles.supervisorOrOwnerOnly();
        vm.prank(outsider);
        vm.expectRevert(bytes("NOT_SUPERVISOR_OR_OWNER"));
        roles.supervisorOrOwnerOnly();
    }

    function _freshConfigurablePool()
        internal
        returns (PropertyPMM freshPool, ConfigurableERC20 freshBase, ConfigurableERC20 freshQuote)
    {
        freshBase = new ConfigurableERC20("Config Base", "CB");
        freshQuote = new ConfigurableERC20("Config Quote", "CQ");
        freshBase.setKycRegistry(address(kyc));
        freshPool = new PropertyPMM(
            address(this),
            supervisor,
            maintainer,
            address(freshBase),
            address(freshQuote),
            INITIAL_PRICE,
            DEFAULT_LP_FEE,
            DEFAULT_MAINTAINER_FEE,
            DEFAULT_K,
            "Config LP",
            "CLP"
        );
    }

    function _approveConfigurableLiquidity(
        PropertyPMM freshPool,
        ConfigurableERC20 freshBase,
        ConfigurableERC20 freshQuote
    ) internal {
        freshBase.mint(secondProvider, ONE);
        freshQuote.mint(secondProvider, 100 * ONE);

        vm.startPrank(secondProvider);
        freshBase.approve(address(freshPool), type(uint256).max);
        freshQuote.approve(address(freshPool), type(uint256).max);
        vm.stopPrank();
    }

    function _seedConfigurablePool()
        internal
        returns (PropertyPMM freshPool, ConfigurableERC20 freshBase, ConfigurableERC20 freshQuote)
    {
        (freshPool, freshBase, freshQuote) = _freshConfigurablePool();

        freshBase.mint(lpProvider, INITIAL_BASE);
        freshQuote.mint(lpProvider, INITIAL_QUOTE);
        vm.startPrank(lpProvider);
        freshBase.approve(address(freshPool), type(uint256).max);
        freshQuote.approve(address(freshPool), type(uint256).max);
        freshPool.provideLiquidity(INITIAL_BASE, INITIAL_QUOTE, 0);
        vm.stopPrank();
        freshPool.enableTrading();

        freshBase.mint(trader, 10 * ONE);
        freshQuote.mint(trader, 1000 * ONE);
        vm.startPrank(trader);
        freshBase.approve(address(freshPool), type(uint256).max);
        freshQuote.approve(address(freshPool), type(uint256).max);
        vm.stopPrank();
    }
}

// Local unit tests for the lightweight ERC20 used by AMM deployment scripts.
contract TestnetERC20UnitTest is Test {
    TestnetERC20 internal token;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new TestnetERC20("Testnet Token", "TNT", 18);
    }

    function testMetadataMintAndTransfers() public {
        assertEq(token.name(), "Testnet Token");
        assertEq(token.symbol(), "TNT");
        assertEq(token.decimals(), 18);

        token.mint(alice, 100 ether);
        assertEq(token.totalSupply(), 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(alice), 90 ether);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function testRejectsInvalidReceivers() public {
        vm.expectRevert(bytes("INVALID_RECEIVER"));
        token.mint(address(0), 1);

        token.mint(alice, 1);

        vm.prank(alice);
        vm.expectRevert(bytes("INVALID_RECEIVER"));
        token.transfer(address(0), 1);

        vm.prank(alice);
        token.approve(address(this), 1);

        vm.expectRevert(bytes("INVALID_RECEIVER"));
        token.transferFrom(alice, address(0), 1);
    }
}
