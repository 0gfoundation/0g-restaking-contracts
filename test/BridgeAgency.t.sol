// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeAgency} from "../src/bridge/BridgeAgency.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @notice Covers `BridgeAgency`: onlyOwner enforcement, deployAndAddBridgeToken returns a working
///         BridgeERC20 BeaconProxy where Bridge is MINTER_ROLE-holder, and the various pass-through
///         setters.
contract BridgeAgencyTest is BridgeBaseTest {
    function test_addToken_onlyOwner() public {
        Token token = new Token("X");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);
    }

    function test_deployAndAddBridgeToken_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.deployAndAddBridgeToken("X", "X", bytes32(0));
    }

    function test_mapRemote_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.mapRemote(address(0xdead), 7, address(0xbeef));
    }

    function test_disableToken_onlyOwner() public {
        Token t = new Token("X");
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        agency.disableToken(address(t));
    }

    function test_deployAndAddBridgeToken_grantsMinterRole() public {
        address t = agency.deployAndAddBridgeToken("Sat USDT", "satUSDT", bytes32(0));
        BridgeERC20 token = BridgeERC20(t);

        assertTrue(token.hasRole(token.MINTER_ROLE(), address(bridge)));
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(bridge)));
        assertEq(token.name(), "Sat USDT");
        assertEq(token.symbol(), "satUSDT");

        // Bridge can mint via prank.
        vm.prank(address(bridge));
        token.mint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);

        // Random caller cannot mint.
        vm.expectRevert();
        vm.prank(alice);
        token.mint(alice, 1);
    }

    function test_deployAndAddBridgeToken_registersAsMintBurn() public {
        address t = agency.deployAndAddBridgeToken("Sat", "S", bytes32(0));
        (bool enabled, IBridge.BridgeMode mode) = bridge.tokenConfig(t);
        assertTrue(enabled);
        assertEq(uint8(mode), uint8(IBridge.BridgeMode.MintBurn));
    }

    function test_addToken_thenMapRemote_thenDisable() public {
        Token t = new Token("LR");
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);
        agency.mapRemote(address(t), 5, makeAddr("dst5"));

        // Verify Bridge state reflects the agency's calls.
        (bool enabled, IBridge.BridgeMode mode) = bridge.tokenConfig(address(t));
        assertTrue(enabled);
        assertEq(uint8(mode), uint8(IBridge.BridgeMode.LockRelease));
        assertEq(bridge.remoteToken(address(t), 5), makeAddr("dst5"));

        agency.disableToken(address(t));
        (enabled, mode) = bridge.tokenConfig(address(t));
        assertFalse(enabled);
        // mode preserved
        assertEq(uint8(mode), uint8(IBridge.BridgeMode.LockRelease));

        // Re-enable via addToken — caller must specify mode explicitly (no implicit toggle).
        agency.addToken(address(t), IBridge.BridgeMode.LockRelease);
        (enabled,) = bridge.tokenConfig(address(t));
        assertTrue(enabled);
    }

    function test_views() public view {
        assertEq(agency.bridge(), address(bridge));
        assertEq(agency.bridgeERC20Beacon(), address(bridgeERC20Beacon));
    }

    // ============= initialize zero-address checks =============

    function test_initialize_revertsZeroBridge() public {
        BridgeAgency impl = new BridgeAgency();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), owner);
        bytes memory init = abi.encodeCall(BridgeAgency.initialize, (address(0), address(bridgeERC20Beacon), owner));
        vm.expectRevert(IBridge.ZeroAddress.selector);
        new BeaconProxy(address(beacon), init);
    }

    function test_initialize_revertsZeroBeacon() public {
        BridgeAgency impl = new BridgeAgency();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), owner);
        bytes memory init = abi.encodeCall(BridgeAgency.initialize, (address(bridge), address(0), owner));
        vm.expectRevert(IBridge.ZeroAddress.selector);
        new BeaconProxy(address(beacon), init);
    }

    // ============= CREATE2 determinism =============

    /// Same `(name, symbol, salt)` on a Bridge deployed at a known address always lands the
    /// resulting BridgeERC20 at the CREATE2-predicted address. Two chains that share the same
    /// Bridge + BridgeERC20Beacon addresses (via Nick-method genesis deployment) will therefore
    /// produce the same token address — the cross-chain consistency property we want.
    function test_deployAndAddBridgeToken_addressIsDeterministic() public {
        bytes32 salt = bytes32(uint256(0x42));
        bytes memory init = abi.encodeCall(BridgeERC20.initialize, ("Det", "DET", address(bridge)));
        bytes memory initCode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bridgeERC20Beacon, init));
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), address(bridge));

        address actual = agency.deployAndAddBridgeToken("Det", "DET", salt);
        assertEq(actual, predicted, "deployed address must equal CREATE2 prediction");
    }

    /// Different salts with otherwise identical parameters land at different addresses.
    function test_deployAndAddBridgeToken_differentSaltsGiveDifferentAddresses() public {
        address a = agency.deployAndAddBridgeToken("Same", "SAME", bytes32(uint256(1)));
        address b = agency.deployAndAddBridgeToken("Same", "SAME", bytes32(uint256(2)));
        assertTrue(a != b, "different salts must produce different addresses");
    }

    /// Re-deploying with the same `(name, symbol, salt)` on the same chain hits the CREATE2
    /// "address already taken" rule and reverts.
    function test_deployAndAddBridgeToken_collisionReverts() public {
        bytes32 salt = bytes32(uint256(0xCAFE));
        agency.deployAndAddBridgeToken("Col", "COL", salt);
        vm.expectRevert();
        agency.deployAndAddBridgeToken("Col", "COL", salt);
    }
}
