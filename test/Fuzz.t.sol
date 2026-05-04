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
///         KYC level enforcement, transfer bounds, batch size limits,
///         access control, approved contracts, and property value range.
contract FuzzTest is Test {
    address internal admin;
    address internal user1;
    address internal user2;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyTokenFactory internal factory;
    UpgradeableBeacon internal beacon;

    uint8 internal constant KYC_LEVEL_BASIC = 1;
    uint8 internal constant KYC_LEVEL_ENHANCED = 2;

    function setUp() public virtual {
        admin = address(this);
        user1 = makeAddr("fuzzUser1");
        user2 = makeAddr("fuzzUser2");

        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry = KYCRegistry(
            address(
                new ERC1967Proxy(
                    address(kycImpl),
                    abi.encodeCall(KYCRegistry.initialize, ())
                )
            )
        );

        PropertyRegistry regImpl = new PropertyRegistry();
        propertyRegistry = PropertyRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(PropertyRegistry.initialize, ())
                )
            )
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
                        (
                            address(kycRegistry),
                            address(propertyRegistry),
                            address(beacon)
                        )
                    )
                )
            )
        );

        propertyRegistry.grantRole(
            propertyRegistry.REGISTRY_ADMIN_ROLE(),
            address(factory)
        );
    }

    // --- Helpers ---

    function _deployToken(
        uint8 requiredLevel,
        address tokenOwner
    ) internal returns (PropertyToken token) {
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
                    requiredLevel,
                    tokenOwner
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

    // -------------------------------------------------------------------
    //  1. KYC level enforcement — accepts at-or-above required level
    // -------------------------------------------------------------------
    /// @notice If both parties hold KYC level >= token.requiredKYCLevel,
    ///         a transfer of the fuzzed amount must succeed.
    function testFuzz_KYCLevel_AcceptsAtOrAbove(
        uint8 userLevel,
        uint8 reqLevel,
        uint256 amount
    ) public {
        reqLevel = uint8(bound(reqLevel, KYC_LEVEL_BASIC, KYC_LEVEL_ENHANCED));
        userLevel = uint8(bound(userLevel, reqLevel, KYC_LEVEL_ENHANCED));
        amount = bound(amount, 1, 1_000 ether);

        PropertyToken token = _deployToken(reqLevel, admin);
        kycRegistry.addUser(admin, userLevel);
        kycRegistry.addUser(user1, userLevel);

        bool ok = token.transfer(user1, amount);
        assertTrue(ok, "transfer must succeed for level >= requirement");
        assertEq(token.balanceOf(user1), amount);
    }

    // -------------------------------------------------------------------
    //  2. KYC level enforcement — rejects when user level < required
    // -------------------------------------------------------------------
    /// @notice A user with level below requiredKYCLevel must never receive tokens.
    function testFuzz_KYCLevel_RejectsBelowRequired(
        uint8 userLevel,
        uint256 amount
    ) public {
        userLevel = uint8(bound(userLevel, KYC_LEVEL_BASIC, KYC_LEVEL_BASIC));
        amount = bound(amount, 1, 1_000 ether);

        PropertyToken token = _deployToken(KYC_LEVEL_ENHANCED, admin);
        kycRegistry.addUser(admin, KYC_LEVEL_ENHANCED);
        kycRegistry.addUser(user1, userLevel);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyToken.InsufficientKYCLevel.selector,
                user1,
                KYC_LEVEL_ENHANCED,
                userLevel
            )
        );
        token.transfer(user1, amount);
    }

    // -------------------------------------------------------------------
    //  3. Transfer must respect balance
    // -------------------------------------------------------------------
    /// @notice Any transfer amount strictly greater than the sender's balance
    ///         must revert; no silent underflow or balance creation.
    function testFuzz_Transfer_RespectsBalance(uint256 amount) public {
        amount = bound(amount, 1_001 ether, type(uint128).max);

        PropertyToken token = _deployToken(KYC_LEVEL_BASIC, admin);
        kycRegistry.addUser(admin, KYC_LEVEL_BASIC);
        kycRegistry.addUser(user1, KYC_LEVEL_BASIC);

        vm.expectRevert();
        token.transfer(user1, amount);

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.balanceOf(admin), 1_000 ether);
    }

    // -------------------------------------------------------------------
    //  4. Batch size bounded by MAX_BATCH_SIZE
    // -------------------------------------------------------------------
    /// @notice batchAddUsers must accept any batch <= MAX_BATCH_SIZE and
    ///         reject any batch > MAX_BATCH_SIZE with BatchTooLarge.
    function testFuzz_BatchAddUsers_BoundedByMax(uint8 count) public {
        count = uint8(bound(count, 1, 150));

        address[] memory users = new address[](count);
        uint8[] memory levels = new uint8[](count);
        for (uint256 i = 0; i < count; i++) {
            users[i] = address(
                uint160(uint256(keccak256(abi.encode(i, count))))
            );
            levels[i] = KYC_LEVEL_BASIC;
        }

        uint256 maxBatch = kycRegistry.MAX_BATCH_SIZE();

        if (count > maxBatch) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IKYCRegistry.BatchTooLarge.selector,
                    count,
                    maxBatch
                )
            );
            kycRegistry.batchAddUsers(users, levels);
            assertEq(kycRegistry.getVerifiedUserCount(), 0);
        } else {
            kycRegistry.batchAddUsers(users, levels);
            assertEq(kycRegistry.getVerifiedUserCount(), count);
        }
    }

    // -------------------------------------------------------------------
    //  5. Access control — any non-admin caller must be rejected
    // -------------------------------------------------------------------
    /// @notice addUser must revert for any caller that does not hold
    ///         KYC_ADMIN_ROLE, regardless of the target address or level.
    function testFuzz_AddUser_RejectsAnyNonAdmin(
        address caller,
        uint8 level
    ) public {
        vm.assume(_isSafeActor(caller));
        vm.assume(!kycRegistry.hasRole(kycRegistry.KYC_ADMIN_ROLE(), caller));
        level = uint8(bound(level, KYC_LEVEL_BASIC, KYC_LEVEL_ENHANCED));

        vm.prank(caller);
        vm.expectRevert();
        kycRegistry.addUser(user1, level);

        assertFalse(kycRegistry.isVerified(user1));
    }

    // -------------------------------------------------------------------
    //  6. Approved contracts bypass KYC (addApprovedContract property)
    // -------------------------------------------------------------------
    /// @notice Once an address is added as an approved contract, it may
    ///         participate in transfers without holding a KYC level.
    function testFuzz_ApprovedContract_TransferAllowed(uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);

        PropertyToken token = _deployToken(KYC_LEVEL_BASIC, admin);
        kycRegistry.addUser(admin, KYC_LEVEL_BASIC);

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
    function testFuzz_RegisterProperty_AcceptsAnyNonZero(
        uint256 totalValue
    ) public {
        totalValue = bound(totalValue, 1, type(uint128).max);

        uint256 idBefore = propertyRegistry.getNextPropertyId();
        address tokenMock = address(
            uint160(uint256(keccak256(abi.encode(totalValue))))
        );
        vm.assume(tokenMock != address(0));

        uint256 assignedId = propertyRegistry.registerProperty(
            "Fuzz Property",
            "Jl. Fuzz No. 1",
            totalValue,
            "ipfs://fuzz",
            tokenMock
        );

        assertEq(assignedId, idBefore);
        assertEq(propertyRegistry.getNextPropertyId(), idBefore + 1);

        IPropertyRegistry.Property memory prop = propertyRegistry.getProperty(
            assignedId
        );
        assertEq(prop.totalValue, totalValue);
        assertTrue(prop.isActive);
    }
}

/// @dev Minimal contract used as fuzzed "approved contract" recipient.
///      Has nonzero code so that KYCRegistry.addApprovedContract passes.
contract MockApprovedContract {
    uint256 public dummy;
}
