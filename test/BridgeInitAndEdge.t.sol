// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeAgency} from "../src/bridge/BridgeAgency.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @notice Covers `Bridge.initialize` zero-address rejection on each argument, re-initialization
///         rejection for all three upgradeable contracts, and two delivery edge cases not covered
///         elsewhere: a LockRelease escrow shortfall keeping a message parked (then delivering once
///         topped up) and an empty `deliverBatch` no-op.
contract BridgeInitAndEdgeTest is BridgeBaseTest {
    uint64 constant SRC_CID = 99;

    // ============= Bridge.initialize zero-address branches =============

    /// @dev Deploy a fresh Bridge impl + beacon, then a proxy whose init args we control, so each
    ///      argument can be probed for the ZeroAddress revert independently of the base setUp wiring.
    function _bridgeInitRevertsOnZero(address beacon_, address agency_, address admin_) internal {
        Bridge impl = new Bridge();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), owner);
        bytes memory init = abi.encodeCall(Bridge.initialize, (beacon_, agency_, admin_));
        vm.expectRevert(IBridge.ZeroAddress.selector);
        new BeaconProxy(address(b), init);
    }

    function test_initialize_revertsZeroBeacon() public {
        _bridgeInitRevertsOnZero(address(0), makeAddr("agency"), makeAddr("admin"));
    }

    function test_initialize_revertsZeroAgency() public {
        _bridgeInitRevertsOnZero(makeAddr("beacon"), address(0), makeAddr("admin"));
    }

    function test_initialize_revertsZeroAdmin() public {
        _bridgeInitRevertsOnZero(makeAddr("beacon"), makeAddr("agency"), address(0));
    }

    // ============= re-initialization rejection =============

    /// @notice The Bridge proxy is already initialized in setUp; a second `initialize` must revert
    ///         with OZ's `InvalidInitialization`, so the agency/admin roles can never be re-seeded.
    function test_bridge_reinitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        bridge.initialize(address(bridgeERC20Beacon), address(agency), owner);
    }

    function test_agency_reinitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        agency.initialize(address(bridge), address(bridgeERC20Beacon), owner);
    }

    function test_bridgeERC20_reinitializeReverts() public {
        address t = agency.deployAndAddBridgeToken("RE", "RE", bytes32(uint256(0xACE)));
        BridgeERC20 token = BridgeERC20(t);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize("RE", "RE", address(bridge));
    }

    // ============= LockRelease escrow shortfall keeps message parked =============

    /// @notice For LockRelease, delivery releases from the bridge's own balance. If the escrow is
    ///         short of the inbound amount the `safeTransfer` reverts and the message stays parked
    ///         (consumed flag NOT flipped); topping up the escrow lets anyone deliver it afterward.
    function test_deliver_lockRelease_escrowShortfall_staysParked() public {
        Token token = new Token("LR");
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);

        // Escrow only 10 ether but the inbound message wants 25 — release must fail.
        token.transfer(address(bridge), 10 ether);
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 25 ether, address(0)));

        // ERC20 transfer of more than balance reverts; SafeERC20 bubbles it. Delivery fails.
        vm.expectRevert();
        bridge.deliver(SRC_CID, 1);

        // Message stays claimable: not consumed, still parked, recipient unpaid.
        assertFalse(bridge.inboundConsumed(SRC_CID, 1), "must not be marked consumed on failed release");
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 25 ether, "stays parked");
        assertEq(token.balanceOf(bob), 0, "recipient unpaid");
        (bool deliverable,,,) = bridge.previewDeliver(SRC_CID, 1);
        assertTrue(deliverable, "bridge-side checks still pass; only the token release is short");

        // Top up the escrow so it covers the full inbound amount, then deliver succeeds.
        token.transfer(address(bridge), 15 ether); // escrow now 25 ether
        bridge.deliver(SRC_CID, 1);
        assertEq(token.balanceOf(bob), 25 ether);
        assertEq(token.balanceOf(address(bridge)), 0, "full escrow released");
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    // ============= empty deliverBatch no-op =============

    /// @notice `deliverBatch` with an empty nonce array is a no-op: it must not revert and must not
    ///         touch any state.
    function test_deliverBatch_emptyArrayIsNoOp() public {
        uint64[] memory nonces = new uint64[](0);
        // No revert.
        bridge.deliverBatch(SRC_CID, nonces);
        // Nothing parked, nothing consumed — sanity that the call was inert.
        assertEq(bridge.lastParkedNonce(SRC_CID), 0);
    }
}

/// @notice `BridgeERC20.burn` is `onlyRole(MINTER_ROLE)`; symmetric to the existing mint negative
///         test, a non-minter caller must revert. Only the Bridge holds MINTER_ROLE.
contract BridgeERC20BurnAuthTest is BridgeBaseTest {
    function test_burn_revertsForNonMinter() public {
        address t = agency.deployAndAddBridgeToken("BN", "BN", bytes32(uint256(0xB1)));
        BridgeERC20 token = BridgeERC20(t);

        // Give the bridge a balance so the only thing that can fail is the role check.
        vm.prank(address(bridge));
        token.mint(address(bridge), 5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.MINTER_ROLE())
        );
        vm.prank(alice);
        token.burn(1 ether);
    }
}
