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
import {InitialSaleHandler} from "./InitialSaleHandler.sol";

/// @notice Invariant suite proving InitialSale stays solvent and its accounting is
///         conserved under arbitrary interleavings of deposit / buy / withdraw / pause.
contract InitialSaleInvariantTest is Test {
    uint256 internal constant TOTAL_SUPPLY = 1_000 ether;
    uint256 internal constant PRICE_PER_TOKEN = 100e6;
    uint256 internal constant BUYER_PAYMENT_BALANCE = 100_000_000e6;

    address internal owner;
    address internal treasury;

    KYCRegistry internal kycRegistry;
    PropertyToken internal propertyToken;
    TestnetERC20 internal paymentToken;
    InitialSale internal sale;
    InitialSaleHandler internal handler;

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");

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
        kycRegistry.addApprovedContract(address(sale));
        propertyToken.approve(address(sale), type(uint256).max);

        // Three KYC-verified buyers funded with payment tokens.
        address[] memory buyers = new address[](3);
        for (uint256 i = 0; i < buyers.length; i++) {
            address b = makeAddr(string.concat("buyer", vm.toString(i)));
            buyers[i] = b;
            kycRegistry.addUser(b);
            paymentToken.mint(b, BUYER_PAYMENT_BALANCE);
            vm.prank(b);
            paymentToken.approve(address(sale), type(uint256).max);
        }

        handler = new InitialSaleHandler(sale, propertyToken, paymentToken, owner, buyers);

        // Restrict the fuzzer to the handler's curated action space.
        targetContract(address(handler));
    }

    /// @notice The sale's property-token balance must always equal its booked inventory.
    ///         A mismatch would mean tokens entered/left without updating accounting.
    function invariant_propertyTokenSolvency() public {
        assertEq(propertyToken.balanceOf(address(sale)), sale.tokensAvailable());
    }

    /// @notice Every deposited token is accounted for: still in inventory, sold, or
    ///         withdrawn back as unsold. Nothing is created or destroyed.
    function invariant_inventoryConservation() public {
        assertEq(
            handler.ghostDeposited(),
            sale.tokensAvailable() + sale.totalTokensSold() + handler.ghostWithdrawnUnsold()
        );
    }

    /// @notice Payment held by the sale equals what was collected minus what was paid out.
    ///         The sale can never owe more proceeds than it holds.
    function invariant_paymentSolvency() public {
        assertEq(paymentToken.balanceOf(address(sale)), handler.ghostPaymentIn() - handler.ghostPaymentOut());
        assertEq(sale.totalPaymentCollected(), handler.ghostPaymentIn());
    }
}
