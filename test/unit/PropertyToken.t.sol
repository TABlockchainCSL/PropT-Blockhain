// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import "../../contracts/core/KYCRegistry.sol";
import "../../contracts/core/PropertyToken.sol";

/// @title PropertyTokenTest
/// @notice Unit tests for PropertyToken: ERC-20 transfers, KYC gate, pause,
///         mint/burn, ERC20Votes, ERC20Permit, upgradeability, and security paths.
contract PropertyTokenTest is Test {
    address internal owner;
    address internal attacker;
    address internal user1;
    address internal user2;
    address internal user3;

    KYCRegistry internal kycRegistry;
    UpgradeableBeacon internal beacon;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        KYCRegistry kycImpl = new KYCRegistry();
        kycRegistry = KYCRegistry(
            address(new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ())))
        );

        PropertyToken tokenImpl = new PropertyToken();
        beacon = new UpgradeableBeacon(address(tokenImpl), owner);
    }

    // --- Helpers ---

    function _deployToken() internal returns (PropertyToken) {
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                ("RealToken - Jl. Sudirman No. 1", "RTJKS1", 1000 ether, 1, address(kycRegistry), owner)
            )
        );
        return PropertyToken(address(proxy));
    }

    function _deployTokenSetup() internal returns (PropertyToken) {
        PropertyToken token = _deployToken();
        kycRegistry.addUser(owner);
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);
        return token;
    }

    // =========================================================================
    //  Basic properties
    // =========================================================================

    function test_Token_nameAndSymbol() public {
        PropertyToken token = _deployTokenSetup();
        assertEq(token.name(), "RealToken - Jl. Sudirman No. 1");
        assertEq(token.symbol(), "RTJKS1");
    }

    function test_Token_mintsToOwner() public {
        PropertyToken token = _deployTokenSetup();
        assertEq(token.balanceOf(owner), 1000 ether);
        assertEq(token.totalSupply(), 1000 ether);
    }

    function test_Token_propertyId() public {
        PropertyToken token = _deployTokenSetup();
        assertEq(token.propertyId(), 1);
    }

    function test_Token_kycRegistryAddr() public {
        PropertyToken token = _deployTokenSetup();
        assertEq(address(token.kycRegistry()), address(kycRegistry));
    }

    // =========================================================================
    //  Transfer — happy path
    // =========================================================================

    function test_Token_transferBetweenKYC() public {
        PropertyToken token = _deployTokenSetup();
        token.transfer(user1, 100 ether);
        assertEq(token.balanceOf(user1), 100 ether);
    }

    function test_Token_transferUser1ToUser2() public {
        PropertyToken token = _deployTokenSetup();
        token.transfer(user1, 100 ether);
        vm.prank(user1);
        token.transfer(user2, 50 ether);
        assertEq(token.balanceOf(user2), 50 ether);
    }

    // =========================================================================
    //  Transfer — negative path (KYC gate)
    // =========================================================================

    function test_Token_revertTransferToNonKYC() public {
        PropertyToken token = _deployTokenSetup();
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.RecipientNotAuthorized.selector, user3)
        );
        token.transfer(user3, 100 ether);
    }

    function test_Token_revertTransferFromNonKYC() public {
        PropertyToken token = _deployTokenSetup();
        kycRegistry.addUser(user3);
        token.transfer(user3, 100 ether);
        kycRegistry.removeUser(user3);

        vm.prank(user3);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.SenderNotAuthorized.selector, user3)
        );
        token.transfer(user1, 10 ether);
    }

    function test_KYCBypass_nonKYCCannotReceive() public {
        PropertyToken token = _deployTokenSetup();
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.RecipientNotAuthorized.selector, attacker)
        );
        token.transfer(attacker, 10 ether);
    }

    function test_KYCBypass_revokedSenderCannotTransfer() public {
        PropertyToken token = _deployTokenSetup();
        token.transfer(user1, 10 ether);
        kycRegistry.removeUser(user1);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.SenderNotAuthorized.selector, user1)
        );
        token.transfer(owner, 5 ether);
    }

    // =========================================================================
    //  Pause / unpause
    // =========================================================================

    function test_Token_pause() public {
        PropertyToken token = _deployTokenSetup();
        token.pause();
        vm.expectRevert();
        token.transfer(user1, 10 ether);
    }

    function test_Token_unpause() public {
        PropertyToken token = _deployTokenSetup();
        token.pause();
        token.unpause();
        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 10 ether);
    }

    function test_Token_pauseRevertNonOwner() public {
        PropertyToken token = _deployTokenSetup();
        vm.prank(user1);
        vm.expectRevert();
        token.pause();
    }

    function test_EmergencyPause_blocksTransfers() public {
        PropertyToken token = _deployTokenSetup();
        token.pause();
        vm.expectRevert();
        token.transfer(user1, 10 ether);
    }

    function test_EmergencyPause_blocksMinting() public {
        PropertyToken token = _deployTokenSetup();
        token.pause();
        vm.expectRevert();
        token.mint(owner, 100 ether);
    }

    function test_EmergencyPause_unpauseRestores() public {
        PropertyToken token = _deployTokenSetup();
        token.pause();
        token.unpause();
        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 10 ether);
    }

    // =========================================================================
    //  Mint / burn
    // =========================================================================

    function test_Token_mintAdditional() public {
        PropertyToken token = _deployTokenSetup();
        token.mint(owner, 500 ether);
        assertEq(token.totalSupply(), 1500 ether);
    }

    function test_Token_mintRevertNonOwner() public {
        PropertyToken token = _deployTokenSetup();
        vm.prank(user1);
        vm.expectRevert();
        token.mint(user1, 100 ether);
    }

    function test_Token_burn() public {
        PropertyToken token = _deployTokenSetup();
        token.burn(100 ether);
        assertEq(token.totalSupply(), 900 ether);
    }

    // =========================================================================
    //  setPauser
    // =========================================================================

    function test_Token_setPauser_revertZeroAddress() public {
        PropertyToken token = _deployToken();
        vm.expectRevert(PropertyToken.ZeroAddress.selector);
        token.setPauser(address(0));
    }

    function test_Token_setPauser_valid() public {
        PropertyToken token = _deployToken();
        token.setPauser(user1);
        assertEq(token.pauser(), user1);
    }

    function test_Token_setPauser_revertNonOwner() public {
        PropertyToken token = _deployToken();
        vm.prank(user1);
        vm.expectRevert();
        token.setPauser(user2);
    }

    function test_Token_pauser_canPauseNotUnpause() public {
        PropertyToken token = _deployToken();
        token.setPauser(user1);
        vm.prank(user1);
        token.pause();
        assertTrue(token.paused());

        vm.prank(user1);
        vm.expectRevert();
        token.unpause();
    }

    // =========================================================================
    //  ERC20Votes
    // =========================================================================

    function _deployVotesToken() internal returns (PropertyToken) {
        kycRegistry.addUser(owner);
        kycRegistry.addUser(user1);
        kycRegistry.addUser(user2);

        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                ("RealToken - Villa Bali", "RTVB", 1000 ether, 1, address(kycRegistry), owner)
            )
        );
        return PropertyToken(address(proxy));
    }

    function test_Votes_zeroBeforeDelegation() public {
        PropertyToken token = _deployVotesToken();
        assertEq(token.getVotes(owner), 0);
    }

    function test_Votes_selfDelegation() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(owner);
        assertEq(token.getVotes(owner), 1000 ether);
    }

    function test_Votes_delegateToAnother() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(user1);
        assertEq(token.getVotes(user1), 1000 ether);
        assertEq(token.getVotes(owner), 0);
    }

    function test_Votes_updateAfterTransfer() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(owner);
        vm.prank(user1);
        token.delegate(user1);
        token.transfer(user1, 300 ether);
        assertEq(token.getVotes(owner), 700 ether);
        assertEq(token.getVotes(user1), 300 ether);
    }

    function test_Votes_pastVotesCheckpoint() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(owner);
        vm.prank(user1);
        token.delegate(user1);

        uint256 snapshotBlock = block.number;
        vm.roll(block.number + 1);

        token.transfer(user1, 400 ether);
        vm.roll(block.number + 1);

        assertEq(token.getPastVotes(owner, snapshotBlock), 1000 ether);
        assertEq(token.getPastVotes(user1, snapshotBlock), 0);
        assertEq(token.getVotes(owner), 600 ether);
        assertEq(token.getVotes(user1), 400 ether);
    }

    function test_Votes_pastTotalSupply() public {
        PropertyToken token = _deployVotesToken();
        token.delegate(owner);

        uint256 snapshotBlock = block.number;
        vm.roll(block.number + 1);

        token.mint(owner, 500 ether);
        vm.roll(block.number + 1);

        assertEq(token.getPastTotalSupply(snapshotBlock), 1000 ether);
        assertEq(token.totalSupply(), 1500 ether);
    }

    // =========================================================================
    //  ERC20Permit (EIP-2612)
    // =========================================================================

    function test_Permit_gaslessApproval() public {
        uint256 ownerPk = 0xA11CE;
        address ownerAddr = vm.addr(ownerPk);

        kycRegistry.addUser(ownerAddr);
        kycRegistry.addUser(user1);

        PropertyToken permitToken = _deployPermitToken(ownerAddr);

        uint256 deadline = block.timestamp + 3600;
        bytes32 digest = _buildPermitDigest(permitToken, ownerAddr, user1, 100 ether, deadline);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        vm.prank(user1);
        permitToken.permit(ownerAddr, user1, 100 ether, deadline, v, r, s);
        assertEq(permitToken.allowance(ownerAddr, user1), 100 ether);
    }

    function _deployPermitToken(address tokenOwner) internal returns (PropertyToken) {
        BeaconProxy proxy = new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                PropertyToken.initialize,
                ("Permit Test Token", "PTT", 1000 ether, 99, address(kycRegistry), tokenOwner)
            )
        );
        return PropertyToken(address(proxy));
    }

    function _buildPermitDigest(
        PropertyToken token,
        address permitOwner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                permitOwner,
                spender,
                value,
                token.nonces(permitOwner),
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    // =========================================================================
    //  Upgradeability
    // =========================================================================

    function test_Token_reInit_reverts() public {
        PropertyToken token = _deployToken();
        vm.expectRevert();
        token.initialize("Hack", "HACK", 100 ether, 99, address(kycRegistry), attacker);
    }

    function test_UpgradeHijack_attackerCannotUpgradeBeacon() public {
        PropertyToken fakeImpl = new PropertyToken();
        vm.prank(attacker);
        vm.expectRevert();
        beacon.upgradeTo(address(fakeImpl));
    }

    // =========================================================================
    //  Security: ACL negative path
    // =========================================================================

    function test_ACL_attackerCannotMint() public {
        PropertyToken token = _deployTokenSetup();
        vm.prank(attacker);
        vm.expectRevert();
        token.mint(attacker, 1000 ether);
    }

    function test_ACL_attackerCannotPause() public {
        PropertyToken token = _deployTokenSetup();
        vm.prank(attacker);
        vm.expectRevert();
        token.pause();
    }

    function test_ACL_attackerCannotUnpause() public {
        PropertyToken token = _deployTokenSetup();
        token.pause();
        vm.prank(attacker);
        vm.expectRevert();
        token.unpause();
    }
}

