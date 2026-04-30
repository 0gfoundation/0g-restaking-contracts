// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {MockA0GIBasePrecompile} from "./mocks/MockA0GIBasePrecompile.sol";
import {MockWrappedA0GI} from "./mocks/MockWrappedA0GI.sol";

/// @notice End-to-end W0G integration: Bridge → W0G → MockA0GIBasePrecompile.
///         Verifies caller propagation (precompile sees `caller == W0G_ADDRESS`),
///         per-minter cap tracking, mint-cap-insufficient revert is caught into pendingMessages,
///         and the symmetric burn path.
contract W0gIntegrationTest is BridgeBaseTest {
    address constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint64 constant SRC_CID = 99;

    /// @dev Production agency address (constant on-chain). Tests use it for setMinterCap.
    address constant W0G_AGENCY = 0xe1a5162F99E075f8C6681AE28191AB3aC250b468;

    MockA0GIBasePrecompile internal precompile;
    MockWrappedA0GI internal w0g;

    function setUp() public override {
        super.setUp();
        // Deploy the W0G ERC-20. Its constructor stores the precompile address.
        // We need precompile to know the W0G address — circular. Resolution: deploy a placeholder
        // first, then deploy W0G with the precompile address, then re-deploy the precompile with
        // the correct W0G address using vm.etch.
        // Simpler: predict the W0G address using vm.computeCreateAddress.
        address predictedW0G = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        precompile = new MockA0GIBasePrecompile(predictedW0G, W0G_AGENCY);
        w0g = new MockWrappedA0GI(address(precompile));
        require(address(w0g) == predictedW0G, "predicted address mismatch");

        // Grant MintBurn registration for W0G in the bridge.
        agency.addToken(address(w0g), IBridge.BridgeMode.MintBurn);
    }

    /// @dev W0G_AGENCY grants the bridge a per-minter cap.
    function _setBridgeCap(
        uint256 cap
    ) internal {
        vm.prank(W0G_AGENCY);
        precompile.setMinterCap(address(bridge), cap, 0);
    }

    function test_capRegistered() public {
        _setBridgeCap(100 ether);
        (uint256 cap, uint256 supply, uint256 init) = precompile.minterSupply(address(bridge));
        assertEq(cap, 100 ether);
        assertEq(supply, 0);
        assertEq(init, 0);
    }

    function test_systemMintsViaW0G_capTracked() public {
        _setBridgeCap(100 ether);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(w0g), bob, 25 ether);

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        assertEq(w0g.balanceOf(bob), 25 ether);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));

        (, uint256 supply,) = precompile.minterSupply(address(bridge));
        assertEq(supply, 25 ether);
    }

    function test_capInsufficient_landsInPending() public {
        _setBridgeCap(10 ether);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(w0g), bob, 25 ether);

        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);

        // Mint should have reverted; bridge shouldn't have minted anything.
        assertEq(w0g.balanceOf(bob), 0);
        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        // Pending message stored.
        IBridge.InboundMessage memory stored = bridge.pendingMessage(SRC_CID, 1);
        assertEq(stored.amount, 25 ether);
        assertEq(stored.localToken, address(w0g));
    }

    function test_retryAfterCapBumped_succeeds() public {
        _setBridgeCap(10 ether);

        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(w0g), bob, 25 ether);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);
        assertFalse(bridge.inboundConsumed(SRC_CID, 1));

        // Governance bumps cap.
        _setBridgeCap(100 ether);

        // Anyone retries.
        bridge.retry(SRC_CID, 1);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(w0g.balanceOf(bob), 25 ether);
    }

    function test_burnAndSend_reducesSupply() public {
        _setBridgeCap(100 ether);
        // Mint W0G to alice via system call first.
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(w0g), alice, 30 ether);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);
        assertEq(w0g.balanceOf(alice), 30 ether);

        (, uint256 supplyAfterMint,) = precompile.minterSupply(address(bridge));
        assertEq(supplyAfterMint, 30 ether);

        // burnAndSend uses transferFrom + burn(uint256); alice approves the bridge.
        vm.prank(alice);
        w0g.approve(address(bridge), type(uint256).max);

        // alice burns via the bridge.
        vm.prank(alice);
        bridge.burnAndSend(address(w0g), DST_CID, bob, 10 ether);

        assertEq(w0g.balanceOf(alice), 20 ether);
        assertEq(w0g.balanceOf(address(bridge)), 0); // burned, not held
        (, uint256 supplyAfterBurn,) = precompile.minterSupply(address(bridge));
        assertEq(supplyAfterBurn, 20 ether);
        assertEq(bridge.outboundNonce(DST_CID), 1);
    }

    function test_callerPropagation_precompileSeesW0GAsCaller() public {
        // Hit the mint path; if the precompile's caller-check were misconfigured (e.g. it saw the
        // Bridge instead of W0G), this would revert with "sender is not WA0GI".
        _setBridgeCap(100 ether);
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, 1, address(w0g), bob, 5 ether);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }
}
