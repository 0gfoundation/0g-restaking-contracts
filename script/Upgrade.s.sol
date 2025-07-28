// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {ZeroGravityFactory} from "../src/ZeroGravityFactory.sol";
import {ZeroGravityMiddleware} from "../src/ZeroGravityMiddleware.sol";
import {ZeroGravityOperator} from "../src/ZeroGravityOperator.sol";

import {JsonUtils} from "./deploy/Utils.s.sol";

contract UpgradeScript is Script, JsonUtils {
    function upgradeZeroGravityFactory() public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");

        (string memory json, string memory path) = loadOrInitJson("zerogravity");

        vm.startBroadcast(privKey);

        UpgradeableBeacon networkBeacon = UpgradeableBeacon(vm.parseJsonAddress(json, ".ZeroGravityFactoryBeacon"));
        ZeroGravityFactory factoryImpl = new ZeroGravityFactory();
        networkBeacon.upgradeTo(address(factoryImpl));

        vm.writeJson(vm.toString(address(factoryImpl)), path, ".ZeroGravityFactoryImpl");

        vm.stopBroadcast();
    }
}
