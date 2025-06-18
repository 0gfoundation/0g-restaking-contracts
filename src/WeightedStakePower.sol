// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";
import {Checkpoints} from "@symbiotic/contracts/libraries/Checkpoints.sol";

import {StakePowerManager} from "middleware-sdk/managers/extendable/StakePowerManager.sol";
import {AccessManager} from "middleware-sdk/managers/extendable/AccessManager.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

import {IWeightedStakePower} from "./interfaces/IWeightedStakePower.sol";

/**
 * @title EqualStakePower
 * @notice Implementation of a 1:1 stake to power conversion
 * @dev Simply returns the stake amount as the power amount without any modifications
 */
abstract contract WeightedStakePower is StakePowerManager, AccessManager, IWeightedStakePower {
    using Checkpoints for Checkpoints.Trace256;

    /// @custom:storage-location erc7201:0g.storage.WeightedStakePower
    struct WeightedStakePowerStorage {
        mapping(address => Checkpoints.Trace256) weights; // 18 decimals
    }

    // keccak256(abi.encode(uint256(keccak256("0g.storage.WeightedStakePower")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WeightedStakePowerStorageLocation =
        0x1828e6c0e287b872f5ab0634f9c4726e4c517357cf718de3faa72fe752d29100;

    function _getWeightedStakePowerStorage() internal pure returns (WeightedStakePowerStorage storage $) {
        assembly {
            $.slot := WeightedStakePowerStorageLocation
        }
    }

    function setCollateralWeight(address collateral, uint256 weight) external checkAccess {
        WeightedStakePowerStorage storage $ = _getWeightedStakePowerStorage();
        $.weights[collateral].push(Time.timestamp(), weight);
        emit WeightUpdated(collateral, weight, Time.timestamp());
    }

    function _getCollateralWeight(
        address collateral,
        uint48 timestamp,
        bytes memory hint
    ) internal view returns (uint256) {
        WeightedStakePowerStorage storage $ = _getWeightedStakePowerStorage();
        return $.weights[collateral].upperLookupRecent(timestamp, hint);
    }

    function getCollateralWeight(
        address collateral,
        uint48 timestamp,
        bytes memory hint
    ) external view returns (uint256) {
        return _getCollateralWeight(collateral, timestamp, hint);
    }

    function _stakeToPower(uint256 stake, uint256 weight, address collateral) internal view returns (uint256) {
        return stake * weight / (10 ** IERC20Metadata(collateral).decimals());
    }

    function _powerToStake(uint256 power, uint256 weight, address collateral) internal view returns (uint256) {
        return power * (10 ** IERC20Metadata(collateral).decimals()) / weight;
    }

    function stakeToPower(address vault, uint256 stake) public view override returns (uint256 power) {
        return stakeToPower(vault, Time.timestamp(), stake, "");
    }

    function stakeToPower(
        address vault,
        uint48 timestamp,
        uint256 stake,
        bytes memory hint
    ) public view override returns (uint256 power) {
        address collateral = IVault(vault).collateral();
        uint256 weight = _getCollateralWeight(collateral, timestamp, hint);
        return _stakeToPower(stake, weight, collateral);
    }

    function powerToStake(
        address vault,
        uint48 timestamp,
        uint256 power,
        bytes memory hint
    ) public view override returns (uint256) {
        address collateral = IVault(vault).collateral();
        uint256 weight = _getCollateralWeight(collateral, timestamp, hint);
        return _powerToStake(power, weight, collateral);
    }
}
