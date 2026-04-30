// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

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

    function test_localChainID() public view {
        assertEq(bridge.localChainID(), LOCAL_CID);
    }

    function test_tokenConfig_view() public {
        (Token token,) = _deployLockReleaseToken(alice, 100 ether);
        (bool enabled, IBridge.BridgeMode mode) = bridge.tokenConfig(address(token));
        assertTrue(enabled);
        assertEq(uint8(mode), uint8(IBridge.BridgeMode.LockRelease));
    }
}
