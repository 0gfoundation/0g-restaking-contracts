// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";

import {StakePowerManager} from "middleware-sdk/managers/extendable/StakePowerManager.sol";
import {AccessManager} from "middleware-sdk/managers/extendable/AccessManager.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

/**
 * @title EqualStakePower
 * @notice Implementation of a 1:1 stake to power conversion
 * @dev Simply returns the stake amount as the power amount without any modifications
 */
abstract contract WeightedStakePower is StakePowerManager, AccessManager {
    /// @custom:storage-location erc7201:0g.storage.WeightedStakePower
    struct WeightedStakePowerStorage {
        mapping(address => uint256) weights; // 18 decimals
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
        $.weights[collateral] = weight;
    }

    /**
     * @notice Converts stake amount to voting power using a weighted ratio
     * @param vault The vault address (unused in this implementation)
     * @param stake The stake amount
     * @return power The calculated voting power (equal to stake)
     */
    function stakeToPower(address vault, uint256 stake) public view override returns (uint256 power) {
        WeightedStakePowerStorage storage $ = _getWeightedStakePowerStorage();
        address collateral = IVault(vault).collateral();
        return stake * $.weights[collateral] / (10 ** IERC20Metadata(collateral).decimals());
    }
}
