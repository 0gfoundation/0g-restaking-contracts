// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IZeroGravityMiddleware {
    struct SlashParams {
        uint48 epochStart;
        address operator;
        uint256 totalPower;
        address[] vaults;
        uint160[] subnetworks;
    }

    error InactiveKeySlash(); // Error thrown when trying to slash an inactive key
    error InactiveOperatorSlash(); // Error thrown when trying to slash an inactive operator
    error NotExistKeySlash(); // Error thrown when the key does not exist for slashing
    error InvalidHints(); // Error thrown for invalid hints provided
}
