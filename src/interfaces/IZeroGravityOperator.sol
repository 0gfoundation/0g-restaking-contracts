// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IZeroGravityOperator {
    function initialize(address operatorRegistry) external;
    function optIn(
        address operatorVaultOptInService,
        address vault,
        address operatorNetworkOptInService,
        address network
    ) external;
}
