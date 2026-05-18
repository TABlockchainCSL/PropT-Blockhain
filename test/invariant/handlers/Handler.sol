// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/StdUtils.sol";
import "forge-std/StdCheats.sol";
import "forge-std/Base.sol";

import "../../../src/core/KYCRegistry.sol";
import "../../../src/core/PropertyRegistry.sol";
import "../../../src/core/PropertyToken.sol";

/// @title InvariantHandler
/// @notice Handler that mediates fuzzer calls to the core contracts so
///         invariant runs operate on a realistic action space: KYC-verified
///         transfers, bounded mints, admin-gated user management, and
///         property registrations. Keeps ghost state the invariants read.
contract InvariantHandler is CommonBase, StdCheats, StdUtils {
    KYCRegistry public immutable kycRegistry;
    PropertyRegistry public immutable propertyRegistry;
    PropertyToken public immutable token;
    address public immutable admin;

    address[] internal _actors;
    mapping(address => bool) internal _isActor;

    // Set of every address that has ever received/held tokens. Used only by
    // invariants so they can sum balances even after an address loses KYC.
    address[] internal _holders;
    mapping(address => bool) internal _isHolder;

    // --- Ghost state (read by invariant assertions) ---
    uint256 public ghostMinted;
    uint256 public ghostRegistered;
    uint256 public ghostLastPropertyId;
    uint256 public ghostInitialNextPropertyId;

    // --- Call counters (for forge invariant call summary) ---
    uint256 public callsTransfer;
    uint256 public callsAddUser;
    uint256 public callsRemoveUser;
    uint256 public callsMint;
    uint256 public callsRegister;

    constructor(
        KYCRegistry _kyc,
        PropertyRegistry _reg,
        PropertyToken _token,
        address _admin,
        address[] memory initialActors
    ) {
        kycRegistry = _kyc;
        propertyRegistry = _reg;
        token = _token;
        admin = _admin;
        ghostInitialNextPropertyId = _reg.getNextPropertyId();

        // Admin is the initial holder of the full supply; track it from t=0.
        _holders.push(_admin);
        _isHolder[_admin] = true;

        for (uint256 i = 0; i < initialActors.length; i++) {
            _actors.push(initialActors[i]);
            _isActor[initialActors[i]] = true;
            _holders.push(initialActors[i]);
            _isHolder[initialActors[i]] = true;
        }
    }

    function _trackHolder(address a) internal {
        if (a == address(0)) return;
        if (_isHolder[a]) return;
        _isHolder[a] = true;
        _holders.push(a);
    }

    // --- Views used by invariants ---

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function getActors() external view returns (address[] memory) {
        return _actors;
    }

    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    function getHolders() external view returns (address[] memory) {
        return _holders;
    }

    // --- Action: add a new KYC user ---
    /// @dev Uses a salted pseudo-random address so we explore many actors.
    function addUser(uint256 seed) external {
        callsAddUser++;
        address a =
            address(uint160(uint256(keccak256(abi.encode(seed, "actor", _actors.length)))));
        if (a == address(0) || uint160(a) < 0x20) return;
        if (a == admin || a == address(this)) return;
        if (a == address(token) || a == address(kycRegistry)) return;
        if (a == address(propertyRegistry)) return;
        if (kycRegistry.isVerified(a)) return;

        vm.prank(admin);
        try kycRegistry.addUser(a) {
            if (!_isActor[a]) {
                _actors.push(a);
                _isActor[a] = true;
            }
            _trackHolder(a);
        } catch {}
    }

    // --- Action: remove a KYC user ---
    /// @dev Will not remove the last remaining actor so transfers stay alive.
    function removeUser(uint256 idx) external {
        callsRemoveUser++;
        if (_actors.length <= 1) return;
        idx = bound(idx, 0, _actors.length - 1);
        address a = _actors[idx];
        if (!kycRegistry.isVerified(a)) return;

        vm.prank(admin);
        try kycRegistry.removeUser(a) {
            _isActor[a] = false;
            _actors[idx] = _actors[_actors.length - 1];
            _actors.pop();
        } catch {}
    }

    // --- Action: transfer between admin/actors ---
    /// @dev fromIdx/toIdx==0 means admin (initial holder); >=1 means actors[idx-1].
    function transfer(uint256 fromIdx, uint256 toIdx, uint256 amount) external {
        callsTransfer++;
        if (_actors.length == 0) return;

        address from = _pickHolder(fromIdx);
        address to = _pickHolder(toIdx);
        if (from == to) return;

        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(from);
        try token.transfer(to, amount) {
            _trackHolder(to);
        } catch {}
    }

    // --- Action: mint additional supply to an existing holder ---
    function mint(uint256 toIdx, uint256 amount) external {
        callsMint++;
        address to = _pickHolder(toIdx);
        amount = bound(amount, 1, 1_000 ether);

        vm.prank(admin);
        try token.mint(to, amount) {
            ghostMinted += amount;
            _trackHolder(to);
        } catch {}
    }

    // --- Action: register a new property ---
    function registerProperty(uint256 seed, uint256 totalValue) external {
        callsRegister++;
        totalValue = bound(totalValue, 1, type(uint128).max);

        address tokenAddr =
            address(uint160(uint256(keccak256(abi.encode(seed, "prop", ghostRegistered)))));
        if (tokenAddr == address(0)) return;

        vm.prank(admin);
        try propertyRegistry.registerProperty(
            "Inv Property", "Jl. Invariant No. 1", totalValue, "ipfs://inv", tokenAddr
        ) returns (uint256 id) {
            ghostRegistered++;
            if (id > ghostLastPropertyId) {
                ghostLastPropertyId = id;
            }
        } catch {}
    }

    // --- Internal: resolve index to admin or actor ---
    function _pickHolder(uint256 idx) internal view returns (address) {
        uint256 total = _actors.length + 1; // +1 for admin
        uint256 pick = bound(idx, 0, total - 1);
        if (pick == 0) return admin;
        return _actors[pick - 1];
    }
}
