// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console2} from "forge-std/Test.sol";
import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

/// @notice Pins the consensus-critical guarantee of park-then-deliver: a FULL block of inbound
///         messages (MaxBridgeMessagesPerBlock = 128) in the WORST-case distribution must all park
///         inside one 30M-gas system call, and the measured consumption must respect the sizing
///         rule (≤ 65% of the budget) that leaves headroom for future struct growth / EVM
///         repricing. The park loop performs no token calls and has no revert path beyond the
///         caller gate, so — unlike the old execute-in-system-call design — no message content can
///         make the batch fail; the only failure mode left is gas, which this test bounds.
contract BridgeBatchGasGuaranteeTest is BridgeBaseTest {
    /// @dev == MaxBridgeMessagesPerBlock, a CL/EL consensus parameter. Must stay identical in the
    ///      CL constants file (primary + both satellite branches), the reth 0g-bridge crate, and
    ///      here — four places, one value. Changing the budget requires re-running this
    ///      measurement; if the worst case exceeds the 65% ceiling, lower the budget rather than
    ///      shipping the estimate.
    uint256 constant N = 128;
    /// @dev Worst-case lane spread: many lanes maximize cold `lastParkedNonce` writes (one per
    ///      lane) on top of every message's own cold pending-slot writes.
    uint256 constant LANES = 32;
    uint256 constant PER_LANE = N / LANES; // 4
    /// @dev == the EL's fixed system-call gas budget (revm transact_system_call).
    uint256 constant SYSCALL_GAS = 30_000_000;
    /// @dev Sizing rule: worst-case all-park gas must stay ≤ 65% × 30M.
    uint256 constant PARK_GAS_CEILING = 19_500_000;

    function test_fullBlock_128_worstCase_allPark_under65pctOf30M() public {
        // 128 distinct (srcCID, nonce) pairs across 32 lanes, 4 per lane. Every storage slot
        // touched is cold: 5 pendingMessages slots + hasPending + the inboundConsumed read per
        // message, plus one lastParkedNonce slot per lane. Token / recipient addresses are
        // irrelevant to park (never called, never validated) but kept distinct anyway.
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](N);
        for (uint256 lane = 0; lane < LANES; ++lane) {
            uint64 srcCID = uint64(1000 + lane);
            for (uint256 j = 0; j < PER_LANE; ++j) {
                uint256 i = lane * PER_LANE + j;
                msgs[i] = _msgWithFee(
                    srcCID,
                    uint64(j + 1),
                    address(uint160(0xA0000 + lane)),
                    address(uint160(0xB0000 + i)),
                    1 ether + i,
                    address(uint160(0xC0C0)) // EL-injected proposer placeholder
                );
            }
        }

        // Outer call pinned to exactly the production system-call budget: if the worst case ever
        // outgrew 30M, this call would OOG-revert and fail the test loudly.
        uint256 g0 = gasleft();
        vm.prank(SYSTEM);
        bridge.parkRemoteMessages{gas: SYSCALL_GAS}(msgs);
        uint256 used = g0 - gasleft();

        console2.log("== all-park worst case: 128 msgs, 32 lanes x 4, all slots cold ==");
        console2.log("  total park gas        :", used);
        console2.log("  per-message average   :", used / N);
        console2.log("  ceiling (65% of 30M)  :", PARK_GAS_CEILING);
        console2.log("  headroom vs ceiling   :", PARK_GAS_CEILING - (used > PARK_GAS_CEILING ? 0 : used));

        // Every message parked; per-lane watermark advanced to its max nonce.
        for (uint256 lane = 0; lane < LANES; ++lane) {
            uint64 srcCID = uint64(1000 + lane);
            for (uint256 j = 0; j < PER_LANE; ++j) {
                uint256 i = lane * PER_LANE + j;
                uint64 nonce = uint64(j + 1);
                assertFalse(bridge.inboundConsumed(srcCID, nonce), "park consumes nothing");
                assertEq(bridge.pendingMessage(srcCID, nonce).amount, 1 ether + i, "every message parked");
            }
            assertEq(bridge.lastParkedNonce(srcCID), uint64(PER_LANE), "lane watermark advanced");
        }

        // The sizing-rule gate.
        assertLe(used, PARK_GAS_CEILING, "worst-case all-park must stay within 65% of the 30M system-call budget");
    }

    /// @notice Sentinel: this test's batch size IS the consensus budget. If
    ///         MaxBridgeMessagesPerBlock changes in the CL (primitives constants, primary + both
    ///         satellite branches) or the EL (reth 0g-bridge crate), this constant — and the
    ///         measurement above — must change with it.
    function test_budgetSentinel_matchesConsensusConstant() public pure {
        assertEq(N, 128, "N must equal MaxBridgeMessagesPerBlock (CL constants + reth 0g-bridge crate)");
        assertEq(LANES * PER_LANE, N, "lane spread must cover the full budget");
    }
}
