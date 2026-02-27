// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title IWeightedStakePower
 * @notice Interface for converting between stake amounts and voting power using collateral-specific weights.
 * @dev Weights are stored with checkpoint history, allowing lookups at any past timestamp.
 *      Power = stake * weight / 10^decimals, where decimals is the collateral token's decimals.
 */
interface IWeightedStakePower {
    /**
     * @dev Emitted when a collateral's weight is updated.
     * @param collateral Address of the collateral token
     * @param weight The new weight value
     * @param timestamp The timestamp at which the weight takes effect
     */
    event WeightUpdated(address collateral, uint256 weight, uint48 timestamp);

    /**
     * @notice Returns the weight of a collateral token at a given timestamp.
     * @param collateral Address of the collateral token
     * @param timestamp The timestamp to query
     * @param hint Checkpoint lookup hint for gas optimization
     * @return The collateral weight at the given timestamp
     */
    function getCollateralWeight(
        address collateral,
        uint48 timestamp,
        bytes memory hint
    ) external view returns (uint256);

    /**
     * @notice Converts voting power back to a stake amount for a given vault at a specific timestamp.
     * @param vault Address of the Symbiotic vault (used to determine the collateral token)
     * @param timestamp The timestamp for weight lookup
     * @param power The voting power amount to convert
     * @param hint Checkpoint lookup hint for gas optimization
     * @return The equivalent stake amount
     */
    function powerToStake(
        address vault,
        uint48 timestamp,
        uint256 power,
        bytes memory hint
    ) external view returns (uint256);

    /**
     * @notice Converts a stake amount to voting power for a given vault at a specific timestamp.
     * @param vault Address of the Symbiotic vault (used to determine the collateral token)
     * @param timestamp The timestamp for weight lookup
     * @param stake The stake amount to convert
     * @param hint Checkpoint lookup hint for gas optimization
     * @return power The equivalent voting power
     */
    function stakeToPower(
        address vault,
        uint48 timestamp,
        uint256 stake,
        bytes memory hint
    ) external view returns (uint256 power);
}
