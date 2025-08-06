// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {RewarderFactory} from "../../src/RewarderFactory.sol";
import {Rewarder} from "../../src/Rewarder.sol";
import {RestakingStates} from "../../src/RestakingStates.sol";

import {Token} from "../../test/mocks/Token.sol";
import {JsonUtils} from "./Utils.s.sol";

contract RewarderScript is Script, JsonUtils {
    function run() public virtual {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");
        address owner = vm.addr(privKey);

        string memory obj = "rewarder";

        (, string memory path) = loadOrInitJson(obj);

        uint256 faucet = vm.envOr("FAUCET_KEY_0G", uint256(0));
        if (faucet != 0) {
            vm.startBroadcast(faucet);
            payable(owner).transfer(1 ether);
            vm.stopBroadcast();
        }

        vm.startBroadcast(privKey);

        Rewarder rewarderImpl = new Rewarder();
        vm.serializeAddress(obj, "RewarderImpl", address(rewarderImpl));

        UpgradeableBeacon rewarderBeacon = new UpgradeableBeacon(address(rewarderImpl), owner);
        vm.serializeAddress(obj, "RewarderBeacon", address(rewarderBeacon));

        RestakingStates statesImpl = new RestakingStates();
        vm.serializeAddress(obj, "RestakingStatesImpl", address(statesImpl));

        UpgradeableBeacon statesBeacon = new UpgradeableBeacon(address(statesImpl), owner);
        vm.serializeAddress(obj, "RestakingStatesBeacon", address(statesBeacon));

        BeaconProxy statesProxy =
            new BeaconProxy(address(statesBeacon), abi.encodeCall(RestakingStates.initialize, (1)));
        vm.serializeAddress(obj, "RestakingStates", address(statesProxy));

        RewarderFactory factoryImpl = new RewarderFactory();
        vm.serializeAddress(obj, "RewarderFactoryImpl", address(factoryImpl));

        UpgradeableBeacon factoryBeacon = new UpgradeableBeacon(address(factoryImpl), owner);
        vm.serializeAddress(obj, "RewarderFactoryBeacon", address(factoryBeacon));

        BeaconProxy factoryProxy = new BeaconProxy(
            address(factoryBeacon),
            abi.encodeCall(RewarderFactory.initialize, (address(rewarderBeacon), address(statesProxy)))
        );
        RewarderFactory factory = RewarderFactory(address(factoryProxy));
        vm.serializeBytes32(obj, "RewarderInitCodeHash", factory.rewarderInitCodeHash());
        string memory finalJson = vm.serializeAddress(obj, "RewarderFactory", address(factoryProxy));

        vm.stopBroadcast();
        vm.writeJson(finalJson, path);
    }

    function getRewarder(
        bytes memory pubkey
    ) public {
        (string memory json,) = loadOrInitJson("rewarder");

        RewarderFactory rewarderFactory = RewarderFactory(vm.parseJsonAddress(json, ".RewarderFactory"));
        console2.log("rewarder: ", rewarderFactory.getRewarder(pubkey));
    }
}
