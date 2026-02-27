// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {IRewarderFactory} from "./interfaces/IRewarderFactory.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";

import {Create2Helper} from "./libraries/Create2Helper.sol";

/**
 * @title RewarderFactory
 * @notice Factory for deploying per-validator Rewarder contracts on the 0G Chain via Create2.
 * @dev Each Rewarder is a BeaconProxy deployed with Create2 using keccak256(pubkey) as the salt,
 *      making rewarder addresses deterministic and predictable from the validator's public key.
 *      This allows the Ethereum-side contracts to compute rewarder addresses without cross-chain calls.
 */
contract RewarderFactory is IRewarderFactory, AccessControlUpgradeable {
    /// @custom:storage-location erc7201:0g.restaking.RewarderFactory
    struct RewarderFactoryStorage {
        /// @dev Address of the UpgradeableBeacon contract for rewarder proxies
        address rewarderBeacon;
        /// @dev Address of the RestakingStates contract passed to each rewarder on initialization
        address restakingStates;
        /// @dev Mapping from keccak256(pubkey) to deployed rewarder address
        mapping(bytes32 => address) rewarders;
        /// @dev Reverse mapping from rewarder address to public key
        mapping(address => bytes) pubkeys;
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

    /// @notice Initializes the factory with the beacon and RestakingStates addresses.
    /// @param rewarderBeacon Address of the UpgradeableBeacon for rewarder proxies
    /// @param restakingStates Address of the RestakingStates contract
    function initialize(address rewarderBeacon, address restakingStates) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        $.rewarderBeacon = rewarderBeacon;
        $.restakingStates = restakingStates;
    }

    /// @notice Returns the init code hash used for Create2 address computation.
    /// @return The keccak256 hash of the BeaconProxy creation code with constructor arguments
    function rewarderInitCodeHash() public view override returns (bytes32) {
        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        bytes memory initData = abi.encodeCall(IRewarder.initialize, ($.restakingStates));
        bytes memory constructorArgs = abi.encode($.rewarderBeacon, initData);
        bytes memory initCode = abi.encodePacked(type(BeaconProxy).creationCode, constructorArgs);
        return keccak256(initCode);
    }

    /// @notice Computes the deterministic address where a rewarder would be deployed for the given key.
    /// @dev The rewarder may or may not have been deployed yet.
    /// @param pubkey The validator's BLS public key (48 bytes)
    /// @return The computed Create2 address
    function previewRewarder(
        bytes memory pubkey
    ) external view override returns (address) {
        if (pubkey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPubKeyLength();
        }
        return Create2Helper.computeCreate2Address(address(this), keccak256(pubkey), rewarderInitCodeHash());
    }

    /// @notice Returns the deployed rewarder address for a validator, or zero if not yet deployed.
    /// @param pubkey The validator's BLS public key (48 bytes)
    /// @return The rewarder address, or address(0) if not deployed
    function getRewarder(
        bytes memory pubkey
    ) external view override returns (address) {
        if (pubkey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPubKeyLength();
        }
        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        return $.rewarders[keccak256(pubkey)];
    }

    /// @notice Returns the public key associated with a deployed rewarder address.
    /// @param rewarder Address of the rewarder contract
    /// @return The validator's BLS public key (48 bytes)
    function getPubkey(
        address rewarder
    ) external view override returns (bytes memory) {
        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        return $.pubkeys[rewarder];
    }

    /// @notice Deploys a new rewarder contract for a validator using Create2.
    /// @dev Reverts if a rewarder already exists for this public key or if RestakingStates is not set.
    /// @param pubkey The validator's BLS public key (48 bytes)
    function create(
        bytes memory pubkey
    ) external override {
        if (pubkey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPubKeyLength();
        }

        RewarderFactoryStorage storage $ = _getRewarderFactoryStorage();
        if ($.restakingStates == address(0)) {
            revert EmptyRestakingStates();
        }
        if ($.rewarders[keccak256(pubkey)] != address(0)) {
            revert RewarderAlreadyDeployed();
        }
        BeaconProxy rewarder = new BeaconProxy{salt: keccak256(pubkey)}(
            address($.rewarderBeacon), abi.encodeCall(IRewarder.initialize, ($.restakingStates))
        );
        $.rewarders[keccak256(pubkey)] = address(rewarder);
        $.pubkeys[address(rewarder)] = pubkey;
        emit RewarderCreated(pubkey, address(rewarder));
    }
}
