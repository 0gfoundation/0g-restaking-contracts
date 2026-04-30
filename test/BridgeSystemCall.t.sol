// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @notice Covers `executeRemoteMessages`: caller restriction, multi-msg batching, replay, per-msg
///         try/catch failure isolation, and inboundConsumed semantics.
contract BridgeSystemCallTest is BridgeBaseTest {
    address constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint64 constant SRC_CID = 99;

    function test_executeRemoteMessages_revertsIfNotSystem() public {
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(0xdead), bob, 1 ether);
        vm.expectRevert(IBridge.NotSystemCaller.selector);
        bridge.executeRemoteMessages(msgs);
    }

    function test_executeRemoteMessages_singleMintBurn() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(token), bob, 5 ether);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 5 ether);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(token.balanceOf(bob), 5 ether);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    function test_executeRemoteMessages_singleLockRelease() public {
        // pre-fund the bridge with the token
        Token token = new Token("LR");
        token.transfer(address(bridge), 100 ether);
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(token), bob, 25 ether);

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(token.balanceOf(bob), 25 ether);
        assertEq(token.balanceOf(address(bridge)), 75 ether);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    function test_executeRemoteMessages_multiBatch() public {
        (BridgeERC20 mb,) = _deployMintBurnToken("X", "X");
        Token lr = new Token("LR");
        lr.transfer(address(bridge), 100 ether);
        agency.addToken(address(lr), IBridge.BridgeMode.LockRelease);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](3);
        msgs[0] = _msg(SRC_CID, 1, address(mb), alice, 1 ether);
        msgs[1] = _msg(SRC_CID, 2, address(lr), alice, 2 ether);
        msgs[2] = _msg(SRC_CID, 3, address(mb), bob, 3 ether);

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(mb.balanceOf(alice), 1 ether);
        assertEq(mb.balanceOf(bob), 3 ether);
        assertEq(lr.balanceOf(alice), 2 ether);
        for (uint64 n = 1; n <= 3; ++n) {
            assertTrue(bridge.inboundConsumed(SRC_CID, n));
        }
    }

    function test_executeRemoteMessages_replayEmitsFailedAndContinues() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");

        // First execution succeeds.
        IBridge.InboundMessage[] memory msgs1 = new IBridge.InboundMessage[](1);
        msgs1[0] = _msg(SRC_CID, 1, address(token), bob, 5 ether);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs1);
        assertEq(token.balanceOf(bob), 5 ether);

        // Second time, same nonce — should emit Failed("replay") and not double-mint.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeMessageFailed(SRC_CID, 1, bytes("replay"));
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs1);
        assertEq(token.balanceOf(bob), 5 ether);
    }

    function test_executeRemoteMessages_disabledTokenLandsInPending() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.disableToken(address(token));

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(token), bob, 5 ether);

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(token.balanceOf(bob), 0);
        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        IBridge.InboundMessage memory stored = bridge.pendingMessage(SRC_CID, 1);
        assertEq(stored.localToken, address(token));
        assertEq(stored.recipient, bob);
        assertEq(stored.amount, 5 ether);
    }

    function test_executeRemoteMessages_failureInMiddleOfBatchOthersSucceed() public {
        (BridgeERC20 a,) = _deployMintBurnToken("A", "A");
        (BridgeERC20 b,) = _deployMintBurnToken("B", "B");
        agency.disableToken(address(b)); // middle msg will fail

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](3);
        msgs[0] = _msg(SRC_CID, 1, address(a), alice, 1 ether);
        msgs[1] = _msg(SRC_CID, 2, address(b), alice, 2 ether);
        msgs[2] = _msg(SRC_CID, 3, address(a), bob, 3 ether);

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(a.balanceOf(alice), 1 ether);
        assertEq(a.balanceOf(bob), 3 ether);
        assertEq(b.balanceOf(alice), 0);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertFalse(bridge.inboundConsumed(SRC_CID, 2));
        assertTrue(bridge.inboundConsumed(SRC_CID, 3));
        assertEq(bridge.pendingMessage(SRC_CID, 2).amount, 2 ether);
    }
}
