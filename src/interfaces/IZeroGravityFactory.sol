// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IZeroGravityFactory {
    error InvalidCollateral(); // Error thrown when get unregistered collateral
    error InsufficientCollateral(uint256, uint256); // Error thrown when given amount is smaller than minimal deposit at validator creation
    error OperatorCreated(); // Error thrown when try to create duplicate operators for the same pubkey

    struct InitParams {
        address middleware;
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
}
