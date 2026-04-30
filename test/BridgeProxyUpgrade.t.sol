// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeAgency} from "../src/bridge/BridgeAgency.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";

/// @dev V2 of BridgeERC20 used to verify beacon upgrades propagate to all proxies.
contract BridgeERC20V2 is BridgeERC20 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 of Bridge that exposes a marker.
contract BridgeV2 is Bridge {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev V2 of BridgeAgency that exposes a marker.
contract BridgeAgencyV2 is BridgeAgency {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Verifies that beacon-upgradeable contracts pick up new logic via beacon.upgradeTo,
///         and that a single upgrade of the BridgeERC20 beacon affects every deployed instance.
contract BridgeProxyUpgradeTest is BridgeBaseTest {
    function test_bridgeBeacon_upgradeTo() public {
        BridgeV2 v2 = new BridgeV2();
        bridgeBeacon.upgradeTo(address(v2));
        // Re-cast and call the new selector via low-level staticcall (interface unchanged).
        (bool ok, bytes memory ret) = address(bridge).staticcall(abi.encodeWithSignature("version()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 2);
        // existing storage preserved
        assertEq(bridge.localChainID(), LOCAL_CID);
    }

    function test_agencyBeacon_upgradeTo() public {
        BridgeAgencyV2 v2 = new BridgeAgencyV2();
        agencyBeacon.upgradeTo(address(v2));
        (bool ok, bytes memory ret) = address(agency).staticcall(abi.encodeWithSignature("version()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 2);
        // existing storage preserved
        assertEq(agency.bridge(), address(bridge));
    }

    function test_bridgeERC20Beacon_upgradeAffectsAllInstances() public {
        // Deploy 3 BridgeERC20 instances via the agency.
        address t1 = agency.deployAndAddBridgeToken("A", "A");
        address t2 = agency.deployAndAddBridgeToken("B", "B");
        address t3 = agency.deployAndAddBridgeToken("C", "C");

        // Pre-upgrade: version() doesn't exist on the V1 impl — calling fails.
        (bool ok,) = t1.staticcall(abi.encodeWithSignature("version()"));
        assertFalse(ok);

        // Upgrade the shared beacon.
        BridgeERC20V2 v2 = new BridgeERC20V2();
        bridgeERC20Beacon.upgradeTo(address(v2));

        // All three proxies pick up the new logic.
        for (uint256 i = 0; i < 3; ++i) {
            address t = i == 0 ? t1 : (i == 1 ? t2 : t3);
            (bool ok2, bytes memory ret) = t.staticcall(abi.encodeWithSignature("version()"));
            assertTrue(ok2);
            assertEq(abi.decode(ret, (uint256)), 2);
        }

        // Storage preserved — Bridge still has MINTER_ROLE on each.
        for (uint256 i = 0; i < 3; ++i) {
            address t = i == 0 ? t1 : (i == 1 ? t2 : t3);
            BridgeERC20 token = BridgeERC20(t);
            assertTrue(token.hasRole(token.MINTER_ROLE(), address(bridge)));
        }
    }

    function test_nonOwner_upgradeReverts() public {
        BridgeV2 v2 = new BridgeV2();
        vm.expectRevert();
        vm.prank(alice);
        bridgeBeacon.upgradeTo(address(v2));
    }

    function test_nonOwner_upgradeERC20BeaconReverts() public {
        BridgeERC20V2 v2 = new BridgeERC20V2();
        vm.expectRevert();
        vm.prank(alice);
        bridgeERC20Beacon.upgradeTo(address(v2));
    }
}
