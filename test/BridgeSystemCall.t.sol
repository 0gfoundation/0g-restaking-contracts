// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2, Vm} from "forge-std/Test.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @notice Covers `parkRemoteMessages` — the system call's park-only semantics: caller restriction,
///         pending/lastParkedNonce state writes, idempotent skips of consumed/parked nonces, the
///         no-token-calls / no-events / no-revert-paths guarantees, and over-budget batch stress.
///         Token movement and fee math live in the delivery path (`BridgeDeliver.t.sol`).
contract BridgeSystemCallTest is BridgeBaseTest {
    uint64 constant SRC_CID = 99;

    /// @dev Stand-in for the EL-injected proposer withdrawal address.
    address internal proposer;

    function setUp() public override {
        super.setUp();
        proposer = makeAddr("proposer");
    }

    function test_parkRemoteMessages_revertsIfNotSystem() public {
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(0xdead), bob, 1 ether);
        vm.expectRevert(IBridge.NotSystemCaller.selector);
        bridge.parkRemoteMessages(msgs);
    }

    function test_park_storesPendingAndAdvancesWatermark() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 5 ether, proposer));

        // Full struct parked verbatim, including the EL-injected feeRecipient.
        IBridge.InboundMessage memory stored = bridge.pendingMessage(SRC_CID, 1);
        assertEq(stored.srcChainID, SRC_CID);
        assertEq(stored.nonce, 1);
        assertEq(stored.localToken, address(token));
        assertEq(stored.recipient, bob);
        assertEq(stored.amount, 5 ether);
        assertEq(stored.feeRecipient, proposer);

        // Parked, not consumed; watermark advanced; deliverable.
        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.lastParkedNonce(SRC_CID), 1);
        (bool deliverable,,,) = _deliverableOracle(SRC_CID, 1);
        assertTrue(deliverable);

        // No token side effects at park time.
        assertEq(token.totalSupply(), 0, "park must not mint");
        assertEq(token.balanceOf(bob), 0);
    }

    function test_park_emitsNoEvents() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](3);
        msgs[0] = _msgWithFee(SRC_CID, 1, address(token), alice, 1 ether, proposer);
        msgs[1] = _msgWithFee(SRC_CID, 2, address(token), bob, 2 ether, proposer);
        msgs[2] = _msgWithFee(SRC_CID, 3, address(token), bob, 3 ether, proposer);

        vm.recordLogs();
        _park(msgs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "park must emit nothing (system-call logs are discarded anyway)");
    }

    /// @notice Park never consults token config — a disabled or entirely unknown token parks fine.
    ///         The check moves to deliver time, where a failure is recoverable.
    function test_park_ignoresTokenConfig() public {
        address ghost = makeAddr("ghostToken"); // never registered
        (BridgeERC20 disabled,) = _deployMintBurnToken("D", "D");
        agency.disableToken(address(disabled));

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](2);
        msgs[0] = _msgWithFee(SRC_CID, 1, ghost, bob, 1 ether, proposer);
        msgs[1] = _msgWithFee(SRC_CID, 2, address(disabled), bob, 2 ether, proposer);
        _park(msgs);

        assertEq(bridge.pendingMessage(SRC_CID, 1).localToken, ghost);
        assertEq(bridge.pendingMessage(SRC_CID, 2).localToken, address(disabled));
        assertEq(bridge.lastParkedNonce(SRC_CID), 2);
    }

    /// @notice All-zero garbage (zero token / recipient / amount) still parks — the park loop has
    ///         no revert path beyond the caller gate, so one bad message can never halt the batch.
    function test_park_zeroFieldMessage_stillParks() public {
        _parkOne(_msgWithFee(SRC_CID, 1, address(0), address(0), 0, address(0)));
        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.lastParkedNonce(SRC_CID), 1);
        IBridge.InboundMessage memory stored = bridge.pendingMessage(SRC_CID, 1);
        assertEq(stored.nonce, 1);
        assertEq(stored.amount, 0);
        // Parked garbage is inert: a zero amount can never out-pay its (zero) fees, so the
        // deliverability oracle reports it non-deliverable (0 >= 0 hits the fee-exceeds rule).
        (bool deliverable,,,) = _deliverableOracle(SRC_CID, 1);
        assertFalse(deliverable);
    }

    function test_park_multiLane_independentWatermarks() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        uint64 laneA = 100;
        uint64 laneB = 200;

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](4);
        msgs[0] = _msgWithFee(laneA, 1, address(token), alice, 1 ether, proposer);
        msgs[1] = _msgWithFee(laneA, 2, address(token), alice, 2 ether, proposer);
        msgs[2] = _msgWithFee(laneB, 7, address(token), bob, 3 ether, proposer);
        msgs[3] = _msgWithFee(laneB, 8, address(token), bob, 4 ether, proposer);
        _park(msgs);

        assertEq(bridge.lastParkedNonce(laneA), 2);
        assertEq(bridge.lastParkedNonce(laneB), 8);
        assertEq(bridge.pendingMessage(laneA, 2).amount, 2 ether);
        assertEq(bridge.pendingMessage(laneB, 7).amount, 3 ether);
        assertEq(token.totalSupply(), 0, "park moves no tokens");
    }

    function test_park_idempotent_skipsAlreadyParked() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 5 ether, proposer));
        // Re-park the same (srcCID, nonce) with different contents — must be skipped, not
        // overwritten (defensive: the CL watermark prevents duplicates reaching the contract).
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), alice, 7 ether, proposer));

        IBridge.InboundMessage memory stored = bridge.pendingMessage(SRC_CID, 1);
        assertEq(stored.recipient, bob, "first park wins");
        assertEq(stored.amount, 5 ether, "first park wins");
        assertEq(bridge.lastParkedNonce(SRC_CID), 1);
    }

    function test_park_idempotent_skipsConsumed() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 5 ether, address(0)));
        bridge.deliver(SRC_CID, 1);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(token.balanceOf(bob), 5 ether);

        // Re-park after consumption — skipped: no pending entry re-appears, no double delivery.
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 5 ether, address(0)));
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 0, "consumed nonce must not re-park");
        vm.expectRevert(IBridge.AlreadyConsumed.selector);
        bridge.deliver(SRC_CID, 1);
        assertEq(token.balanceOf(bob), 5 ether, "no double mint");
    }

    function test_park_lastParkedNonce_monotonicMax() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msgWithFee(SRC_CID, 5, address(token), bob, 1 ether, proposer));
        assertEq(bridge.lastParkedNonce(SRC_CID), 5);

        // A lower (but new) nonce parks fine yet never moves the watermark backwards.
        _parkOne(_msgWithFee(SRC_CID, 3, address(token), bob, 1 ether, proposer));
        assertEq(bridge.lastParkedNonce(SRC_CID), 5, "watermark is monotonic max");
        assertEq(bridge.pendingMessage(SRC_CID, 3).amount, 1 ether, "lower nonce still parked");
    }

    /// @notice Over-budget stress: the contract loop has no batch cap — the 128-messages-per-block
    ///         budget is a CL/EL consensus parameter enforced off-contract. Drive 200 messages
    ///         (well above the network budget) through one call and verify every one parks.
    function test_park_largeBatch200_overBudgetStress() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        uint256 batchSize = 200;

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](batchSize);
        for (uint256 i = 0; i < batchSize; ++i) {
            address to = (i % 2 == 0) ? alice : bob;
            msgs[i] = _msgWithFee(SRC_CID, uint64(i + 1), address(token), to, (i + 1) * 0.01 ether, proposer);
        }
        _park(msgs);

        for (uint64 n = 1; n <= batchSize; ++n) {
            assertFalse(bridge.inboundConsumed(SRC_CID, n), "park consumes nothing");
            assertEq(bridge.pendingMessage(SRC_CID, n).amount, uint256(n) * 0.01 ether, "every message parked");
        }
        assertEq(bridge.lastParkedNonce(SRC_CID), uint64(batchSize));
        assertEq(token.totalSupply(), 0, "park moves no tokens");
    }
}
