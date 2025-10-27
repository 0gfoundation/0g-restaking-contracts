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

    function grantUpdateRole(
        address account
    ) public {
        (string memory json,) = loadOrInitJson("rewarder");
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");

        vm.startBroadcast(privKey);
        RestakingStates states = RestakingStates(vm.parseJsonAddress(json, ".RestakingStates"));
        states.grantRole(states.UPDATE_ROLE(), account);
        vm.stopBroadcast();
    }

    function hash() public {
        (string memory json,) = loadOrInitJson("rewarder");

        RewarderFactory rewarderFactory = RewarderFactory(vm.parseJsonAddress(json, ".RewarderFactory"));
        console2.logBytes32(rewarderFactory.rewarderInitCodeHash());
    }

    function getRewarder(
        bytes memory pubkey
    ) public returns (address) {
        (string memory json,) = loadOrInitJson("rewarder");

        RewarderFactory rewarderFactory = RewarderFactory(vm.parseJsonAddress(json, ".RewarderFactory"));
        address rewarder = rewarderFactory.getRewarder(pubkey);
        console2.log("rewarder: ", rewarder);
        return rewarder;
    }

    function show() public {
        bytes[] memory pubkeys = new bytes[](4);
        pubkeys[0] =
            hex"872e648c3b12a24a2a85b539dc669e722f2463ef8ed67304551db381e313f78ebf879d9835d57617f64e8d50658fdf1e";
        pubkeys[1] =
            hex"b0d6091bc5d40ed082900c87a93ff45bda1d5494c028bc1632365b22a373dcf691b7f75642c0dbfeafcda052f259d768";
        pubkeys[2] =
            hex"a8a9672bc571aae5f454bcc8d59a45a844194811b3e44d8cef94ea967653ce7d0b93914a8c2dfef5f15f146ea8923c1e";
        pubkeys[3] =
            hex"973191a914e10526cf374397edb4a0f8b5749ae13759fae02c3fde989c09ac7b8d7ac453590935abb09da12e19596598";

        (string memory json,) = loadOrInitJson("rewarder");
        for (uint256 j = 0; j < pubkeys.length; ++j) {
            address rewarder = getRewarder(pubkeys[j]);
            RestakingStates states = RestakingStates(vm.parseJsonAddress(json, ".RestakingStates"));
            (uint256 power, RestakingStates.Power[] memory powers) = states.getPowers(rewarder);
            console2.log("total power of ", rewarder, " is ", power);
            for (uint256 i = 0; i < powers.length; ++i) {
                if (powers[i].power == 0) {
                    continue;
                }
                console2.log("power of ", powers[i].supply.collateral, " is ", powers[i].power);
            }
        }
    }

    function claim(address rewarder, address account) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");

        vm.startBroadcast(privKey);
        uint256 reward = Rewarder(payable(rewarder)).claim(account);
        console2.log("reward: ", reward);
        vm.stopBroadcast();
    }
}
