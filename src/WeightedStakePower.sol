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
 * @title WeightedStakePower
 * @notice Converts between stake amounts and voting power using per-collateral weights.
 * @dev Each collateral token has a configurable weight with checkpoint history, allowing
 *      historical lookups. Conversion formula:
 *      power = stake * weight / 10^(collateral decimals)
 *      stake = power * 10^(collateral decimals) / weight
 */
abstract contract WeightedStakePower is StakePowerManager, AccessManager, IWeightedStakePower {
    using Checkpoints for Checkpoints.Trace256;

    /// @custom:storage-location erc7201:0g.storage.WeightedStakePower
    struct WeightedStakePowerStorage {
        /// @dev Per-collateral weight history using Symbiotic's Checkpoints library (18 decimals)
        mapping(address => Checkpoints.Trace256) weights;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.storage.WeightedStakePower")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WeightedStakePowerStorageLocation =
        0x1828e6c0e287b872f5ab0634f9c4726e4c517357cf718de3faa72fe752d29100;

    function _getWeightedStakePowerStorage() internal pure returns (WeightedStakePowerStorage storage $) {
        assembly {
            $.slot := WeightedStakePowerStorageLocation
        }
    }

    /// @notice Sets the weight for a collateral token, effective from the current timestamp.
    /// @param collateral Address of the collateral token
    /// @param weight The new weight value
    function setCollateralWeight(address collateral, uint256 weight) external checkAccess {
        WeightedStakePowerStorage storage $ = _getWeightedStakePowerStorage();
        $.weights[collateral].push(Time.timestamp(), weight);
        emit WeightUpdated(collateral, weight, Time.timestamp());
    }

    /// @dev Returns the weight for a collateral at a given timestamp using checkpoint lookup.
    /// @param collateral Address of the collateral token
    /// @param timestamp The timestamp to query
    /// @param hint Checkpoint lookup hint for gas optimization
    /// @return The collateral weight at the given timestamp
    function _getCollateralWeight(
        address collateral,
        uint48 timestamp,
        bytes memory hint
    ) internal view returns (uint256) {
        WeightedStakePowerStorage storage $ = _getWeightedStakePowerStorage();
        return $.weights[collateral].upperLookupRecent(timestamp, hint);
    }

    /// @notice Returns the weight of a collateral token at a given timestamp.
    /// @param collateral Address of the collateral token
    /// @param timestamp The timestamp to query
    /// @param hint Checkpoint lookup hint for gas optimization
    /// @return The collateral weight at the given timestamp
    function getCollateralWeight(
        address collateral,
        uint48 timestamp,
        bytes memory hint
    ) external view returns (uint256) {
        return _getCollateralWeight(collateral, timestamp, hint);
    }

    /// @dev Converts a stake amount to voting power: stake * weight / 10^decimals.
    function _stakeToPower(uint256 stake, uint256 weight, address collateral) internal view returns (uint256) {
        return stake * weight / (10 ** IERC20Metadata(collateral).decimals());
    }

    /// @dev Converts voting power back to a stake amount: power * 10^decimals / weight.
    function _powerToStake(uint256 power, uint256 weight, address collateral) internal view returns (uint256) {
        return power * (10 ** IERC20Metadata(collateral).decimals()) / weight;
    }

    /// @notice Converts stake to power for a vault using the current timestamp.
    /// @param vault Address of the Symbiotic vault
    /// @param stake The stake amount to convert
    /// @return power The equivalent voting power
    function stakeToPower(address vault, uint256 stake) public view override returns (uint256 power) {
        return stakeToPower(vault, Time.timestamp(), stake, "");
    }

    /// @notice Converts stake to power for a vault at a specific timestamp.
    /// @param vault Address of the Symbiotic vault (used to determine collateral)
    /// @param timestamp The timestamp for weight lookup
    /// @param stake The stake amount to convert
    /// @param hint Checkpoint lookup hint for gas optimization
    /// @return power The equivalent voting power
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

    /// @notice Converts voting power back to a stake amount for a vault at a specific timestamp.
    /// @param vault Address of the Symbiotic vault (used to determine collateral)
    /// @param timestamp The timestamp for weight lookup
    /// @param power The voting power to convert
    /// @param hint Checkpoint lookup hint for gas optimization
    /// @return The equivalent stake amount
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
