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

/// @notice Anti-spam coverage for the dual-fee model: source-side `minCrossOutAmount` floor,
///         struct-param `setSpamControl` validation, and the destination-side fee matrix charged
///         at deliver time — per-leg bps/min/max branches for the proposer and keeper legs,
///         combined-fee conservation, FeeExceedsAmount park-keeping, and the leg-skip edge cases.
contract BridgeSpamControlTest is BridgeBaseTest {
    uint64 constant SRC_CID = 99;

    address internal proposer;
    address internal keeper;

    function setUp() public override {
        super.setUp();
        proposer = makeAddr("proposer");
        keeper = makeAddr("keeper");
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

    /// @dev Park `(SRC_CID, nonce)` for `amount` of `token` with the standard proposer, then
    ///      deliver it as `keeper`.
    function _parkAndDeliver(address token, uint64 nonce, address recipient, uint256 amount) internal {
        _parkOne(_msgWithFee(SRC_CID, nonce, token, recipient, amount, proposer));
        vm.prank(keeper);
        bridge.deliver(SRC_CID, nonce);
    }

    // -------------- source side: min cross-out amount --------------

    function test_minCrossOutAmount_revertsLockRelease() public {
        (Token token,) = _setupLR(100 ether);
        agency.setSpamControl(address(token), _cfg(1 ether, 0, 0, 0, 0, 0, 0));

        vm.expectRevert(IBridge.AmountTooSmall.selector);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether - 1);
    }

    function test_minCrossOutAmount_revertsMintBurn() public {
        (BridgeERC20 token,) = _setupMB(100 ether);
        agency.setSpamControl(address(token), _cfg(5 ether, 0, 0, 0, 0, 0, 0));

        vm.expectRevert(IBridge.AmountTooSmall.selector);
        vm.prank(alice);
        bridge.burnAndSend(address(token), DST_CID, bob, 4 ether);
    }

    function test_minCrossOutAmount_atBoundaryPasses() public {
        (Token token, address remote) = _setupLR(100 ether);
        agency.setSpamControl(address(token), _cfg(1 ether, 0, 0, 0, 0, 0, 0));

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(LOCAL_CID, DST_CID, 1, address(token), remote, bob, 1 ether, 0);
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 1 ether);
    }

    // -------------- source side never deducts fees --------------

    /// @notice Source-side never deducts a fee — the full input `amount` is escrowed/burned and
    ///         emitted in `BridgeOut`. Both fee legs accrue at the destination at deliver time.
    function test_bridgeOutEvent_carriesFullAmount() public {
        (Token token, address remote) = _setupLR(100 ether);
        // Dest-side legs are stored but unused by `lockAndSend` / `burnAndSend`; configure both
        // anyway to confirm they don't perturb the outbound amount.
        agency.setSpamControl(address(token), _cfg(0, 200, 0, type(uint256).max, 100, 0, type(uint256).max));

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
        agency.setSpamControl(address(token), _cfg(0, 100, 0, type(uint256).max, 50, 0, type(uint256).max));

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

    function test_setSpamControl_rejectsCombinedBpsAbove10000() public {
        (Token token,) = _setupLR(100 ether);
        // Each leg individually under the cap; combined 5000 + 5001 > 10000.
        vm.expectRevert(IBridge.FeeBpsTooHigh.selector);
        agency.setSpamControl(address(token), _cfg(0, 5000, 0, type(uint256).max, 5001, 0, type(uint256).max));
    }

    function test_setSpamControl_rejectsSingleLegBpsAbove10000() public {
        (Token token,) = _setupLR(100 ether);
        vm.expectRevert(IBridge.FeeBpsTooHigh.selector);
        agency.setSpamControl(address(token), _cfg(0, 10_001, 0, type(uint256).max, 0, 0, 0));
        vm.expectRevert(IBridge.FeeBpsTooHigh.selector);
        agency.setSpamControl(address(token), _cfg(0, 0, 0, 0, 10_001, 0, type(uint256).max));
    }

    function test_setSpamControl_acceptsCombinedBpsAt10000Cap() public {
        (Token token,) = _setupLR(100 ether);
        // Boundary: exactly the cap is allowed.
        agency.setSpamControl(address(token), _cfg(0, 6000, 0, type(uint256).max, 4000, 0, type(uint256).max));
        IBridge.TokenSpamControl memory stored = bridge.spamControl(address(token));
        assertEq(stored.proposerFeeBps, 6000);
        assertEq(stored.keeperFeeBps, 4000);
    }

    function test_setSpamControl_rejectsProposerMinGreaterThanMax() public {
        (Token token,) = _setupLR(100 ether);
        vm.expectRevert(IBridge.InvalidFeeBounds.selector);
        agency.setSpamControl(address(token), _cfg(0, 100, 2 ether, 1 ether, 0, 0, 0));
    }

    function test_setSpamControl_rejectsKeeperMinGreaterThanMax() public {
        (Token token,) = _setupLR(100 ether);
        vm.expectRevert(IBridge.InvalidFeeBounds.selector);
        agency.setSpamControl(address(token), _cfg(0, 0, 0, 0, 100, 2 ether, 1 ether));
    }

    function test_setSpamControl_rejectsZeroToken() public {
        vm.expectRevert(IBridge.ZeroAddress.selector);
        agency.setSpamControl(address(0), _zeroCfg());
    }

    function test_setSpamControl_onlyAgencyOwner() public {
        Token token = new Token("X");
        // alice is not the agency's owner.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.setSpamControl(address(token), _cfg(0, 100, 0, type(uint256).max, 0, 0, 0));
    }

    function test_setSpamControl_directBridgeCallRequiresAdminRole() public {
        Token token = new Token("X");
        // alice has neither ADMIN_ROLE nor any other role.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bridge.ADMIN_ROLE())
        );
        vm.prank(alice);
        bridge.setSpamControl(address(token), _cfg(0, 100, 0, type(uint256).max, 0, 0, 0));
    }

    function test_setSpamControl_emitsEvent() public {
        Token token = new Token("X");
        IBridge.TokenSpamControl memory cfg = _cfg(1 ether, 100, 0.1 ether, 5 ether, 50, 0.05 ether, 2 ether);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.SpamControlUpdated(address(token), cfg);
        agency.setSpamControl(address(token), cfg);
    }

    function test_setSpamControl_storedAndReadback() public {
        Token token = new Token("X");
        agency.setSpamControl(address(token), _cfg(7 ether, 250, 0.5 ether, 10 ether, 30, 0.01 ether, 3 ether));

        IBridge.TokenSpamControl memory s = bridge.spamControl(address(token));
        assertEq(s.minCrossOutAmount, 7 ether);
        assertEq(s.proposerFeeBps, 250);
        assertEq(s.proposerFeeMin, 0.5 ether);
        assertEq(s.proposerFeeMax, 10 ether);
        assertEq(s.keeperFeeBps, 30);
        assertEq(s.keeperFeeMin, 0.01 ether);
        assertEq(s.keeperFeeMax, 3 ether);
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
        agency.setSpamControl(address(token), _cfg(1 ether, 100, 0, type(uint256).max, 0, 0, 0));
        agency.setSpamControl(address(token), _zeroCfg());

        // Below previous min should now succeed.
        vm.prank(alice);
        bridge.lockAndSend(address(token), DST_CID, bob, 0.1 ether);
        assertEq(token.balanceOf(address(bridge)), 0.1 ether);
    }

    function test_maxFeeBpsConstant() public view {
        assertEq(bridge.MAX_FEE_BPS(), 10_000);
    }

    // -------------- proposer leg: bps / min / max branches --------------

    function test_proposerFee_bpsBranch() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // 1% with inactive clamps for this magnitude; keeper leg disabled.
        agency.setSpamControl(address(token), _cfg(0, 100, 0, type(uint256).max, 0, 0, 0));
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 100 ether, proposer));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 99 ether, proposer, 1 ether, keeper, 0);
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        assertEq(token.balanceOf(bob), 99 ether);
        assertEq(token.balanceOf(proposer), 1 ether);
        assertEq(token.balanceOf(keeper), 0);
    }

    function test_proposerFee_clampsUpToMin() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // 0.10% bps with a 1 ether floor: raw fee on 10 ether = 0.01 → floor applies.
        agency.setSpamControl(address(token), _cfg(0, 10, 1 ether, 5 ether, 0, 0, 0));

        _parkAndDeliver(address(token), 1, bob, 10 ether);
        assertEq(token.balanceOf(bob), 9 ether, "amount - 1 ether floor");
        assertEq(token.balanceOf(proposer), 1 ether, "floor applied");
    }

    function test_proposerFee_clampsDownToMax() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // 0.10% bps with a 5 ether ceiling: raw fee on 10_000 ether = 10 → ceiling applies.
        agency.setSpamControl(address(token), _cfg(0, 10, 1 ether, 5 ether, 0, 0, 0));

        _parkAndDeliver(address(token), 1, bob, 10_000 ether);
        assertEq(token.balanceOf(bob), 10_000 ether - 5 ether, "amount - 5 ether ceiling");
        assertEq(token.balanceOf(proposer), 5 ether, "ceiling applied");
    }

    // -------------- keeper leg: bps / min / max branches --------------

    function test_keeperFee_bpsBranch() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), _cfg(0, 0, 0, 0, 100, 0, type(uint256).max));
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 100 ether, proposer));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 99 ether, address(0), 0, keeper, 1 ether);
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        assertEq(token.balanceOf(bob), 99 ether);
        assertEq(token.balanceOf(keeper), 1 ether);
        assertEq(token.balanceOf(proposer), 0);
    }

    function test_keeperFee_clampsUpToMin() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), _cfg(0, 0, 0, 0, 10, 1 ether, 5 ether));

        _parkAndDeliver(address(token), 1, bob, 10 ether);
        assertEq(token.balanceOf(bob), 9 ether);
        assertEq(token.balanceOf(keeper), 1 ether, "floor applied");
    }

    function test_keeperFee_clampsDownToMax() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), _cfg(0, 0, 0, 0, 10, 1 ether, 5 ether));

        _parkAndDeliver(address(token), 1, bob, 10_000 ether);
        assertEq(token.balanceOf(bob), 10_000 ether - 5 ether);
        assertEq(token.balanceOf(keeper), 5 ether, "ceiling applied");
    }

    // -------------- both legs: conservation --------------

    function test_bothLegs_conservation_mintBurn() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // Proposer 1%, keeper 0.5%.
        agency.setSpamControl(address(token), _cfg(0, 100, 0, type(uint256).max, 50, 0, type(uint256).max));

        uint256 amount = 100 ether;
        uint256 pFee = 1 ether;
        uint256 kFee = 0.5 ether;
        uint256 net = amount - pFee - kFee;
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, amount, proposer));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, net, proposer, pFee, keeper, kFee);
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        // 3-way conservation: net + proposerFee + keeperFee == inbound amount.
        assertEq(token.balanceOf(bob), net);
        assertEq(token.balanceOf(proposer), pFee);
        assertEq(token.balanceOf(keeper), kFee);
        assertEq(token.balanceOf(bob) + token.balanceOf(proposer) + token.balanceOf(keeper), amount);
        assertEq(token.totalSupply(), amount, "MintBurn mints exactly the inbound amount");
    }

    function test_bothLegs_conservation_lockRelease() public {
        Token token = new Token("LR");
        token.transfer(address(bridge), 1000 ether);
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);
        agency.setSpamControl(address(token), _cfg(0, 200, 0, type(uint256).max, 100, 0, type(uint256).max));

        uint256 amount = 50 ether;
        uint256 pFee = 1 ether; // 2%
        uint256 kFee = 0.5 ether; // 1%
        uint256 net = amount - pFee - kFee;

        _parkAndDeliver(address(token), 1, bob, amount);

        assertEq(token.balanceOf(bob), net);
        assertEq(token.balanceOf(proposer), pFee);
        assertEq(token.balanceOf(keeper), kFee);
        // All three legs release from the same escrow: bridge balance drops by the full amount.
        assertEq(token.balanceOf(address(bridge)), 1000 ether - amount);
    }

    // -------------- FeeExceedsAmount: stays parked, recoverable --------------

    function test_combinedFeeAtAmount_revertsAndStaysParked() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // 50% + 50% = 100% → combined fee == amount → FeeExceedsAmount.
        agency.setSpamControl(address(token), _cfg(0, 5000, 0, type(uint256).max, 5000, 0, type(uint256).max));
        uint256 amount = 100 ether;
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, amount, proposer));

        (bool deliverable,,,) = _deliverableOracle(SRC_CID, 1);
        assertFalse(deliverable, "oracle reports fee-blocked message as non-deliverable");

        vm.expectRevert(IBridge.FeeExceedsAmount.selector);
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, amount, "stays parked");
        assertEq(token.totalSupply(), 0, "nothing minted");

        // Admin rebalances → anyone can deliver, exactly once, with the new split.
        agency.setSpamControl(address(token), _cfg(0, 100, 0, type(uint256).max, 100, 0, type(uint256).max));
        (bool ok, uint256 net, uint256 pFee, uint256 kFee) = _deliverableOracle(SRC_CID, 1);
        assertTrue(ok);
        assertEq(net + pFee + kFee, amount, "oracle split conserves the inbound amount");

        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);
        assertEq(token.balanceOf(bob), 98 ether);
        assertEq(token.balanceOf(proposer), 1 ether);
        assertEq(token.balanceOf(keeper), 1 ether);
        assertEq(token.totalSupply(), amount, "minted exactly once");
    }

    function test_feeMinsSummingOverAmount_revert() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // Flat mins: 60 + 50 > 100 even though bps are zero.
        agency.setSpamControl(address(token), _cfg(0, 0, 60 ether, 60 ether, 0, 50 ether, 50 ether));
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 100 ether, proposer));

        vm.expectRevert(IBridge.FeeExceedsAmount.selector);
        bridge.deliver(SRC_CID, 1);
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 100 ether, "stays parked");
    }

    // -------------- leg-skip edge cases --------------

    function test_feeRecipientZero_skipsProposerLegOnly() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), _cfg(0, 100, 0, type(uint256).max, 50, 0, type(uint256).max));

        // feeRecipient = 0 (theoretical pre-MinerReward edge): proposer leg skipped, keeper leg
        // still paid — no value stuck on the zero address.
        uint256 amount = 100 ether;
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, amount, address(0)));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 99.5 ether, address(0), 0, keeper, 0.5 ether);
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        assertEq(token.balanceOf(bob), 99.5 ether);
        assertEq(token.balanceOf(keeper), 0.5 ether);
        assertEq(token.totalSupply(), amount, "no leg minted to the zero address");
    }

    /// @notice `keeperFeeMax == 0` forces the keeper leg to 0 even with nonzero bps — the
    ///         per-leg footgun is intentional (a token without keeper incentive relies on
    ///         self-claims or an operator bot). Pinned so a refactor interpreting max=0 as
    ///         "no cap" fails loudly.
    function test_keeperFeeMaxZero_forcesZeroKeeperFee() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), _cfg(0, 0, 0, 0, 100, 0, 0));

        _parkAndDeliver(address(token), 1, bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "full amount; keeper leg clamped to 0");
        assertEq(token.balanceOf(keeper), 0);
    }

    /// @notice Same footgun on the proposer leg.
    function test_proposerFeeMaxZero_forcesZeroProposerFee() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), _cfg(0, 100, 0, 0, 0, 0, 0));
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 10 ether, proposer));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 10 ether, address(0), 0, keeper, 0);
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.balanceOf(proposer), 0);
    }

    // -------------- off-chain fee formula matches actual on-chain split --------------

    /// @notice The fee split a keeper computes off-chain (same bps→clamp[min,max] formula the
    ///         contract applies in `_deliverOne`) must match what `deliver` actually pays out, under
    ///         non-trivial per-leg clamping (both legs hit their min/max bounds here). Pins the
    ///         formula against the contract so a divergence (e.g. clamp-order change) fails loudly.
    function test_offchainFeeFormula_matchesDeliveredSplit() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), _cfg(0, 123, 0.5 ether, 50 ether, 77, 0.25 ether, 20 ether));

        uint256 amount = 333 ether;
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, amount, proposer));
        (bool deliverable, uint256 net, uint256 pFee, uint256 kFee) = _deliverableOracle(SRC_CID, 1);
        assertTrue(deliverable);
        assertEq(net + pFee + kFee, amount);

        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);
        assertEq(token.balanceOf(bob), net, "off-chain net matches delivery");
        assertEq(token.balanceOf(proposer), pFee, "off-chain proposer fee matches delivery");
        assertEq(token.balanceOf(keeper), kFee, "off-chain keeper fee matches delivery");
    }
}
