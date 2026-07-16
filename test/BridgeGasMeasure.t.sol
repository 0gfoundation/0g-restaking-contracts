// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

/// Standard OZ ERC20 (LockRelease), instrumented to record gas consumed INSIDE its own
/// transfer() across all calls in a tx. SafeERC20.safeTransfer routes through transfer().
contract ProbeLR is ERC20 {
    uint256 public consumed;

    constructor() ERC20("USDT", "") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        uint256 g = gasleft();
        bool r = super.transfer(to, amt);
        consumed += g - gasleft();
        return r;
    }
}

/// Mintable ERC20 (MintBurn) implementing the IBurnable surface the Bridge calls, instrumented
/// to record gas consumed inside mint(). Represents a GENERIC bridged-in token (BridgeERC20-like);
/// the native W0G path instead routes mint() to the WrappedA0GIBase precompile (fixed 100k/mint).
contract ProbeMB is ERC20 {
    uint256 public consumed;

    constructor() ERC20("MB", "") {
        // Seed totalSupply nonzero so measured mints pay the realistic nonzero->nonzero
        // totalSupply SSTORE (~5k), not a fresh-token zero->nonzero (~22k) artifact.
        _mint(address(0xdEaD), 1 ether);
    }

    function mint(address to, uint256 amt) external {
        uint256 g = gasleft();
        _mint(to, amt);
        consumed += g - gasleft();
    }

    function burn(
        uint256 amt
    ) external {
        _burn(msg.sender, amt);
    }
}

