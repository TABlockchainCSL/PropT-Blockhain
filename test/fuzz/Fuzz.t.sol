// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import "../../contracts/core/KYCRegistry.sol";
import "../../contracts/core/PropertyRegistry.sol";
import "../../contracts/core/PropertyToken.sol";
import "../../contracts/core/PropertyTokenFactory.sol";
import "../../contracts/interfaces/IKYCRegistry.sol";
import "../../contracts/interfaces/IPropertyRegistry.sol";
import "../../contracts/interfaces/IPropertyTokenFactory.sol";

/// @title FuzzTest
/// @notice Property-based fuzz tests covering input space that unit tests miss:
///         transfer bounds, access control, approved contracts,
///         and property value range.
contract FuzzTest is Test {
    address internal admin;
    address internal user1;
    address internal user2;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyTokenFactory internal factory;
    UpgradeableBeacon internal beacon;

    function setUp() public virtual {
        admin = address(this);
        user1 = makeAddr("fuzzUser1");
        user2 = makeAddr("fuzzUser2");

        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry = KYCRegistry(
            address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ())))
        );

        PropertyRegistry regImpl = new PropertyRegistry();
        propertyRegistry = PropertyRegistry(
            address(new ERC1967Proxy(address(regImpl), abi.encodeCall(PropertyRegistry.initialize, ())))
        );

        PropertyToken tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), admin);

        PropertyTokenFactory factoryImpl = new PropertyTokenFactory();
        factory = PropertyTokenFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl),
                    abi.encodeCall(
                        PropertyTokenFactory.initialize,
                        (address(kycRegistry), address(propertyRegistry), address(beacon))
                    )
                )
            )
        );

        propertyRegistry.grantRole(propertyRegistry.REGISTRY_ADMIN_ROLE(), address(factory));
    }

    // --- Helpers ---

    function _deployToken() internal returns (PropertyToken token) {
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "Fuzz Token",
                    "FZT",
                    1_000 ether,
                    uint256(uint160(address(this))),
                    address(kycRegistry),
                    admin
                )
            )
        );
        return PropertyToken(address(proxy));
    }

    /// @dev Returns true when `addr` is safe to use as a fuzzed actor.
    function _isSafeActor(address addr) internal view returns (bool) {
        if (addr == address(0)) return false;
        if (uint160(addr) < 0x10) return false; // precompiles
        if (addr == admin) return false;
        if (addr == address(kycRegistry)) return false;
        if (addr == address(propertyRegistry)) return false;
        if (addr == address(factory)) return false;
        if (addr == address(beacon)) return false;
        return true;
    }

    // =========================================================================
    //  testFuzz_Transfer_RespectsBalance
    //  Transfer amount > balance must always revert; no silent underflow.
    // =========================================================================
    function testFuzz_Transfer_RespectsBalance(uint256 amount) public {
        amount = bound(amount, 1_001 ether, type(uint128).max);

        PropertyToken token = _deployToken();
        kycRegistry.addUser(admin);
        kycRegistry.addUser(user1);

        vm.expectRevert();
        token.transfer(user1, amount);

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.balanceOf(admin), 1_000 ether);
    }

    // =========================================================================
    //  testFuzz_AddUser_RejectsAnyNonAdmin
    //  addUser must revert for any caller without KYC_ADMIN_ROLE.
    // =========================================================================
    function testFuzz_AddUser_RejectsAnyNonAdmin(address caller) public {
        vm.assume(_isSafeActor(caller));
        vm.assume(!kycRegistry.hasRole(kycRegistry.KYC_ADMIN_ROLE(), caller));
        vm.prank(caller);
        vm.expectRevert();
        kycRegistry.addUser(user1);

        assertFalse(kycRegistry.isVerified(user1));
    }

    // =========================================================================
    //  testFuzz_ApprovedContract_TransferAllowed
    //  Approved contract can receive tokens without holding KYC level.
    // =========================================================================
    function testFuzz_ApprovedContract_TransferAllowed(uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);

        PropertyToken token = _deployToken();
        kycRegistry.addUser(admin);

        MockApprovedContract poolMock = new MockApprovedContract();
        kycRegistry.addApprovedContract(address(poolMock));

        bool ok = token.transfer(address(poolMock), amount);
        assertTrue(ok, "approved contract must receive tokens");
        assertEq(token.balanceOf(address(poolMock)), amount);
    }

    // =========================================================================
    //  testFuzz_RegisterProperty_AcceptsAnyNonZero
    //  registerProperty accepts any non-zero totalValue; propertyId is monotonic.
    // =========================================================================
    function testFuzz_RegisterProperty_AcceptsAnyNonZero(uint256 totalValue) public {
        totalValue = bound(totalValue, 1, type(uint128).max);

        uint256 idBefore = propertyRegistry.getNextPropertyId();
        address tokenMock =
            address(uint160(uint256(keccak256(abi.encode(totalValue)))));
        vm.assume(tokenMock != address(0));

        uint256 assignedId = propertyRegistry.registerProperty(
            "Fuzz Property", "Jl. Fuzz No. 1", totalValue, "ipfs://fuzz", tokenMock
        );

        assertEq(assignedId, idBefore);
        assertEq(propertyRegistry.getNextPropertyId(), idBefore + 1);

        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(assignedId);
        assertEq(prop.totalValue, totalValue);
        assertTrue(prop.isActive);
    }
}

/// @dev Minimal contract used as fuzzed "approved contract" recipient.
///      Has nonzero code so that KYCRegistry.addApprovedContract passes.
contract MockApprovedContract {
    uint256 public dummy;
}
