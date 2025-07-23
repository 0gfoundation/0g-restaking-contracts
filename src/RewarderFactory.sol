// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {IRewarderFactory} from "./interfaces/IRewarderFactory.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";

import {Create2Helper} from "./libraries/Create2Helper.sol";

contract RewarderFactory is IRewarderFactory, AccessControlUpgradeable {
    /// @custom:storage-location erc7201:0g.restaking.RewarderFactory
    struct RewarderFactoryStorage {
        address rewarderBeacon;
        address restakingStates;
        mapping(bytes32 => address) rewarders;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.restaking.RewarderFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RewarderFactoryStorageLocation =
        0x3fd90de53f217b075ffff7205438b062a9add38fb8aa6d7e731a992a20589b00;

    function _getRewarderFactoryStorage() internal pure returns (RewarderFactoryStorage storage $) {
        assembly {
            $.slot := RewarderFactoryStorageLocation
        }
    }

    /// @dev The length of the public key, PUBLIC_KEY_LENGTH bytes.
    uint8 internal constant PUBLIC_KEY_LENGTH = 48;

    function initialize(address rewarderBeacon, address restakingStates) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        $.rewarderBeacon = rewarderBeacon;
        $.restakingStates = restakingStates;
    }

    function rewarderInitCodeHash() public view returns (bytes32) {
        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        bytes memory initData = abi.encodeCall(IRewarder.initialize, ($.restakingStates));
        bytes memory constructorArgs = abi.encode($.rewarderBeacon, initData);
        bytes memory initCode = abi.encodePacked(type(BeaconProxy).creationCode, constructorArgs);
        return keccak256(initCode);
    }

    function previewRewarder(
        bytes memory pubkey
    ) external view returns (address) {
        if (pubkey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPubKeyLength();
        }
        return Create2Helper.computeCreate2Address(address(this), keccak256(pubkey), rewarderInitCodeHash());
    }

    function getRewarder(
        bytes memory pubkey
    ) external view returns (address) {
        if (pubkey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPubKeyLength();
        }
        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        return $.rewarders[keccak256(pubkey)];
    }

    function create(
        bytes memory pubkey
    ) external {
        if (pubkey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPubKeyLength();
        }

        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        if ($.restakingStates == address(0)) {
            revert EmptyRestakingStates();
        }
        BeaconProxy rewarder = new BeaconProxy{salt: keccak256(pubkey)}(
            address($.rewarderBeacon), abi.encodeCall(IRewarder.initialize, ($.restakingStates))
        );
        $.rewarders[keccak256(pubkey)] = address(rewarder);
        emit RewarderCreated(pubkey, address(rewarder));
    }
}
