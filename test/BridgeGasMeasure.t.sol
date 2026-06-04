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

    function burn(uint256 amt) external {
        _burn(msg.sender, amt);
    }
}

/// @notice Measures, via the SYSTEM-CALL interface `executeRemoteMessages`, the gas to process
///         ONE inbound bridge request, isolating the ERC20-call portion. All measurements are the
///         COLD case (first touch of token + bridge storage) = the worst single-message cost.
///         Run: forge test --match-path test/BridgeGasMeasure.t.sol -vv
contract BridgeGasMeasureTest is BridgeBaseTest {
    address constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint64 constant SRC_CID = 99;

    function _run(IBridge.InboundMessage[] memory msgs) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);
        used = g0 - gasleft();
    }

    function test_gas_lockRelease_noFee() public {
        ProbeLR t = new ProbeLR();
        t.transfer(address(bridge), 1_000_000 ether);
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);

        IBridge.InboundMessage[] memory m = new IBridge.InboundMessage[](1);
        m[0] = _msgWithFee(SRC_CID, 1, address(t), makeAddr("r1"), 100 ether, address(0));
        uint256 total = _run(m);
        console2.log("== LockRelease, no fee (1 transfer) ==");
        console2.log("  total executeRemoteMessages gas :", total);
        console2.log("  of which ERC20 transfer (inside):", t.consumed());
        console2.log("  bridge framework overhead       :", total - t.consumed());
    }

    function test_gas_lockRelease_withFee() public {
        ProbeLR t = new ProbeLR();
        t.transfer(address(bridge), 1_000_000 ether);
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);
        agency.setSpamControl(address(t), 0, 100, 0, type(uint256).max); // 1% → 2 transfers

        IBridge.InboundMessage[] memory m = new IBridge.InboundMessage[](1);
        m[0] = _msgWithFee(SRC_CID, 1, address(t), makeAddr("r2"), 100 ether, makeAddr("p2"));
        uint256 total = _run(m);
        console2.log("== LockRelease, with fee (2 transfers) ==");
        console2.log("  total executeRemoteMessages gas :", total);
        console2.log("  of which ERC20 transfers (inside):", t.consumed());
        console2.log("  bridge framework overhead        :", total - t.consumed());
    }

    function test_gas_mintBurn_noFee() public {
        ProbeMB t = new ProbeMB();
        agency.addToken(address(t), IBridge.BridgeMode.MintBurn);

        IBridge.InboundMessage[] memory m = new IBridge.InboundMessage[](1);
        m[0] = _msgWithFee(SRC_CID, 1, address(t), makeAddr("r3"), 100 ether, address(0));
        uint256 total = _run(m);
        console2.log("== MintBurn, no fee (1 mint; generic token, NOT precompile) ==");
        console2.log("  total executeRemoteMessages gas :", total);
        console2.log("  of which ERC20 mint (inside)    :", t.consumed());
        console2.log("  bridge framework overhead       :", total - t.consumed());
    }

    function test_gas_mintBurn_withFee() public {
        ProbeMB t = new ProbeMB();
        agency.addToken(address(t), IBridge.BridgeMode.MintBurn);
        agency.setSpamControl(address(t), 0, 100, 0, type(uint256).max);

        IBridge.InboundMessage[] memory m = new IBridge.InboundMessage[](1);
        m[0] = _msgWithFee(SRC_CID, 1, address(t), makeAddr("r4"), 100 ether, makeAddr("p4"));
        uint256 total = _run(m);
        console2.log("== MintBurn, with fee (2 mints; generic token, NOT precompile) ==");
        console2.log("  total executeRemoteMessages gas :", total);
        console2.log("  of which ERC20 mints (inside)   :", t.consumed());
        console2.log("  bridge framework overhead       :", total - t.consumed());
        console2.log("  NOTE: native W0G replaces each mint with 100k precompile -> +~200k for 2 mints");
    }
}
