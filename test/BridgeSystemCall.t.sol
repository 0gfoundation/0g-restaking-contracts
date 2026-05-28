// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @notice Covers `executeRemoteMessages`: caller restriction, multi-msg batching, replay, per-msg
///         try/catch failure isolation, `inboundConsumed` semantics, and the destination-side
///         fee distribution that splits inbound `amount` between `recipient` and the EL-injected
///         `feeRecipient`.
contract BridgeSystemCallTest is BridgeBaseTest {
    address constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint64 constant SRC_CID = 99;

    /// @dev Stand-in for the EL-injected proposer withdrawal address.
    address internal proposer;

    function setUp() public override {
        super.setUp();
        proposer = makeAddr("proposer");
    }

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
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 5 ether, address(0), 0);
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

    // -------------- destination-side fee distribution --------------

    function test_executeRemoteMessages_appliesFeeAndPaysToFeeRecipient_mintBurn() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // Destination-side: 1% fee, no clamps active for this magnitude.
        agency.setSpamControl(address(token), 0, 100, 0, type(uint256).max);

        uint256 amount = 100 ether;
        uint256 expectedFee = (amount * 100) / 10_000; // 1 ether
        uint256 toRecipient = amount - expectedFee;

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msgWithFee(SRC_CID, 1, address(token), bob, amount, proposer);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, toRecipient, proposer, expectedFee);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(token.balanceOf(bob), toRecipient, "recipient gets amount minus fee");
        assertEq(token.balanceOf(proposer), expectedFee, "proposer gets fee");
        assertEq(token.totalSupply(), amount, "total minted == inbound amount");
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    function test_executeRemoteMessages_appliesFeeAndPaysToFeeRecipient_lockRelease() public {
        Token token = new Token("LR");
        token.transfer(address(bridge), 1000 ether);
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);
        // Destination-side: 2% fee, no clamps active for this magnitude.
        agency.setSpamControl(address(token), 0, 200, 0, type(uint256).max);

        uint256 amount = 50 ether;
        uint256 expectedFee = (amount * 200) / 10_000; // 1 ether
        uint256 toRecipient = amount - expectedFee;

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msgWithFee(SRC_CID, 1, address(token), bob, amount, proposer);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, toRecipient, proposer, expectedFee);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(token.balanceOf(bob), toRecipient);
        assertEq(token.balanceOf(proposer), expectedFee);
        // Bridge balance dropped by full `amount` (recipient + fee both released from escrow).
        assertEq(token.balanceOf(address(bridge)), 1000 ether - amount);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    function test_executeRemoteMessages_skipsFeeWhenZero() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // No spam control configured → feeBps == 0 && feeMin == 0, fee path is a no-op.

        uint256 amount = 7 ether;

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msgWithFee(SRC_CID, 1, address(token), bob, amount, proposer);

        vm.expectEmit(true, false, false, true, address(bridge));
        // BridgeIn carries the full amount and feeRecipient=0 / fee=0 because the destination
        // chose not to charge a fee for this token.
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, amount, address(0), 0);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(token.balanceOf(bob), amount, "recipient gets full amount");
        assertEq(token.balanceOf(proposer), 0, "proposer gets nothing when feeBps=0");
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    function test_executeRemoteMessages_skipsFeeWhenFeeRecipientZero() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // Destination configured a 1% fee, but inbound message has feeRecipient = 0x0
        // (theoretical edge case — shouldn't happen in production because EL always injects
        // a non-zero coinbase post-MinerReward fork).
        agency.setSpamControl(address(token), 0, 100, 0, type(uint256).max);

        uint256 amount = 10 ether;

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msgWithFee(SRC_CID, 1, address(token), bob, amount, address(0));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, amount, address(0), 0);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        // Recipient gets the full amount; no tokens minted to the zero address.
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), amount, "no fee leg minted");
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    function test_executeRemoteMessages_clampsFeeAtMinAndMax() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // 0.10% bps with a 1 ether floor and a 5 ether ceiling.
        agency.setSpamControl(address(token), 0, 10, 1 ether, 5 ether);

        // Tiny inbound: raw bps fee = 10 * 10/10_000 = 0.01 ether → clamps up to floor (1 ether).
        IBridge.InboundMessage[] memory smallMsg = new IBridge.InboundMessage[](1);
        smallMsg[0] = _msgWithFee(SRC_CID, 1, address(token), alice, 10 ether, proposer);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(smallMsg);
        assertEq(token.balanceOf(alice), 9 ether, "small: amount - 1 ether floor");
        assertEq(token.balanceOf(proposer), 1 ether, "small: floor applied");

        // Huge inbound: raw bps fee = 10_000 * 10/10_000 = 10 ether → clamps down to ceiling (5 ether).
        IBridge.InboundMessage[] memory bigMsg = new IBridge.InboundMessage[](1);
        bigMsg[0] = _msgWithFee(SRC_CID, 2, address(token), bob, 10_000 ether, proposer);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(bigMsg);
        assertEq(token.balanceOf(bob), 10_000 ether - 5 ether, "big: amount - 5 ether ceiling");
        assertEq(token.balanceOf(proposer), 1 ether + 5 ether, "big: ceiling applied (cumulative)");
    }

    /// @notice Protocol max-batch sanity check. The CL/EL budget caps `InboundMessage[]` at 64
    ///         per block; verify the contract delivers a full 64-message batch without any
    ///         per-message failures and that the post-state matches the per-message expected
    ///         balances and `inboundConsumed` flags.
    function test_executeRemoteMessages_maxBatchOf64() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        uint256 batchSize = 64;

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](batchSize);
        for (uint256 i = 0; i < batchSize; ++i) {
            // nonces 1..64, alternating recipients alice / bob, amounts = (i+1) * 0.01 ether.
            address to = (i % 2 == 0) ? alice : bob;
            msgs[i] = _msg(SRC_CID, uint64(i + 1), address(token), to, (i + 1) * 0.01 ether);
        }

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        // Sum of (i+1)*0.01 for i in [0, 64) = (1+2+...+64) * 0.01 ether = 2080 * 0.01 = 20.8 ether.
        // Even indices (0..62) → alice: sum of 1,3,5,...,63 multiplied by 0.01 = 1024 * 0.01 = 10.24 ether.
        // Odd indices (1..63) → bob: sum of 2,4,6,...,64 multiplied by 0.01 = 1056 * 0.01 = 10.56 ether.
        assertEq(token.balanceOf(alice), 10.24 ether, "alice cumulative");
        assertEq(token.balanceOf(bob), 10.56 ether, "bob cumulative");
        assertEq(token.totalSupply(), 20.8 ether, "supply = sum of all amounts");
        for (uint64 n = 1; n <= 64; ++n) {
            assertTrue(bridge.inboundConsumed(SRC_CID, n), "all nonces consumed");
        }
    }

    /// @notice Partial fee config `(feeBps=X, feeMin=0, feeMax=0)` is intentionally treated as
    ///         "fee disabled": _computeFee falls through the early-return (feeBps != 0), computes
    ///         the raw bps fee, then clamps it down to feeMax==0 and returns 0. Pinning this so a
    ///         future refactor that interprets feeMax=0 as "no cap" would loudly fail.
    function test_executeRemoteMessages_feeBpsWithZeroFeeMax_yieldsZeroFee() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), 0, 100, 0, 0);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msgWithFee(SRC_CID, 1, address(token), bob, 10 ether, proposer);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 10 ether, address(0), 0);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(token.balanceOf(bob), 10 ether, "recipient gets full amount when feeMax=0 clamps fee to 0");
        assertEq(token.balanceOf(proposer), 0, "proposer gets nothing when feeMax=0");
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }
}