/// @notice Measures both halves of park-then-deliver in isolation, feeding the keeper-bot batch
///         sizing downstream:
///         - single-message park cost, cold lane vs warm lane (the system-call side);
///         - single-message deliver cost for LockRelease / MintBurn, with and without the dual
///           proposer+keeper fee legs (the keeper-tx side);
///         - deliverBatch amortization across 64 messages.
///         Deliver figures model the production shape — park happens in an earlier block, so the
///         bridge/token storage is force-cooled (vm.cool) between park and the measured deliver.
///         Figures EXCLUDE the delivery tx's intrinsic cost (21k + calldata); add it when sizing
///         keeper batches.
///         Run: forge test --match-path test/BridgeGasMeasure.t.sol -vv
contract BridgeGasMeasureTest is BridgeBaseTest {
    uint64 constant SRC_CID = 99;

    address internal proposer;
    address internal keeper;

    function setUp() public override {
        super.setUp();
        proposer = makeAddr("proposer");
        keeper = makeAddr("keeper");
    }

    function _parkGas(
        IBridge.InboundMessage[] memory msgs
    ) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        vm.prank(SYSTEM);
        bridge.parkRemoteMessages(msgs);
        used = g0 - gasleft();
    }

    /// @dev Cool the bridge proxy (its storage holds the parked message) and the token so the
    ///      measured deliver pays production-like cold access costs.
    function _coolForDeliver(
        address token
    ) internal {
        vm.cool(address(bridge));
        vm.cool(token);
    }

    function _deliverGas(
        uint64 nonce
    ) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        vm.prank(keeper);
        bridge.deliver(SRC_CID, nonce);
        used = g0 - gasleft();
    }

    // -------------- park --------------

    function test_gas_park_coldVsWarmLane() public {
        address token = makeAddr("anyToken"); // park never touches the token

        // Cold: first message of a fresh lane — all slots cold incl. the lane's lastParkedNonce.
        IBridge.InboundMessage[] memory first = new IBridge.InboundMessage[](1);
        first[0] = _msgWithFee(SRC_CID, 1, token, makeAddr("r1"), 100 ether, proposer);
        uint256 cold = _parkGas(first);

        // Warm lane: next message of the now-active lane in the same block — the lane watermark
        // slot is warm, but the new nonce's pending slots are still cold (fresh keys).
        IBridge.InboundMessage[] memory second = new IBridge.InboundMessage[](1);
        second[0] = _msgWithFee(SRC_CID, 2, token, makeAddr("r2"), 100 ether, proposer);
        uint256 warmLane = _parkGas(second);

        console2.log("== park single message ==");
        console2.log("  cold lane (first msg of lane)  :", cold);
        console2.log("  warm lane (subsequent in block):", warmLane);
    }

    // -------------- deliver: LockRelease --------------

    function test_gas_deliver_lockRelease_noFee() public {
        ProbeLR t = new ProbeLR();
        t.transfer(address(bridge), 1_000_000 ether);
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);

        _parkOne(_msgWithFee(SRC_CID, 1, address(t), makeAddr("r1"), 100 ether, proposer));
        _coolForDeliver(address(t));

        uint256 total = _deliverGas(1);
        console2.log("== deliver LockRelease, no fee (1 transfer) ==");
        console2.log("  total deliver gas               :", total);
        console2.log("  of which ERC20 transfer (inside):", t.consumed());
        console2.log("  bridge framework overhead       :", total - t.consumed());
    }

    function test_gas_deliver_lockRelease_dualFee() public {
        ProbeLR t = new ProbeLR();
        t.transfer(address(bridge), 1_000_000 ether);
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);
        // 1% proposer + 0.5% keeper → 3 transfers.
        agency.setSpamControl(address(t), _cfg(0, 100, 0, type(uint256).max, 50, 0, type(uint256).max));

        _parkOne(_msgWithFee(SRC_CID, 1, address(t), makeAddr("r2"), 100 ether, proposer));
        _coolForDeliver(address(t));

        uint256 total = _deliverGas(1);
        console2.log("== deliver LockRelease, dual fee (3 transfers) ==");
        console2.log("  total deliver gas                :", total);
        console2.log("  of which ERC20 transfers (inside):", t.consumed());
        console2.log("  bridge framework overhead        :", total - t.consumed());
    }

    // -------------- deliver: MintBurn --------------

    function test_gas_deliver_mintBurn_noFee() public {
        ProbeMB t = new ProbeMB();
        agency.addToken(address(t), IBridge.BridgeMode.MintBurn);

        _parkOne(_msgWithFee(SRC_CID, 1, address(t), makeAddr("r3"), 100 ether, proposer));
        _coolForDeliver(address(t));

        uint256 total = _deliverGas(1);
        console2.log("== deliver MintBurn, no fee (1 mint; generic token, NOT precompile) ==");
        console2.log("  total deliver gas            :", total);
        console2.log("  of which ERC20 mint (inside) :", t.consumed());
        console2.log("  bridge framework overhead    :", total - t.consumed());
    }

    function test_gas_deliver_mintBurn_dualFee() public {
        ProbeMB t = new ProbeMB();
        agency.addToken(address(t), IBridge.BridgeMode.MintBurn);
        agency.setSpamControl(address(t), _cfg(0, 100, 0, type(uint256).max, 50, 0, type(uint256).max));

        _parkOne(_msgWithFee(SRC_CID, 1, address(t), makeAddr("r4"), 100 ether, proposer));
        _coolForDeliver(address(t));

        uint256 total = _deliverGas(1);
        console2.log("== deliver MintBurn, dual fee (3 mints; generic token, NOT precompile) ==");
        console2.log("  total deliver gas            :", total);
        console2.log("  of which ERC20 mints (inside):", t.consumed());
        console2.log("  bridge framework overhead    :", total - t.consumed());
        console2.log("  NOTE: native W0G replaces each mint with a 100k precompile call -> +~300k for 3 mints");
    }

    // -------------- deliverBatch amortization --------------

    function test_gas_deliverBatch_amortized64() public {
        ProbeMB t = new ProbeMB();
        agency.addToken(address(t), IBridge.BridgeMode.MintBurn);
        agency.setSpamControl(address(t), _cfg(0, 100, 0, type(uint256).max, 50, 0, type(uint256).max));

        uint256 batch = 64;
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](batch);
        for (uint256 i = 0; i < batch; ++i) {
            msgs[i] =
                _msgWithFee(SRC_CID, uint64(i + 1), address(t), address(uint160(0xB0000 + i)), 100 ether, proposer);
        }
        _park(msgs);
        _coolForDeliver(address(t));

        uint64[] memory nonces = new uint64[](batch);
        for (uint256 i = 0; i < batch; ++i) {
            nonces[i] = uint64(i + 1);
        }
        uint256 g0 = gasleft();
        vm.prank(keeper);
        bridge.deliverBatch(SRC_CID, nonces);
        uint256 used = g0 - gasleft();

        for (uint64 n = 1; n <= batch; ++n) {
            assertTrue(bridge.inboundConsumed(SRC_CID, n), "batch must deliver everything");
        }

        console2.log("== deliverBatch, 64 MintBurn messages, dual fee ==");
        console2.log("  total deliverBatch gas:", used);
        console2.log("  amortized per message :", used / batch);
        console2.log("  (keeper batch sizing: add 21k intrinsic + ~16/nonce calldata per tx)");
    }
}
