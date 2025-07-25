// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {RewarderFactory} from "../src/RewarderFactory.sol";
import {Rewarder} from "../src/Rewarder.sol";
import {RestakingStates} from "../src/RestakingStates.sol";

import {IRewarderFactory} from "../src/interfaces/IRewarderFactory.sol";

contract RewarderBaseTest is Test {
    using Strings for uint256;

    address private owner;
    RestakingStates restakingStates;
    RewarderFactory rewarderFactory;

    uint256 internal constant DOMAIN_CNT = 3;
    uint256 internal constant COLLATERAL_CNT = 10;
    uint256 internal constant REWARDER_CNT = 5;
    uint256 internal constant ACCOUNTS_CNT = 10;

    address[] collaterals;
    address[] rewarders;
    address[] accounts;
    mapping(address => uint256) decimals;
    mapping(uint256 => mapping(address => uint256)) weights;
    mapping(uint256 => mapping(address => mapping(address => mapping(address => uint256)))) balances;
    mapping(uint256 => mapping(address => mapping(address => uint256))) supply;
    uint256 rng;

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

    function _initialRewarderStates() internal {
        // set domains
        restakingStates.setDomains(DOMAIN_CNT);
        // rewarders
        for (uint256 i = 0; i < REWARDER_CNT; ++i) {
            bytes memory pubkey = bytes.concat(abi.encode(i), new bytes(16));
            rewarderFactory.create(pubkey);
            vm.label(rewarderFactory.getRewarder(pubkey), string.concat("rewarder#", i.toString()));
            rewarders.push(rewarderFactory.getRewarder(pubkey));
        }
        // accounts
        for (uint256 i = 0; i < ACCOUNTS_CNT; ++i) {
            accounts.push(makeAddr(string.concat("account#", i.toString())));
            vm.deal(accounts[i], 1 ether);
        }
        // set collateral weights
        for (uint256 i = 0; i < COLLATERAL_CNT; ++i) {
            collaterals.push(makeAddr(string.concat("collateral#", i.toString())));
            decimals[collaterals[i]] = i % 13 + 6;
        }

        for (uint256 domain = 0; domain < DOMAIN_CNT; ++domain) {
            for (uint256 i = 0; i < COLLATERAL_CNT; ++i) {
                weights[domain][collaterals[i]] = _alignedWeight(decimals[collaterals[i]], (i + 1) * 1e9);
                restakingStates.updateWeight(domain, collaterals[i], weights[domain][collaterals[i]]);
            }
        }
    }

    function _nextRng() internal returns (uint256) {
        rng = uint256(keccak256(abi.encodePacked(rng)));
        return rng;
    }

    function _alignedWeight(uint256 decimal, uint256 unitPower) internal pure returns (uint256) {
        // assume amount * aligned_weight / 1e18 = power (in Gwei)
        return unitPower * 1e18 / (10 ** decimal);
    }
}
