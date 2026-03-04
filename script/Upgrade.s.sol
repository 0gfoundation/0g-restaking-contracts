// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {ZeroGravityFactory} from "../src/ZeroGravityFactory.sol";
import {ZeroGravityMiddleware} from "../src/ZeroGravityMiddleware.sol";
import {ZeroGravityOperator} from "../src/ZeroGravityOperator.sol";
import {Rewarder} from "../src/Rewarder.sol";
import {RestakingStates} from "../src/RestakingStates.sol";
import {AscendRouter} from "../src/ascend/AscendRouter.sol";

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

    function upgradeZeroGravityMiddleware() public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");

        (string memory json, string memory path) = loadOrInitJson("zerogravity");

        vm.startBroadcast(privKey);

        UpgradeableBeacon networkBeacon = UpgradeableBeacon(vm.parseJsonAddress(json, ".ZeroGravityMiddlewareBeacon"));
        ZeroGravityMiddleware impl = new ZeroGravityMiddleware();
        networkBeacon.upgradeTo(address(impl));

        vm.writeJson(vm.toString(address(impl)), path, ".ZeroGravityMiddlewareImpl");

        vm.stopBroadcast();
    }

    function upgradeRewarder() public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");

        (string memory json, string memory path) = loadOrInitJson("rewarder");

        vm.startBroadcast(privKey);

        UpgradeableBeacon rewarderBeacon = UpgradeableBeacon(vm.parseJsonAddress(json, ".RewarderBeacon"));
        Rewarder impl = new Rewarder();
        rewarderBeacon.upgradeTo(address(impl));

        vm.writeJson(vm.toString(address(impl)), path, ".RewarderImpl");

        vm.stopBroadcast();
    }

    function upgradeRestakingStates() public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");

        (string memory json, string memory path) = loadOrInitJson("rewarder");

        vm.startBroadcast(privKey);

        UpgradeableBeacon restakingStatesBeacon = UpgradeableBeacon(vm.parseJsonAddress(json, ".RestakingStatesBeacon"));
        RestakingStates impl = new RestakingStates();
        restakingStatesBeacon.upgradeTo(address(impl));

        vm.writeJson(vm.toString(address(impl)), path, ".RestakingStatesImpl");

        vm.stopBroadcast();
    }

    function upgradeAscendRouter() public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");

        (string memory json, string memory path) = loadOrInitJson("ascend");

        vm.startBroadcast(privKey);

        UpgradeableBeacon ascendRouterBeacon = UpgradeableBeacon(vm.parseJsonAddress(json, ".AscendRouterBeacon"));
        AscendRouter impl = new AscendRouter();
        ascendRouterBeacon.upgradeTo(address(impl));

        vm.writeJson(vm.toString(address(impl)), path, ".AscendRouterImpl");

        vm.stopBroadcast();
    }
}
