// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import "../contracts/core/KYCRegistry.sol";
import "../contracts/core/PropertyRegistry.sol";
import "../contracts/core/PropertyToken.sol";
import "./handlers/Handler.sol";

/// @title InvariantTest
/// @notice Stateful invariants verified across many random action sequences
///         dispatched by the InvariantHandler. Covers conservation of supply,
///         consistency of the KYC bookkeeping, and monotonicity of property IDs.
contract InvariantTest is Test {
    address internal admin;
    address internal seedActor1;
    address internal seedActor2;

    KYCRegistry internal kycRegistry;
    PropertyRegistry internal propertyRegistry;
    PropertyToken internal token;
    UpgradeableBeacon internal beacon;

    InvariantHandler internal handler;

    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;
    uint8 internal constant KYC_LEVEL_BASIC = 1;
    uint8 internal constant KYC_LEVEL_ENHANCED = 2;

    function setUp() public {
        admin = address(this);
        seedActor1 = makeAddr("invSeed1");
        seedActor2 = makeAddr("invSeed2");

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

        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                (
                    "Invariant Token",
                    "IVT",
                    INITIAL_SUPPLY,
                    1,
                    address(kycRegistry),
                    KYC_LEVEL_BASIC,
                    admin
                )
            )
        );
        token = PropertyToken(address(proxy));

        kycRegistry.addUser(admin, KYC_LEVEL_ENHANCED);
        kycRegistry.addUser(seedActor1, KYC_LEVEL_BASIC);
        kycRegistry.addUser(seedActor2, KYC_LEVEL_ENHANCED);

        address[] memory initialActors = new address[](2);
        initialActors[0] = seedActor1;
        initialActors[1] = seedActor2;

        handler = new InvariantHandler(
            kycRegistry,
            propertyRegistry,
            token,
            admin,
            initialActors
        );

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = InvariantHandler.addUser.selector;
        selectors[1] = InvariantHandler.removeUser.selector;
        selectors[2] = InvariantHandler.transfer.selector;
        selectors[3] = InvariantHandler.mint.selector;
        selectors[4] = InvariantHandler.registerProperty.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );

        excludeSender(admin);
        excludeContract(address(kycRegistry));
        excludeContract(address(propertyRegistry));
        excludeContract(address(token));
        excludeContract(address(beacon));
    }

    // -------------------------------------------------------------------
    //  Invariant 1: no value creation or destruction outside mint/burn
    // -------------------------------------------------------------------
    /// @notice totalSupply must always equal the sum of balances held by
    ///         admin + every actor tracked by the handler. Mints increase
    ///         totalSupply; no transfer may create or destroy tokens silently.
    function invariant_TotalSupplyEqualsBalanceSum() external {
        uint256 sum;

        address[] memory holders = handler.getHolders();
        for (uint256 i = 0; i < holders.length; i++) {
            sum += token.balanceOf(holders[i]);
        }

        assertEq(
            sum,
            token.totalSupply(),
            "totalSupply mismatch across tracked holders"
        );
    }

    // -------------------------------------------------------------------
    //  Invariant 2: KYC bookkeeping consistent
    // -------------------------------------------------------------------
    /// @notice The verified-user count reported by KYCRegistry must equal
    ///         the length of the underlying address array, and every
    ///         address in that array must still have a non-zero level.
    function invariant_VerifiedCountConsistent() external {
        uint256 reported = kycRegistry.getVerifiedUserCount();
        address[] memory verified = kycRegistry.getVerifiedUsers();
        assertEq(reported, verified.length, "count != array length");

        for (uint256 i = 0; i < verified.length; i++) {
            assertTrue(
                kycRegistry.isVerified(verified[i]),
                "listed address is not verified"
            );
            assertGt(
                kycRegistry.getKYCLevel(verified[i]),
                0,
                "verified address has level 0"
            );
        }
    }

    // -------------------------------------------------------------------
    //  Invariant 3: property IDs strictly monotonic
    // -------------------------------------------------------------------
    /// @notice getNextPropertyId() starts at 1 and never decreases; the
    ///         observed value must match the initial value plus the number
    ///         of successful registrations the handler has recorded.
    function invariant_PropertyIdMonotonic() external {
        uint256 next = propertyRegistry.getNextPropertyId();
        assertGe(next, 1, "nextPropertyId must start >= 1");
        assertEq(
            next,
            handler.ghostInitialNextPropertyId() + handler.ghostRegistered(),
            "propertyId drift"
        );
    }

    // -------------------------------------------------------------------
    //  Invariant 4: ownership never escapes admin (governance boundary)
    // -------------------------------------------------------------------
    /// @notice Owner of the PropertyToken never changes during fuzzed runs;
    ///         only a deliberate transferOwnership call (not exposed to the
    ///         handler) could move it.
    function invariant_OwnerUnchanged() external {
        assertEq(token.owner(), admin, "token ownership drifted");
    }

    /// @dev Reported in the invariant summary so we can see the fuzzer was
    ///      actually exercising each action.
    function invariant_callSummary() external {
        // No assertion here; just force the invariant runner to evaluate
        // `handler` state so ghost counters are captured in traces.
        assertGe(
            handler.callsTransfer() +
                handler.callsAddUser() +
                handler.callsRemoveUser() +
                handler.callsMint() +
                handler.callsRegister(),
            0
        );
    }
}