/// @title PauserTest
/// @notice Dedicated tests for the pauser role: setPauser, pause by pauser,
///         only owner can unpause, attacker blocked.
contract PauserTest is Test {
    address internal owner;
    address internal pauser;
    address internal attacker;
    address internal user1;

    KYCRegistry internal kycRegistry;
    PropertyToken internal token;

    function setUp() public {
        owner = address(this);
        pauser = makeAddr("pauser");
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");

        KYCRegistry kycImpl = new KYCRegistry();
        ERC1967Proxy kycProxy =
            new ERC1967Proxy(address(kycImpl), abi.encodeCall(KYCRegistry.initialize, ()));
        kycRegistry = KYCRegistry(address(kycProxy));

        PropertyToken tokenImpl = new PropertyToken();
        UpgradeableBeacon b = new UpgradeableBeacon(address(tokenImpl), owner);
        BeaconProxy proxy = new BeaconProxy(
            address(b),
            abi.encodeCall(
                PropertyToken.initialize, ("Test Token", "TST", 1000 ether, 1, address(kycRegistry), owner)
            )
        );
        token = PropertyToken(address(proxy));

        kycRegistry.addUser(owner);
        kycRegistry.addUser(user1);
        token.setPauser(pauser);
    }

    function test_Pauser_canPause() public {
        vm.prank(pauser);
        token.pause();
        assertTrue(token.paused());
    }

    function test_Pauser_ownerCanStillPause() public {
        token.pause();
        assertTrue(token.paused());
    }

    function test_Pauser_attackerCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PropertyToken.NotPauserOrOwner.selector, attacker));
        token.pause();
    }

    function test_Pauser_cannotUnpause() public {
        token.pause();
        vm.prank(pauser);
        vm.expectRevert();
        token.unpause();
    }

    function test_Pauser_ownerCanUnpause() public {
        vm.prank(pauser);
        token.pause();
        token.unpause();
        assertFalse(token.paused());
    }

    function test_Pauser_onlyOwnerCanSetPauser() public {
        vm.prank(attacker);
        vm.expectRevert();
        token.setPauser(attacker);
    }

    function test_Pauser_setPauserEmitsEvent() public {
        address newPauser = makeAddr("newPauser");
        vm.expectEmit(true, true, false, true);
        emit PropertyToken.PauserUpdated(pauser, newPauser);
        token.setPauser(newPauser);
    }

    function test_Pauser_blocksTransferWhenPaused() public {
        vm.prank(pauser);
        token.pause();
        vm.expectRevert();
        token.transfer(user1, 10 ether);
    }

    function test_Pauser_resumeAfterUnpause() public {
        vm.prank(pauser);
        token.pause();
        token.unpause();
        token.transfer(user1, 10 ether);
        assertEq(token.balanceOf(user1), 10 ether);
    }
}
