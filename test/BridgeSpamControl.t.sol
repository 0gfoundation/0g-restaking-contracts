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

/// @notice Plan §1.5 / §2.D anti-spam coverage: per-token min cross-out amount + bps fee with
///         floor / cap clamps, applied to both LockRelease (`lockAndSend`) and MintBurn
///         (`burnAndSend`). Verifies admin gating, hard caps, recipient routing, and that the
///         cross-chain `BridgeOut` event carries the post-fee amount.
contract BridgeSpamControlTest is BridgeBaseTest {
    address internal feeSink;

    function setUp() public override {
        super.setUp();
        feeSink = makeAddr("feeSink");
    }

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
        agency.setSpamControl(address(token), 1 ether, 0, 0, 0, address(0));

        vm.expectRevert(IBridge.AmountTooSmall.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether - 1);
    }

    function test_minCrossOutAmount_revertsMintBurn() public {
        (BridgeERC20 token,) = _setupMB(100 ether);
        agency.setSpamControl(address(token), 5 ether, 0, 0, 0, address(0));

        vm.expectRevert(IBridge.AmountTooSmall.selector);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, 4 ether);
    }

    function test_minCrossOutAmount_atBoundaryPasses() public {
        (Token token, address remote) = _setupLR(100 ether);
        agency.setSpamControl(address(token), 1 ether, 0, 0, 0, address(0));

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, 1 ether, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
    }

    // -------------- bps fee + clamp behaviour --------------

    function test_bpsFee_basicLockRelease() public {
        (Token token, address remote) = _setupLR(100 ether);
        // 0.50% fee, no floor, generous cap.
        agency.setSpamControl(address(token), 0, 50, 0, type(uint256).max, feeSink);

        uint256 amount = 100 ether;
        uint256 expectedFee = (amount * 50) / 10_000; // 0.5 ether
        uint256 amountAfterFee = amount - expectedFee;

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amountAfterFee, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, amount);

        assertEq(token.balanceOf(feeSink), expectedFee, "fee forwarded to sink");
        assertEq(token.balanceOf(address(bridge)), amountAfterFee, "bridge holds amountAfterFee");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_bpsFee_basicMintBurn_withRecipient() public {
        (BridgeERC20 token, address remote) = _setupMB(100 ether);
        agency.setSpamControl(address(token), 0, 100, 0, type(uint256).max, feeSink); // 1%

        uint256 amount = 50 ether;
        uint256 expectedFee = (amount * 100) / 10_000; // 0.5 ether
        uint256 amountAfterFee = amount - expectedFee;

        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amountAfterFee, 1);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, amount);

        // feeSink received the fee live tokens (not burned).
        assertEq(token.balanceOf(feeSink), expectedFee);
        // Bridge burned `amountAfterFee`.
        assertEq(token.totalSupply(), supplyBefore - amountAfterFee);
        // Bridge holds nothing — fee was forwarded out before the burn.
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function test_feeMin_clampsUpwards() public {
        (Token token, address remote) = _setupLR(100 ether);
        // 0.10% bps but flat floor of 1 ether — small txs always pay 1 ether.
        agency.setSpamControl(address(token), 0, 10, 1 ether, type(uint256).max, feeSink);

        uint256 amount = 50 ether;
        // raw bps fee = 50 * 10 / 10000 = 0.05 ether → clamps up to 1 ether floor.
        uint256 expectedFee = 1 ether;
        uint256 amountAfterFee = amount - expectedFee;

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amountAfterFee, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, amount);

        assertEq(token.balanceOf(feeSink), expectedFee);
        assertEq(token.balanceOf(address(bridge)), amountAfterFee);
    }

    function test_feeMax_clampsDownwards() public {
        (Token token, address remote) = _setupLR(1000 ether);
        // 1% bps but cap at 2 ether — big txs pay flat 2 ether.
        agency.setSpamControl(address(token), 0, 100, 0, 2 ether, feeSink);

        uint256 amount = 1000 ether;
        // raw bps fee = 1000 * 100 / 10000 = 10 ether → clamps down to 2 ether cap.
        uint256 expectedFee = 2 ether;
        uint256 amountAfterFee = amount - expectedFee;

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amountAfterFee, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, amount);

        assertEq(token.balanceOf(feeSink), expectedFee);
        assertEq(token.balanceOf(address(bridge)), amountAfterFee);
    }

    function test_flatFee_zeroBpsUsesFeeMinAsFlat() public {
        (Token token, address remote) = _setupLR(100 ether);
        // Flat 0.5 ether fee, regardless of amount.
        agency.setSpamControl(address(token), 0, 0, 0.5 ether, 0.5 ether, feeSink);

        uint256 amount = 10 ether;
        uint256 expectedFee = 0.5 ether;
        uint256 amountAfterFee = amount - expectedFee;

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amountAfterFee, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, amount);

        assertEq(token.balanceOf(feeSink), expectedFee);
    }

    // -------------- fee-recipient routing --------------

    function test_setSpamControl_revertsLRFeeWithoutRecipient_bps() public {
        (Token token,) = _setupLR(100 ether);
        // LockRelease + non-zero bps + no recipient: fee tokens would lock permanently in the
        // bridge with no admin sweep. Disallowed by setSpamControl invariant.
        vm.expectRevert(IBridge.InvalidLockReleaseFeeConfig.selector);
        agency.setSpamControl(address(token), 0, 100, 0, type(uint256).max, address(0));
    }

    function test_setSpamControl_revertsLRFeeWithoutRecipient_flatMin() public {
        (Token token,) = _setupLR(100 ether);
        // Same invariant via the floor-only path (feeBps = 0, feeMin > 0).
        vm.expectRevert(IBridge.InvalidLockReleaseFeeConfig.selector);
        agency.setSpamControl(address(token), 0, 0, 1 ether, 1 ether, address(0));
    }

    function test_setSpamControl_acceptsLRZeroFeeWithoutRecipient() public {
        (Token token,) = _setupLR(100 ether);
        // LockRelease + recipient=0 + no fee at all: still allowed (this is the "no spam control"
        // configuration), only mode-incompatible fee combinations are rejected.
        agency.setSpamControl(address(token), 1 ether, 0, 0, 0, address(0));
        (uint256 minAmt,, uint256 fMin, uint256 fMax,) = bridge.spamControl(address(token));
        assertEq(minAmt, 1 ether);
        assertEq(fMin, 0);
        assertEq(fMax, 0);
    }

    function test_feeRecipientZero_mintBurn_burnsFullAmount() public {
        (BridgeERC20 token, address remote) = _setupMB(100 ether);
        agency.setSpamControl(address(token), 0, 100, 0, type(uint256).max, address(0));

        uint256 amount = 50 ether;
        uint256 expectedFee = 0.5 ether; // 1%
        uint256 amountAfterFee = amount - expectedFee;

        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amountAfterFee, 1);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, amount);

        // The fee is burned together with `amountAfterFee` (full `amount` retired from supply).
        assertEq(token.totalSupply(), supplyBefore - amount, "full amount burned when no fee sink");
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    // -------------- bridge-out event content --------------

    function test_bridgeOutEvent_carriesAmountAfterFee() public {
        (Token token, address remote) = _setupLR(100 ether);
        agency.setSpamControl(address(token), 0, 200, 0, type(uint256).max, feeSink); // 2%

        uint256 amount = 25 ether;
        uint256 expectedFee = (amount * 200) / 10_000; // 0.5 ether
        uint256 amountAfterFee = amount - expectedFee;

        // Strict event match: nonce, addresses, AND the post-fee amount.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, amountAfterFee, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, amount);
    }

    // -------------- fee >= amount edge case --------------

    function test_feeExceedsAmount_reverts() public {
        (Token token,) = _setupLR(100 ether);
        // Floor of 5 ether means anything <= 5 ether reverts.
        agency.setSpamControl(address(token), 0, 0, 5 ether, 5 ether, feeSink);

        vm.expectRevert(IBridge.FeeExceedsAmount.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 5 ether);

        vm.expectRevert(IBridge.FeeExceedsAmount.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 4 ether);
    }

    // -------------- admin / setter validation --------------

    function test_setSpamControl_rejectsFeeBpsAbove2000() public {
        (Token token,) = _setupLR(100 ether);
        vm.expectRevert(IBridge.FeeBpsTooHigh.selector);
        agency.setSpamControl(address(token), 0, 2001, 0, type(uint256).max, feeSink);
    }

    function test_setSpamControl_acceptsFeeBpsAt2000Cap() public {
        (Token token,) = _setupLR(100 ether);
        // Boundary: exactly the cap is allowed.
        agency.setSpamControl(address(token), 0, 2000, 0, type(uint256).max, feeSink);
        (, uint16 storedBps,,,) = bridge.spamControl(address(token));
        assertEq(storedBps, 2000);
    }

    function test_setSpamControl_rejectsFeeMinGreaterThanFeeMax() public {
        (Token token,) = _setupLR(100 ether);
        vm.expectRevert(IBridge.InvalidFeeBounds.selector);
        agency.setSpamControl(address(token), 0, 100, 2 ether, 1 ether, feeSink);
    }

    function test_setSpamControl_rejectsZeroToken() public {
        vm.expectRevert(IBridge.ZeroAddress.selector);
        agency.setSpamControl(address(0), 0, 0, 0, 0, feeSink);
    }

    function test_setSpamControl_onlyAgencyOwner() public {
        Token token = new Token("X");
        // alice is not the agency's owner.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.setSpamControl(address(token), 0, 100, 0, type(uint256).max, feeSink);
    }

    function test_setSpamControl_directBridgeCallRequiresAdminRole() public {
        Token token = new Token("X");
        // alice has neither ADMIN_ROLE nor any other role.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bridge.ADMIN_ROLE())
        );
        vm.prank(alice);
        bridge.setSpamControl(address(token), 0, 100, 0, type(uint256).max, feeSink);
    }

    function test_setSpamControl_emitsEvent() public {
        Token token = new Token("X");
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.SpamControlUpdated(address(token), 1 ether, 100, 0.1 ether, 5 ether, feeSink);
        agency.setSpamControl(address(token), 1 ether, 100, 0.1 ether, 5 ether, feeSink);
    }

    function test_setSpamControl_storedAndReadback() public {
        Token token = new Token("X");
        agency.setSpamControl(address(token), 7 ether, 250, 0.5 ether, 10 ether, feeSink);

        (uint256 minAmt, uint16 bps, uint256 fMin, uint256 fMax, address recip) = bridge.spamControl(address(token));
        assertEq(minAmt, 7 ether);
        assertEq(bps, 250);
        assertEq(fMin, 0.5 ether);
        assertEq(fMax, 10 ether);
        assertEq(recip, feeSink);
    }

    function test_defaultSpamControl_isNoOp() public {
        // No setSpamControl call → all defaults zero. lockAndSend should behave exactly as before.
        (Token token, address remote) = _setupLR(100 ether);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, 50 ether, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 50 ether);

        assertEq(token.balanceOf(address(bridge)), 50 ether);
        assertEq(token.balanceOf(feeSink), 0);
    }

    function test_clearSpamControl_byZeroingAllFields() public {
        (Token token,) = _setupLR(100 ether);
        agency.setSpamControl(address(token), 1 ether, 100, 0, type(uint256).max, feeSink);
        agency.setSpamControl(address(token), 0, 0, 0, 0, address(0));

        // Below previous min should now succeed.
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 0.1 ether);
        assertEq(token.balanceOf(feeSink), 0, "no fee taken after clear");
    }

    // -------------- MAX_FEE_BPS constant exposed --------------

    function test_maxFeeBpsConstant() public view {
        assertEq(bridge.MAX_FEE_BPS(), 2000);
    }
}
