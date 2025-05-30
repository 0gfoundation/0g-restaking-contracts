// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IZeroGravityMiddleware {
    struct SlashParams {
        address operator;
        uint256 totalPower;
        address[] vaults;
        uint160[] subnetworks;
    }

    struct InitParams {
        address network; // The address of the network, should be 0g factory
        uint48 slashingWindow; // The duration of the slashing window, < epoch duration
        address vaultRegistry; // The address of the vault registry
        address operatorRegistry; // The address of the operator registry
        address operatorNetOptin; // The address of the operator network opt-in service
        address reader; // The address of the reader contract used for delegatecall
        address defaultAdmin; // The address of the default admin
    }

    error InactiveKeySlash(); // Error thrown when trying to slash an inactive key
    error InactiveOperatorSlash(); // Error thrown when trying to slash an inactive operator
    error NotExistKeySlash(); // Error thrown when the key does not exist for slashing
    error InvalidHints(); // Error thrown for invalid hints provided

    function slash(
        uint48 captureTimestamp,
        bytes memory key,
        uint256 amount,
        bytes[][] memory stakeHints,
        bytes[] memory slashHints
    ) external;
}
