// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {IBridge} from "../src/bridge/IBridge.sol";
import {Bridge} from "../src/bridge/Bridge.sol";

/// MintBurn token whose mint() consumes ALL forwarded gas and halts — the way a stateful
/// precompile (e.g. W0G over its mint cap) fails in revm: a precompile error that the EVM
/// treats as an exceptional halt (all gas burned), NOT a refunding revert. The per-message
/// gas cap must keep this from draining the whole batch.
contract HaltBurnToken is ERC20 {
    constructor() ERC20("HB", "") {}

    function mint(address, uint256) external pure {
        assembly {
            invalid()
        }
    }

    function burn(
        uint256
    ) external {}
}

/// Plain mintable token; every mint succeeds cheaply.
contract OkMintToken is ERC20 {
    constructor() ERC20("OK", "") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function burn(
        uint256
    ) external {}
}

/// Mintable token whose mint costs > PER_MESSAGE_GAS_CAP (writes 20 fresh slots ≈ 440k) so it
/// CANNOT succeed under the batch cap (parks) but CAN succeed under uncapped retry.
contract GasGuzzlerToken is ERC20 {
    constructor() ERC20("GG", "") {}

    function mint(address to, uint256 amt) external {
        for (uint256 i = 1; i <= 20; ++i) {
            assembly {
                sstore(i, i)
            }
        }
        _mint(to, amt);
    }

    function burn(
        uint256
    ) external {}
}

/// @notice Proves the executeRemoteMessages system call NEVER reverts the whole batch under the
///         real 30M gas budget, for a full block (MaxBridgeMessagesPerBlock = 48) of worst-case
///         (gas-burning) failures, all successes, or a mix — and that an over-cap message parks
///         in-batch yet recovers via uncapped retry.
contract BridgeBatchGasGuaranteeTest is BridgeBaseTest {
    address constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint64 constant SRC_CID = 99;
    uint256 constant N = 48; // == constants.MaxBridgeMessagesPerBlock
    uint256 constant SYSCALL_GAS = 30_000_000; // == revm transact_system_call budget

    function test_fullBlock_48_allFail_haltBurn_systemCallCommits() public {
        HaltBurnToken t = new HaltBurnToken();
        agency.addToken(address(t), IBridge.BridgeMode.MintBurn);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](N);
        for (uint256 i = 0; i < N; ++i) {
            msgs[i] =
                _msgWithFee(SRC_CID, uint64(i + 1), address(t), makeAddr(string(abi.encode(i))), 1 ether, address(0));
        }

        // Under EXACTLY the 30M system-call budget: must NOT out-of-gas revert the batch.
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages{gas: SYSCALL_GAS}(msgs);

        // Every message parked (none consumed, none delivered).
        for (uint64 i = 1; i <= N; ++i) {
            assertFalse(bridge.inboundConsumed(SRC_CID, i), "must not consume a halt-burn failure");
            assertEq(bridge.pendingMessage(SRC_CID, i).amount, 1 ether, "must park for retry");
        }
        assertEq(t.totalSupply(), 0, "nothing minted");
    }

    function test_fullBlock_48_allSuccess() public {
        OkMintToken t = new OkMintToken();
        agency.addToken(address(t), IBridge.BridgeMode.MintBurn);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](N);
        for (uint256 i = 0; i < N; ++i) {
            msgs[i] =
                _msgWithFee(SRC_CID, uint64(i + 1), address(t), makeAddr(string(abi.encode(i))), 1 ether, address(0));
        }

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages{gas: SYSCALL_GAS}(msgs);

        for (uint64 i = 1; i <= N; ++i) {
            assertTrue(bridge.inboundConsumed(SRC_CID, i), "must deliver");
            assertEq(bridge.pendingMessage(SRC_CID, i).amount, 0, "no pending on success");
        }
        assertEq(t.totalSupply(), N * 1 ether, "all minted exactly once");
    }

    function test_fullBlock_48_mixed_fail_and_success() public {
        HaltBurnToken bad = new HaltBurnToken();
        OkMintToken good = new OkMintToken();
        agency.addToken(address(bad), IBridge.BridgeMode.MintBurn);
        agency.addToken(address(good), IBridge.BridgeMode.MintBurn);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](N);
        for (uint256 i = 0; i < N; ++i) {
            address tok = (i % 2 == 0) ? address(bad) : address(good);
            msgs[i] = _msgWithFee(SRC_CID, uint64(i + 1), tok, makeAddr(string(abi.encode(i))), 1 ether, address(0));
        }

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages{gas: SYSCALL_GAS}(msgs);

        for (uint64 i = 1; i <= N; ++i) {
            if ((i - 1) % 2 == 0) {
                assertFalse(bridge.inboundConsumed(SRC_CID, i), "bad token parks");
                assertEq(bridge.pendingMessage(SRC_CID, i).amount, 1 ether);
            } else {
                assertTrue(bridge.inboundConsumed(SRC_CID, i), "good token delivers");
            }
        }
        assertEq(good.totalSupply(), (N / 2) * 1 ether);
    }

    function test_overCapMessage_parksInBatch_thenUncappedRetrySucceeds() public {
        GasGuzzlerToken t = new GasGuzzlerToken();
        agency.addToken(address(t), IBridge.BridgeMode.MintBurn);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        address recipient = makeAddr("ggRecipient");
        msgs[0] = _msgWithFee(SRC_CID, 1, address(t), recipient, 1 ether, address(0));

        // Batch path: capped at PER_MESSAGE_GAS_CAP (400k) < the ~440k this mint needs -> parks.
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages{gas: SYSCALL_GAS}(msgs);
        assertFalse(bridge.inboundConsumed(SRC_CID, 1), "over-cap message parks in batch");
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 1 ether);
        assertEq(t.balanceOf(recipient), 0);

        // Retry is uncapped (user-funded): the same message now has enough gas to succeed.
        bridge.retry(SRC_CID, 1);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1), "uncapped retry delivers the over-cap message");
        assertEq(t.balanceOf(recipient), 1 ether);
    }

    function test_perMessageGasCapConstant_is400k() public view {
        assertEq(Bridge(address(bridge)).PER_MESSAGE_GAS_CAP(), 400_000);
    }
}
