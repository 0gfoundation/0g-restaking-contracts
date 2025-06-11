// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IZeroGravityFactory {
    error InvalidCollateral(); // Error thrown when get unregistered collateral
    error InsufficientCollateral(); // Error thrown when given amount is smaller than minimal deposit at validator creation
    error VaultCreated(); // Error thrown when try to create duplicate vault for the same pubkey
    error InvalidOperator(); // Error thrown when try to find invalid operator
    error OperatorVaultNotFound(); // Error thrown when there is no corresponding vault of an operator

    struct InitParams {
        address vaultConfigurator;
        uint64 vaultVersion;
        uint64 delegatorVersion;
        uint64 slasherVersion;
        uint48 epochDuration;
        uint48 vetoDuration;
        uint256 resolverSetEpochsDelay;
        address operatorRegistry;
        address operatorBeacon;
        address resolver;
        address operatorVaultOptInService;
        address operatorNetworkOptInService;
        address defaultStakerRewardsFactory;
    }

    event ValidatorCreated(
        bytes pubkey, bytes signature, address collateral, address vault, address operator, address rewards
    );

    function getRewarder(
        address vault
    ) external view returns (address);

    function createValidator(
        bytes memory pubkey,
        bytes memory signature,
        address onBehalfOf,
        address collateral,
        uint256 amount
    ) external;
}
