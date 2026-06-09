// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {KYCRegistry} from "../../src/core/KYCRegistry.sol";
import {PropertyToken} from "../../src/core/PropertyToken.sol";
import {TestnetERC20} from "../../src/amm/testnet/TestnetERC20.sol";
import {InitialSale} from "../../src/sale/InitialSale.sol";
import {DividendDistribution} from "../../src/dividend/DividendDistribution.sol";

contract InitialSaleTest is Test {
    uint256 internal constant TOTAL_SUPPLY = 1_000 ether;
    uint256 internal constant PRICE_PER_TOKEN = 100e6;
    uint256 internal constant BUYER_PAYMENT_BALANCE = 1_000_000e6;

    address internal owner;
    address internal buyer;
    address internal buyer2;
    address internal nonKycBuyer;
    address internal treasury;
    address internal attacker;

    KYCRegistry internal kycRegistry;
    PropertyToken internal propertyToken;
    TestnetERC20 internal paymentToken;
    InitialSale internal sale;

    function setUp() public {
        owner = address(this);
        buyer = makeAddr("buyer");
        buyer2 = makeAddr("buyer2");
        nonKycBuyer = makeAddr("nonKycBuyer");
        treasury = makeAddr("treasury");
        attacker = makeAddr("attacker");

        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry =
            KYCRegistry(address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()))));

        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(tokenImpl), owner);
        BeaconProxy tokenProxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                ("RealToken - Initial Sale Property", "RTSALE", TOTAL_SUPPLY, 1, address(kycRegistry), owner)
            )
        );
        propertyToken = PropertyToken(address(tokenProxy));

        paymentToken = new TestnetERC20("USD Coin", "USDC", 6);
        sale = new InitialSale(address(propertyToken), address(paymentToken), treasury, PRICE_PER_TOKEN, owner);

        kycRegistry.addUser(owner);
        kycRegistry.addUser(buyer);
        kycRegistry.addUser(buyer2);
        kycRegistry.addApprovedContract(address(sale));

        propertyToken.approve(address(sale), type(uint256).max);
        _mintAndApprovePayment(buyer, BUYER_PAYMENT_BALANCE);
        _mintAndApprovePayment(buyer2, BUYER_PAYMENT_BALANCE);
        _mintAndApprovePayment(nonKycBuyer, BUYER_PAYMENT_BALANCE);
    }

    function test_InitialSale_constructorSetsConfig() public {
        assertEq(address(sale.propertyToken()), address(propertyToken));
        assertEq(address(sale.paymentToken()), address(paymentToken));
        assertEq(sale.treasury(), treasury);
        assertEq(sale.pricePerToken(), PRICE_PER_TOKEN);
        assertTrue(sale.saleActive());
        assertEq(sale.tokensAvailable(), 0);
    }

    function test_InitialSale_quoteUsesFixedPrice() public {
        assertEq(sale.quote(1 ether), 100e6);
        assertEq(sale.quote(2 ether), 200e6);
        assertEq(sale.quote(0.5 ether), 50e6);
    }

    function test_InitialSale_depositAllMovesWholeOwnerBalanceIntoSale() public {
        uint256 deposited = sale.depositAll();

        assertEq(deposited, TOTAL_SUPPLY);
        assertEq(sale.tokensAvailable(), TOTAL_SUPPLY);
        assertEq(propertyToken.balanceOf(address(sale)), TOTAL_SUPPLY);
        assertEq(propertyToken.balanceOf(owner), 0);
        assertEq(sale.remainingSaleValue(), 100_000e6);
    }

    function test_InitialSale_depositSpecificAmount() public {
        sale.deposit(10 ether);

        assertEq(sale.tokensAvailable(), 10 ether);
        assertEq(propertyToken.balanceOf(address(sale)), 10 ether);
        assertEq(propertyToken.balanceOf(owner), TOTAL_SUPPLY - 10 ether);
    }

    function test_InitialSale_depositRevertsIfSaleContractNotApprovedInKYC() public {
        InitialSale unapprovedSale =
            new InitialSale(address(propertyToken), address(paymentToken), treasury, PRICE_PER_TOKEN, owner);
        propertyToken.approve(address(unapprovedSale), type(uint256).max);

        // Deposit moves tokens into the sale; PropertyToken._update rejects the sale
        // as recipient because it is not registered as an approved contract.
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.RecipientNotAuthorized.selector, address(unapprovedSale)));
        unapprovedSale.deposit(1 ether);
    }

    function test_InitialSale_depositRevertsZeroAmount() public {
        vm.expectRevert(InitialSale.InvalidAmount.selector);
        sale.deposit(0);
    }

    function test_InitialSale_buyTransfersPropertyTokensAndCollectsPayment() public {
        sale.depositAll();

        vm.prank(buyer);
        uint256 paid = sale.buy(2 ether);

        assertEq(paid, 200e6);
        assertEq(propertyToken.balanceOf(buyer), 2 ether);
        assertEq(paymentToken.balanceOf(address(sale)), 200e6);
        assertEq(paymentToken.balanceOf(buyer), BUYER_PAYMENT_BALANCE - 200e6);
        assertEq(sale.tokensAvailable(), TOTAL_SUPPLY - 2 ether);
        assertEq(sale.totalTokensSold(), 2 ether);
        assertEq(sale.totalPaymentCollected(), 200e6);
    }

    function test_InitialSale_buySupportsFractionalPropertyTokens() public {
        sale.deposit(10 ether);

        vm.prank(buyer);
        uint256 paid = sale.buy(0.5 ether);

        assertEq(paid, 50e6);
        assertEq(propertyToken.balanceOf(buyer), 0.5 ether);
        assertEq(paymentToken.balanceOf(address(sale)), 50e6);
        assertEq(sale.tokensAvailable(), 9.5 ether);
    }

    function test_InitialSale_buyRevertsForNonKYCBuyer() public {
        sale.deposit(10 ether);

        // KYC is now enforced at the token layer (PropertyToken._update), not by an
        // explicit check in buy(), so the buy reverts when the property token transfer
        // rejects the non-verified recipient.
        vm.prank(nonKycBuyer);
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.RecipientNotAuthorized.selector, nonKycBuyer));
        sale.buy(1 ether);
    }

    function test_InitialSale_buyRevertsWhenSaleInactive() public {
        sale.deposit(10 ether);
        sale.setSaleActive(false);

        vm.prank(buyer);
        vm.expectRevert(InitialSale.SaleInactive.selector);
        sale.buy(1 ether);
    }

    function test_InitialSale_buyRevertsWhenInventoryInsufficient() public {
        sale.deposit(1 ether);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(InitialSale.InsufficientInventory.selector, 2 ether, 1 ether));
        sale.buy(2 ether);
    }

    function test_InitialSale_buyRevertsZeroAmount() public {
        sale.deposit(1 ether);

        vm.prank(buyer);
        vm.expectRevert(InitialSale.InvalidAmount.selector);
        sale.buy(0);
    }

    function test_InitialSale_fixedPricePersistsAcrossSalePause() public {
        sale.deposit(10 ether);
        sale.setSaleActive(false);
        sale.setSaleActive(true);

        vm.prank(buyer);
        uint256 paid = sale.buy(2 ether);

        assertEq(paid, 200e6);
        assertEq(sale.pricePerToken(), PRICE_PER_TOKEN);
        assertEq(paymentToken.balanceOf(address(sale)), 200e6);
    }

    function test_InitialSale_constructorRevertsZeroPrice() public {
        vm.expectRevert(InitialSale.InvalidPrice.selector);
        new InitialSale(address(propertyToken), address(paymentToken), treasury, 0, owner);
    }

    function test_InitialSale_fixedPriceAppliesAcrossMultipleBuyers() public {
        sale.deposit(10 ether);

        vm.prank(buyer);
        uint256 firstPayment = sale.buy(1 ether);

        vm.prank(buyer2);
        uint256 secondPayment = sale.buy(2 ether);

        assertEq(firstPayment, 100e6);
        assertEq(secondPayment, 200e6);
        assertEq(sale.pricePerToken(), PRICE_PER_TOKEN);
        assertEq(paymentToken.balanceOf(address(sale)), 300e6);
    }

    function test_InitialSale_withdrawAllProceedsTransfersPaymentToTreasury() public {
        sale.deposit(10 ether);

        vm.prank(buyer);
        sale.buy(2 ether);

        uint256 withdrawn = sale.withdrawAllProceeds();

        assertEq(withdrawn, 200e6);
        assertEq(paymentToken.balanceOf(treasury), 200e6);
        assertEq(paymentToken.balanceOf(address(sale)), 0);
    }

    function test_InitialSale_withdrawPartialProceeds() public {
        sale.deposit(10 ether);

        vm.prank(buyer);
        sale.buy(2 ether);

        sale.withdrawProceeds(75e6);

        assertEq(paymentToken.balanceOf(treasury), 75e6);
        assertEq(paymentToken.balanceOf(address(sale)), 125e6);
    }

    function test_InitialSale_withdrawProceedsRevertsIfAmountExceedsAvailable() public {
        vm.expectRevert(abi.encodeWithSelector(InitialSale.InsufficientProceeds.selector, 1, 0));
        sale.withdrawProceeds(1);
    }

    function test_InitialSale_withdrawUnsoldRequiresInactiveSale() public {
        sale.deposit(10 ether);

        vm.expectRevert(InitialSale.SaleActive.selector);
        sale.withdrawUnsold(owner, 1 ether);
    }

    function test_InitialSale_withdrawUnsoldAfterClosingSale() public {
        sale.deposit(10 ether);
        sale.setSaleActive(false);

        sale.withdrawUnsold(owner, 4 ether);

        assertEq(sale.tokensAvailable(), 6 ether);
        assertEq(propertyToken.balanceOf(owner), TOTAL_SUPPLY - 6 ether);
        assertEq(propertyToken.balanceOf(address(sale)), 6 ether);
    }

    function test_InitialSale_withdrawUnsoldRevertsForNonAuthorizedRecipient() public {
        sale.deposit(10 ether);
        sale.setSaleActive(false);

        // Recipient authorization is enforced by the token transfer in withdrawUnsold.
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.RecipientNotAuthorized.selector, nonKycBuyer));
        sale.withdrawUnsold(nonKycBuyer, 1 ether);
    }

    function test_InitialSale_setTreasuryUpdatesWithdrawReceiver() public {
        address newTreasury = makeAddr("newTreasury");
        sale.setTreasury(newTreasury);
        sale.deposit(10 ether);

        vm.prank(buyer);
        sale.buy(1 ether);
        sale.withdrawAllProceeds();

        assertEq(paymentToken.balanceOf(newTreasury), 100e6);
        assertEq(paymentToken.balanceOf(treasury), 0);
    }

    function test_InitialSale_adminFunctionsRevertForNonOwner() public {
        vm.startPrank(attacker);

        vm.expectRevert();
        sale.deposit(1 ether);

        vm.expectRevert();
        sale.withdrawProceeds(1);

        vm.expectRevert();
        sale.withdrawUnsold(attacker, 1 ether);

        vm.expectRevert();
        sale.setSaleActive(false);

        vm.expectRevert();
        sale.setTreasury(attacker);

        vm.stopPrank();
    }

    /// @notice End-to-end proof of the Model-A mechanism: the sale delegates its voting
    ///         units to the treasury, so dividends accruing to unsold inventory are
    ///         claimable by the issuer (treasury) instead of being stranded. The sold
    ///         portion is claimable by the buyer. Together they drain the full epoch.
    function test_InitialSale_unsoldInventoryDividendsClaimableByTreasury() public {
        // Separate stablecoin so dividend balances do not mix with sale proceeds.
        TestnetERC20 divToken = new TestnetERC20("Dividend USD", "dUSD", 6);
        DividendDistribution dividends =
            new DividendDistribution(address(propertyToken), address(divToken), address(kycRegistry), owner);

        // Treasury must be authorized to claim its share.
        kycRegistry.addUser(treasury);

        // Put the whole supply into the sale as inventory (votes delegated to treasury).
        sale.deposit(TOTAL_SUPPLY);
        assertEq(propertyToken.getVotes(treasury), TOTAL_SUPPLY);

        // Buyer self-delegates (required to claim) and buys 40% of inventory.
        vm.prank(buyer);
        propertyToken.delegate(buyer);
        vm.prank(buyer);
        sale.buy(400 ether);

        // Sale keeps 600 (delegated to treasury); buyer holds 400.
        assertEq(propertyToken.getVotes(treasury), 600 ether);
        assertEq(propertyToken.getVotes(buyer), 400 ether);

        // Settle the snapshot block, then deposit one 1,000 dUSD dividend epoch.
        vm.roll(block.number + 1);
        uint256 divAmount = 1_000e6;
        divToken.mint(owner, divAmount);
        divToken.approve(address(dividends), divAmount);
        dividends.depositDividends(divAmount);
        vm.roll(block.number + 1);

        // Treasury claims the unsold share (600/1000), buyer claims the sold share (400/1000).
        vm.prank(treasury);
        dividends.claimDividends(type(uint256).max);
        vm.prank(buyer);
        dividends.claimDividends(type(uint256).max);

        assertEq(divToken.balanceOf(treasury), 600e6);
        assertEq(divToken.balanceOf(buyer), 400e6);
        // Nothing stranded in the distributor.
        assertEq(divToken.balanceOf(address(dividends)), 0);
    }

    // ---------------------------------------------------------------------
    // Branch coverage: constructor guards
    // ---------------------------------------------------------------------

    function test_InitialSale_constructorRevertsZeroPropertyToken() public {
        vm.expectRevert(InitialSale.ZeroAddress.selector);
        new InitialSale(address(0), address(paymentToken), treasury, PRICE_PER_TOKEN, owner);
    }

    function test_InitialSale_constructorRevertsZeroPaymentToken() public {
        vm.expectRevert(InitialSale.ZeroAddress.selector);
        new InitialSale(address(propertyToken), address(0), treasury, PRICE_PER_TOKEN, owner);
    }

    function test_InitialSale_constructorRevertsZeroTreasury() public {
        vm.expectRevert(InitialSale.ZeroAddress.selector);
        new InitialSale(address(propertyToken), address(paymentToken), address(0), PRICE_PER_TOKEN, owner);
    }

    function test_InitialSale_constructorRevertsIdenticalTokens() public {
        vm.expectRevert(InitialSale.IdenticalTokens.selector);
        new InitialSale(address(propertyToken), address(propertyToken), treasury, PRICE_PER_TOKEN, owner);
    }

    // ---------------------------------------------------------------------
    // Branch coverage: buy / withdraw / setTreasury guards
    // ---------------------------------------------------------------------

    function test_InitialSale_availableProceedsReflectsCollectedPayment() public {
        sale.deposit(10 ether);
        assertEq(sale.availableProceeds(), 0);

        vm.prank(buyer);
        sale.buy(2 ether);
        assertEq(sale.availableProceeds(), 200e6);

        sale.withdrawProceeds(50e6);
        assertEq(sale.availableProceeds(), 150e6);
    }

    function test_InitialSale_buyRevertsWhenQuoteRoundsToZero() public {
        sale.deposit(10 ether);

        // pricePerToken = 100e6, so quote(amount) = amount * 100e6 / 1e18. Any amount
        // below 1e10 wei rounds the payment down to zero, which must be rejected so
        // buyers cannot drain inventory for free.
        vm.prank(buyer);
        vm.expectRevert(InitialSale.ZeroPayment.selector);
        sale.buy(1e9);
    }

    function test_InitialSale_withdrawUnsoldRevertsZeroAddress() public {
        sale.deposit(10 ether);
        sale.setSaleActive(false);

        vm.expectRevert(InitialSale.ZeroAddress.selector);
        sale.withdrawUnsold(address(0), 1 ether);
    }

    function test_InitialSale_withdrawUnsoldRevertsZeroAmount() public {
        sale.deposit(10 ether);
        sale.setSaleActive(false);

        vm.expectRevert(InitialSale.InvalidAmount.selector);
        sale.withdrawUnsold(owner, 0);
    }

    function test_InitialSale_withdrawUnsoldRevertsInsufficientInventory() public {
        sale.deposit(1 ether);
        sale.setSaleActive(false);

        vm.expectRevert(abi.encodeWithSelector(InitialSale.InsufficientInventory.selector, 2 ether, 1 ether));
        sale.withdrawUnsold(owner, 2 ether);
    }

    function test_InitialSale_withdrawProceedsRevertsZeroAmount() public {
        vm.expectRevert(InitialSale.InvalidAmount.selector);
        sale.withdrawProceeds(0);
    }

    function test_InitialSale_setTreasuryRevertsZeroAddress() public {
        vm.expectRevert(InitialSale.ZeroAddress.selector);
        sale.setTreasury(address(0));
    }

    // ---------------------------------------------------------------------
    // Fuzz tests
    // ---------------------------------------------------------------------

    /// @notice quote() must be exactly amount * price / 1e18 for any input, with no
    ///         overflow across the realistic supply/price range and monotonic output.
    function testFuzz_InitialSale_quoteMatchesFormula(uint256 amount) public {
        amount = bound(amount, 0, 1_000_000_000 ether);
        uint256 expected = (amount * PRICE_PER_TOKEN) / sale.PROPERTY_TOKEN_UNIT();
        assertEq(sale.quote(amount), expected);
    }

    /// @notice A successful buy of any inventory amount must (a) charge exactly quote(),
    ///         (b) decrement inventory by exactly `amount`, and (c) preserve the
    ///         conservation identity tokensAvailable + totalTokensSold == deposited.
    function testFuzz_InitialSale_buyConservesAccounting(uint256 deposit, uint256 amount) public {
        // Keep deposit (and therefore amount) above the rounding floor so quote() never
        // returns zero, otherwise buy() would revert with ZeroPayment.
        deposit = bound(deposit, 1e10, TOTAL_SUPPLY);
        amount = bound(amount, 1e10, deposit);

        sale.deposit(deposit);

        uint256 expectedPay = sale.quote(amount);
        uint256 buyerBalBefore = paymentToken.balanceOf(buyer);

        vm.prank(buyer);
        uint256 paid = sale.buy(amount);

        assertEq(paid, expectedPay);
        assertEq(propertyToken.balanceOf(buyer), amount);
        assertEq(paymentToken.balanceOf(buyer), buyerBalBefore - expectedPay);
        assertEq(sale.tokensAvailable() + sale.totalTokensSold(), deposit);
        assertEq(propertyToken.balanceOf(address(sale)), sale.tokensAvailable());
    }

    /// @notice Depositing then withdrawing the unsold inventory must return exactly what
    ///         went in, leaving the sale's property-token balance at zero.
    function testFuzz_InitialSale_depositWithdrawRoundtrip(uint256 amount) public {
        amount = bound(amount, 1, TOTAL_SUPPLY);

        sale.deposit(amount);
        sale.setSaleActive(false);
        sale.withdrawUnsold(owner, amount);

        assertEq(sale.tokensAvailable(), 0);
        assertEq(propertyToken.balanceOf(address(sale)), 0);
        assertEq(propertyToken.balanceOf(owner), TOTAL_SUPPLY);
    }

    function _mintAndApprovePayment(address account, uint256 amount) internal {
        paymentToken.mint(account, amount);
        vm.prank(account);
        paymentToken.approve(address(sale), type(uint256).max);
    }
}
