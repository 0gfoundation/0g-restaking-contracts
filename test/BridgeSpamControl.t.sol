// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @notice Source-side anti-spam coverage: per-token `minCrossOutAmount` floor enforced by
///         `lockAndSend` / `burnAndSend`, plus admin-side validation of `setSpamControl`.
///         Destination-side fee math (bps + min/max clamps + fee distribution to the EL-injected
///         proposer fee recipient) lives in `BridgeSystemCall.t.sol`.
contract BridgeSpamControlTest is BridgeBaseTest {
    // -------------- helpers --------------

    function _setupLR(
        uint256 supplyToAlice
    ) internal returns (Token token, address remote) {
        (token, remote) = _deployLockReleaseToken(alice, supplyToAlice);
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
    }

    function _setupMB(
        uint256 supplyToAlice
    ) internal returns (BridgeERC20 token, address remote) {
        (token, remote) = _deployMintBurnToken("MB", "MB");
        vm.prank(address(bridge));
        token.mint(alice, supplyToAlice);
        vm.prank(alice);
        token.approve(address(bridge), type(uint256).max);
    }

    // -------------- min cross-out amount --------------

    function test_minCrossOutAmount_revertsLockRelease() public {
        (Token token,) = _setupLR(100 ether);
        agency.setSpamControl(address(token), 1 ether, 0, 0, 0);

        vm.expectRevert(IBridge.AmountTooSmall.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether - 1);
    }

    function test_minCrossOutAmount_revertsMintBurn() public {
        (BridgeERC20 token,) = _setupMB(100 ether);
        agency.setSpamControl(address(token), 5 ether, 0, 0, 0);

        vm.expectRevert(IBridge.AmountTooSmall.selector);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, 4 ether);
    }

    function test_minCrossOutAmount_atBoundaryPasses() public {
        (Token token, address remote) = _setupLR(100 ether);
        agency.setSpamControl(address(token), 1 ether, 0, 0, 0);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, 1 ether, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
    }

    // -------------- bridge-out event content --------------

    /// @notice Source-side never deducts a fee — the full input `amount` is escrowed/burned and
    ///         emitted in `BridgeOut`. Fee accrual happens at the destination on inbound delivery.
    function test_bridgeOutEvent_carriesFullAmount() public {
        (Token token, address remote) = _setupLR(100 ether);
        // Source-side `feeBps/feeMin/feeMax` are stored but unused by `lockAndSend` /
        // `burnAndSend`; configure them anyway to confirm they don't perturb the outbound amount.
        agency.setSpamControl(address(token), 0, 200, 0, type(uint256).max);

        uint256 amount = 25 ether;

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amount, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, amount);

        // Bridge holds the entire amount, no fee siphoned off source-side.
        assertEq(token.balanceOf(address(bridge)), amount);
        assertEq(token.balanceOf(alice), 100 ether - amount);
    }

    function test_bridgeOutEvent_burnAndSend_carriesFullAmount() public {
        (BridgeERC20 token, address remote) = _setupMB(100 ether);
        agency.setSpamControl(address(token), 0, 100, 0, type(uint256).max);

        uint256 amount = 50 ether;
        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amount, 1);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, amount);

        // Full `amount` retired from supply; bridge holds nothing.
        assertEq(token.totalSupply(), supplyBefore - amount, "full amount burned source-side");
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    // -------------- admin / setter validation --------------

    function test_setSpamControl_rejectsFeeBpsAbove10000() public {
        (Token token,) = _setupLR(100 ether);
        vm.expectRevert(IBridge.FeeBpsTooHigh.selector);
        agency.setSpamControl(address(token), 0, 10_001, 0, type(uint256).max);
    }

    function test_setSpamControl_acceptsFeeBpsAt10000Cap() public {
        (Token token,) = _setupLR(100 ether);
        // Boundary: exactly the cap is allowed.
        agency.setSpamControl(address(token), 0, 10_000, 0, type(uint256).max);
        (, uint16 storedBps,,) = bridge.spamControl(address(token));
        assertEq(storedBps, 10_000);
    }

    function test_setSpamControl_rejectsFeeMinGreaterThanFeeMax() public {
        (Token token,) = _setupLR(100 ether);
        vm.expectRevert(IBridge.InvalidFeeBounds.selector);
        agency.setSpamControl(address(token), 0, 100, 2 ether, 1 ether);
    }

    function test_setSpamControl_rejectsZeroToken() public {
        vm.expectRevert(IBridge.ZeroAddress.selector);
        agency.setSpamControl(address(0), 0, 0, 0, 0);
    }

    function test_setSpamControl_onlyAgencyOwner() public {
        Token token = new Token("X");
        // alice is not the agency's owner.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.setSpamControl(address(token), 0, 100, 0, type(uint256).max);
    }

    function test_setSpamControl_directBridgeCallRequiresAdminRole() public {
        Token token = new Token("X");
        // alice has neither ADMIN_ROLE nor any other role.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bridge.ADMIN_ROLE())
        );
        vm.prank(alice);
        bridge.setSpamControl(address(token), 0, 100, 0, type(uint256).max);
    }

    function test_setSpamControl_emitsEvent() public {
        Token token = new Token("X");
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.SpamControlUpdated(address(token), 1 ether, 100, 0.1 ether, 5 ether);
        agency.setSpamControl(address(token), 1 ether, 100, 0.1 ether, 5 ether);
    }

    function test_setSpamControl_storedAndReadback() public {
        Token token = new Token("X");
        agency.setSpamControl(address(token), 7 ether, 250, 0.5 ether, 10 ether);

        (uint256 minAmt, uint16 bps, uint256 fMin, uint256 fMax) = bridge.spamControl(address(token));
        assertEq(minAmt, 7 ether);
        assertEq(bps, 250);
        assertEq(fMin, 0.5 ether);
        assertEq(fMax, 10 ether);
    }

    function test_defaultSpamControl_isNoOp() public {
        // No setSpamControl call → all defaults zero. lockAndSend should behave exactly as before.
        (Token token, address remote) = _setupLR(100 ether);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, 50 ether, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 50 ether);

        assertEq(token.balanceOf(address(bridge)), 50 ether);
    }

    function test_clearSpamControl_byZeroingAllFields() public {
        (Token token,) = _setupLR(100 ether);
        agency.setSpamControl(address(token), 1 ether, 100, 0, type(uint256).max);
        agency.setSpamControl(address(token), 0, 0, 0, 0);

        // Below previous min should now succeed.
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 0.1 ether);
        assertEq(token.balanceOf(address(bridge)), 0.1 ether);
    }

    // -------------- MAX_FEE_BPS constant exposed --------------

    function test_maxFeeBpsConstant() public view {
        assertEq(bridge.MAX_FEE_BPS(), 10_000);
    }
}
