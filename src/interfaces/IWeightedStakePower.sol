// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IWeightedStakePower {
    event WeightUpdated(address collateral, uint256 weight, uint48 timestamp);

    function getCollateralWeight(
        address collateral,
        uint48 timestamp,
        bytes memory hint
    ) external view returns (uint256);

    function powerToStake(
        address vault,
        uint48 timestamp,
        uint256 power,
        bytes memory hint
    ) external view returns (uint256);

    function stakeToPower(
        address vault,
        uint48 timestamp,
        uint256 stake,
        bytes memory hint
    ) external view returns (uint256 power);
}
