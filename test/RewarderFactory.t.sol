// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {RewarderFactory} from "../src/RewarderFactory.sol";
import {Rewarder} from "../src/Rewarder.sol";
import {RestakingStates} from "../src/RestakingStates.sol";

import {IRewarderFactory} from "../src/interfaces/IRewarderFactory.sol";

import {RewarderBaseTest} from "./RewarderBase.t.sol";

contract RewarderFactoryTest is RewarderBaseTest {
    function setUp() public virtual override {
        super.setUp();
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

    function test_createRevertRewarderAlreadyDeployed() public {
        bytes memory pubkey = bytes.concat(abi.encode(1), new bytes(16));
        rewarderFactory.create(pubkey);
        vm.expectRevert(IRewarderFactory.RewarderAlreadyDeployed.selector);
        rewarderFactory.create(pubkey);
    }
}
