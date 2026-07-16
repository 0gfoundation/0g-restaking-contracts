// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @notice Covers user-facing entry points: lockAndSend / burnAndSend / outboundNonce monotonicity,
///         BridgeOut event content, and mode/disabled reverts.
contract BridgeUserPathsTest is BridgeBaseTest {
    function test_lockAndSend_happy() public {
        (Token token, address remote) = _deployLockReleaseToken(alice, 100 ether);

        vm.startPrank(alice);
        token.approve(address(bridge), 100 ether);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, 50 ether, 0);
        bridge.lockAndSend(address(token), DST_CID, bob, 50 ether);
        vm.stopPrank();

        // tokens moved to bridge
        assertEq(token.balanceOf(address(bridge)), 50 ether);
        assertEq(token.balanceOf(alice), 50 ether);
        // nonce incremented
        assertEq(bridge.outboundNonce(DST_CID), 1);
    }

    function test_burnAndSend_happy() public {
        (BridgeERC20 token, address remote) = _deployMintBurnToken("Sat USDT", "satUSDT");
        // Pre-mint to alice via the bridge holding MINTER_ROLE.
        vm.prank(address(bridge));
        token.mint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);

        // burnAndSend uses transferFrom + burn; alice must approve the bridge first.
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, 30 ether, 1);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, 30 ether);

        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.balanceOf(address(bridge)), 0); // burned, not held
        assertEq(token.totalSupply(), 70 ether);
        assertEq(bridge.outboundNonce(DST_CID), 1);
    }

    function test_outboundNonce_monotonic() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether);
        vm.startPrank(alice);
        token.approve(address(bridge), type(uint256).max);
        for (uint64 i = 1; i <= 5; ++i) {
            bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
            assertEq(bridge.outboundNonce(DST_CID), i);
        }
        vm.stopPrank();
    }

    function test_outboundNonce_independentPerDstCID() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether);
        // Map a second remote so the call to lockAndSend(DST_CID2) doesn't blow up.
        agency.mapRemote(address(token), uint64(7), makeAddr("remote2"));

        vm.startPrank(alice);
        token.approve(address(bridge), type(uint256).max);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
        bridge.lockAndSend(address(token), uint64(7), bob, 1 ether);
        vm.stopPrank();

        assertEq(bridge.outboundNonce(DST_CID), 2);
        assertEq(bridge.outboundNonce(uint64(7)), 1);
    }

    function test_lockAndSend_revertsIfMintBurnMode() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        vm.expectRevert(IBridge.WrongMode.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
    }

    function test_burnAndSend_revertsIfLockReleaseMode() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether);
        vm.expectRevert(IBridge.WrongMode.selector);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, 1 ether);
    }

    function test_lockAndSend_revertsIfDisabled() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether);
        agency.disableToken(address(token));
        vm.expectRevert(IBridge.TokenDisabled.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
    }

    function test_burnAndSend_revertsIfDisabled() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.disableToken(address(token));
        vm.expectRevert(IBridge.TokenDisabled.selector);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, 1 ether);
    }

    function test_lockAndSend_revertsOnAmountZero() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
        vm.expectRevert(IBridge.AmountTooSmall.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 0);
    }

    function test_burnAndSend_revertsOnAmountZero() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        vm.prank(address(bridge));
        token.mint(alice, 1 ether);
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
        vm.expectRevert(IBridge.AmountTooSmall.selector);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, 0);
    }

    /// @notice A zero recipient parks fine on the destination but can never be delivered, so the
    ///         source funds would be locked with no recovery. Must be rejected at the source.
    function test_lockAndSend_revertsOnZeroRecipient() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
        vm.expectRevert(IBridge.ZeroAddress.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, address(0), 1 ether);
    }

    /// @notice Same for MintBurn — more critical because the tokens would be burned, not just locked.
    function test_burnAndSend_revertsOnZeroRecipient() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        vm.prank(address(bridge));
        token.mint(alice, 1 ether);
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
        vm.expectRevert(IBridge.ZeroAddress.selector);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, address(0), 1 ether);
    }

    /// @notice Unmapping a single route (remoteToken_ = address(0)) deprecates just that
    ///         (token, dstCID): lockAndSend to it reverts, while the token's route to another
    ///         chain and its enabled flag are untouched.
    function test_mapRemoteToken_zeroUnmapsSingleRoute() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether); // mapped at DST_CID
        uint64 otherCID = uint64(7);
        agency.mapRemote(address(token), otherCID, makeAddr("remoteOther"));
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);

        // Deprecate the DST_CID route.
        agency.mapRemote(address(token), DST_CID, address(0));
        assertEq(bridge.remoteToken(address(token), DST_CID), address(0));

        // That route is now closed...
        vm.expectRevert(IBridge.RemoteTokenNotMapped.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);

        // ...but the other route still works (token not disabled).
        vm.prank(alice);
        bridge.lockAndSend(address(token), otherCID, bob, 1 ether);
        assertEq(bridge.outboundNonce(otherCID), 1);
    }

    function test_tokenConfig_view() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether);
        (bool enabled, IBridge.BridgeMode mode) = bridge.tokenConfig(address(token));
        assertTrue(enabled);
        assertEq(uint8(mode), uint8(IBridge.BridgeMode.LockRelease));
    }

    /// @notice Registering a LockRelease token but forgetting to map a remote must block
    ///         lockAndSend on the source side. If we allowed it, the emitted
    ///         BridgeOut.remoteToken would be address(0), the destination would resolve
    ///         localToken=0, and the resulting pending message would be permanently
    ///         non-deliverable (token 0 always disabled; pending storage can't be
    ///         repaired by later configuring the source mapping).
    function test_lockAndSend_revertsIfRemoteNotMapped() public {
        Token token = new Token("MockLR");
        token.transfer(alice, 100 ether);
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);
        // Note: agency.mapRemote NOT called.

        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
        vm.expectRevert(IBridge.RemoteTokenNotMapped.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
    }

    /// @notice Same as the LockRelease case but for MintBurn — even more critical because the
    ///         user's tokens would be burned (not just locked) before the message went pending.
    function test_burnAndSend_revertsIfRemoteNotMapped() public {
        bytes32 salt = keccak256("noMapping");
        address t = agency.deployAndAddBridgeToken("X", "X", 18, salt);
        BridgeERC20 token = BridgeERC20(t);
        // Note: agency.mapRemote NOT called.

        vm.prank(address(bridge));
        token.mint(alice, 1 ether);
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
        vm.expectRevert(IBridge.RemoteTokenNotMapped.selector);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, 1 ether);
    }

    /// @notice The mapping setter still rejects a zero LOCAL token (a malformed mapping), even
    ///         though a zero REMOTE token is now a valid explicit unmap.
    function test_mapRemoteToken_revertsOnZeroLocal() public {
        vm.expectRevert(IBridge.ZeroAddress.selector);
        agency.mapRemote(address(0), uint64(9), makeAddr("remote"));
    }
}

/// @notice Covers the three Bridge admin setters that BridgeAgency proxies to. The agency-side
///         ownership gating is exercised in BridgeAgency.t.sol; this class pins the underlying
///         `ADMIN_ROLE` check on Bridge itself, so a future refactor that swapped ADMIN_ROLE
///         for DEFAULT_ADMIN_ROLE on any of these would fail loudly.
contract BridgeAdminEntrypointTest is BridgeBaseTest {
    function test_configureToken_directBridgeCallRequiresAdminRole() public {
        Token token = new Token("X");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bridge.ADMIN_ROLE())
        );
        vm.prank(alice);
        bridge.configureToken(address(token), true, IBridge.BridgeMode.LockRelease);
    }

    function test_mapRemoteToken_directBridgeCallRequiresAdminRole() public {
        Token token = new Token("X");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bridge.ADMIN_ROLE())
        );
        vm.prank(alice);
        bridge.mapRemoteToken(address(token), uint64(7), makeAddr("remote"));
    }

    function test_deployBridgeERC20_directBridgeCallRequiresAdminRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bridge.ADMIN_ROLE())
        );
        vm.prank(alice);
        bridge.deployBridgeERC20("X", "X", 18, bytes32(0));
    }
}
