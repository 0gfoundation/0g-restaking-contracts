// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {RewarderFactory} from "../src/RewarderFactory.sol";
import {Rewarder} from "../src/Rewarder.sol";
import {RestakingStates} from "../src/RestakingStates.sol";

contract RewarderFactoryTest is Test {
    address private owner;
    RestakingStates restakingStates;
    RewarderFactory rewarderFactory;

    function setUp() public virtual {
        owner = address(this);

        Rewarder rewarderImpl = new Rewarder();
        UpgradeableBeacon rewarderBeacon = new UpgradeableBeacon(address(rewarderImpl), owner);

        RestakingStates statesImpl = new RestakingStates();
        UpgradeableBeacon statesBeacon = new UpgradeableBeacon(address(statesImpl), owner);
        BeaconProxy statesProxy =
            new BeaconProxy(address(statesBeacon), abi.encodeCall(RestakingStates.initialize, (1)));
        restakingStates = RestakingStates(address(statesProxy));

        RewarderFactory factoryImpl = new RewarderFactory();
        UpgradeableBeacon factoryBeacon = new UpgradeableBeacon(address(factoryImpl), owner);
        BeaconProxy factoryProxy = new BeaconProxy(
            address(factoryBeacon),
            abi.encodeCall(RewarderFactory.initialize, (address(rewarderBeacon), address(restakingStates)))
        );
        rewarderFactory = RewarderFactory(address(factoryProxy));
    }

    function test_create() public {
        console2.log("initCodeHash: ");
        console2.logBytes32(rewarderFactory.rewarderInitCodeHash());
        console2.log("factory: ", address(rewarderFactory));
        for (uint256 i = 0; i < 10; ++i) {
            bytes memory pubkey = bytes.concat(abi.encode(i), new bytes(16));
            rewarderFactory.create(pubkey);
            // console2.log("preview: ", factory.previewRewarder(pubkey));
            // console2.log("real: ", factory.getRewarder(pubkey));
            assertEq(rewarderFactory.previewRewarder(pubkey), rewarderFactory.getRewarder(pubkey));
            address rewarder = rewarderFactory.previewRewarder(pubkey);
            assertEq(rewarderFactory.getPubkey(rewarder), pubkey);
        }
    }
}
