// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

/// @dev Mock ERC-20 with a configurable `decimals()` — the stock `Token` mock is fixed at 18.
contract DToken is ERC20 {
    uint8 private immutable _d;

    constructor(string memory name_, uint8 d_, address holder, uint256 supply) ERC20(name_, "") {
        _d = d_;
        _mint(holder, supply);
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }
}

/// @notice Exercises the wire-decimals normalization: the bridge carries every cross-chain amount
///         normalized to `WIRE_DECIMALS` (18) and converts back to each token's native decimals,
///         so the source and destination tokens need NOT share decimals.
contract BridgeDecimalsTest is BridgeBaseTest {
    uint64 internal constant SRC = 7;

    /// Register `token` as LockRelease and map a remote at DST_CID (owner == address(this)).
    function _registerLR(
        address token
    ) internal {
        agency.addToken(token, IBridge.BridgeMode.LockRelease);
        agency.mapRemote(token, DST_CID, makeAddr("remote"));
    }

    /// Source side: a 6-decimals token's `lockAndSend(100e6)` escrows the full 100e6 and emits a
    /// BridgeOut carrying the 18-decimals wire value 100e18.
    function test_source_normalizesSixDecimalsToWire() public {
        DToken t = new DToken("USDT", 6, alice, 1000e6);
        _registerLR(address(t));

        uint256 amount = 100e6;
        vm.prank(alice);
        t.approve(address(bridge), amount);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(
            uint64(block.chainid),
            DST_CID,
            1,
            address(t),
            makeAddr("remote"),
            bob,
            100e18,
            uint8(IBridge.BridgeMode.LockRelease)
        );
        vm.prank(alice);
        bridge.lockAndSend(address(t), DST_CID, bob, amount);

        assertEq(t.balanceOf(address(bridge)), 100e6, "escrow holds full native amount");
        assertEq(t.balanceOf(alice), 900e6, "sender debited exactly the native amount");
    }

    /// Destination side: a parked wire amount of 100e18 delivered to a 6-decimals LockRelease token
    /// releases 100e6 native to the recipient.
    function test_dest_denormalizesWireToSixDecimals() public {
        DToken t = new DToken("USDT", 6, address(bridge), 1000e6); // pre-fund escrow
        _registerLR(address(t));

        IBridge.InboundMessage memory m = _msg(SRC, 1, address(t), bob, 100e18); // wire = 18 decimals
        _parkOne(m);
        bridge.deliver(SRC, 1);

        assertEq(t.balanceOf(bob), 100e6, "recipient gets wire amount converted to 6 decimals");
    }

    /// Source side, > 18 decimals: `lockAndSend` truncates the sub-wire dust — it escrows only the
    /// portion that survives the 18-decimals wire and leaves the remainder with the sender.
    function test_source_truncatesAboveEighteenDecimals() public {
        DToken t = new DToken("BIG", 24, alice, 1000e24);
        _registerLR(address(t));

        uint256 amount = 100e24 + 5; // 5 is below the 10**(24-18) = 1e6 wire resolution
        vm.prank(alice);
        t.approve(address(bridge), amount);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeOut(
            uint64(block.chainid),
            DST_CID,
            1,
            address(t),
            makeAddr("remote"),
            bob,
            100e18,
            uint8(IBridge.BridgeMode.LockRelease)
        );
        vm.prank(alice);
        bridge.lockAndSend(address(t), DST_CID, bob, amount);

        assertEq(t.balanceOf(address(bridge)), 100e24, "escrow holds only the wire-representable amount");
        assertEq(t.balanceOf(alice), 1000e24 - 100e24, "the 5-wei sub-wire dust stays with the sender");
    }

    /// A user amount smaller than the wire resolution (nothing crosses) reverts rather than
    /// escrowing dust that could never be delivered.
    function test_source_belowWireResolutionReverts() public {
        DToken t = new DToken("BIG", 24, alice, 1000e24);
        _registerLR(address(t));

        vm.prank(alice);
        t.approve(address(bridge), 5);
        vm.prank(alice);
        vm.expectRevert(IBridge.AmountTooSmall.selector);
        bridge.lockAndSend(address(t), DST_CID, bob, 5); // 5 / 1e6 == 0 wire
    }

    /// End-to-end through the real deploy path: a BridgeERC20 twin deployed with `decimals_ = 6`
    /// reports 6 decimals and receives a parked wire amount of 100e18 as 100e6 minted native.
    function test_mintBurnTwinWithSixDecimals() public {
        address t = agency.deployAndAddBridgeToken("Bridged USDT", "bUSDT", 6, bytes32(uint256(0xDEC)));
        agency.mapRemote(t, DST_CID, makeAddr("remote6"));
        assertEq(BridgeERC20(t).decimals(), 6, "twin reports the configured decimals");

        IBridge.InboundMessage memory m = _msg(SRC, 1, t, bob, 100e18); // wire = 18 decimals
        _parkOne(m);
        bridge.deliver(SRC, 1);

        assertEq(BridgeERC20(t).balanceOf(bob), 100e6, "twin minted wire amount converted to 6 decimals");
    }
}
