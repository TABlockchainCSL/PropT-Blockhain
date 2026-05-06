// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import "../contracts/core/KYCRegistry.sol";
import "../contracts/core/PropertyRegistry.sol";
import "../contracts/core/PropertyToken.sol";
import "../contracts/core/PropertyTokenFactory.sol";
import "../contracts/interfaces/IKYCRegistry.sol";
import "../contracts/interfaces/IPropertyRegistry.sol";
import "../contracts/interfaces/IPropertyTokenFactory.sol";

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
        kycRegistry =
            KYCRegistry(address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()))));

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
                ("Fuzz Token", "FZT", 1_000 ether, uint256(uint160(address(this))), address(kycRegistry), admin)
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

    // -------------------------------------------------------------------
    //  3. Transfer must respect balance
    // -------------------------------------------------------------------
    /// @notice Any transfer amount strictly greater than the sender's balance
    ///         must revert; no silent underflow or balance creation.
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

    // -------------------------------------------------------------------
    //  5. Access control — any non-admin caller must be rejected
    // -------------------------------------------------------------------
    /// @notice addUser must revert for any caller that does not hold
    ///         KYC_ADMIN_ROLE, regardless of the target address or level.
    function testFuzz_AddUser_RejectsAnyNonAdmin(address caller) public {
        vm.assume(_isSafeActor(caller));
        vm.assume(!kycRegistry.hasRole(kycRegistry.KYC_ADMIN_ROLE(), caller));
        vm.prank(caller);
        vm.expectRevert();
        kycRegistry.addUser(user1);

        assertFalse(kycRegistry.isVerified(user1));
    }

    // -------------------------------------------------------------------
    //  6. Approved contracts bypass KYC (addApprovedContract property)
    // -------------------------------------------------------------------
    /// @notice Once an address is added as an approved contract, it may
    ///         participate in transfers without holding a KYC level.
    function testFuzz_ApprovedContract_TransferAllowed(uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);

        PropertyToken token = _deployToken();
        kycRegistry.addUser(admin);

        // Deploy a throwaway contract to serve as approved recipient.
        MockApprovedContract poolMock = new MockApprovedContract();
        kycRegistry.addApprovedContract(address(poolMock));

        // Before approval, transfer to a non-KYC contract would revert;
        // since we just added it, transfer must succeed.
        bool ok = token.transfer(address(poolMock), amount);
        assertTrue(ok, "approved contract must receive tokens");
        assertEq(token.balanceOf(address(poolMock)), amount);
    }

    // -------------------------------------------------------------------
    //  7. Property registration — any non-zero value is accepted
    // -------------------------------------------------------------------
    /// @notice registerProperty must accept any non-zero totalValue and
    ///         produce a strictly monotonic propertyId.
    function testFuzz_RegisterProperty_AcceptsAnyNonZero(uint256 totalValue) public {
        totalValue = bound(totalValue, 1, type(uint128).max);

        uint256 idBefore = propertyRegistry.getNextPropertyId();
        address tokenMock = address(uint160(uint256(keccak256(abi.encode(totalValue)))));
        vm.assume(tokenMock != address(0));

        uint256 assignedId =
            propertyRegistry.registerProperty("Fuzz Property", "Jl. Fuzz No. 1", totalValue, "ipfs://fuzz", tokenMock);

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
