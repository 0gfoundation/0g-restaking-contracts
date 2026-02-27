// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title IZeroGravityOperator
 * @notice Interface for the 0G operator contract deployed as a BeaconProxy per validator.
 * @dev Each operator registers with Symbiotic's OperatorRegistry and opts into vaults and networks.
 */
interface IZeroGravityOperator {
    /**
     * @notice Initializes the operator and registers it in the Symbiotic OperatorRegistry.
     * @param operatorRegistry Address of the Symbiotic OperatorRegistry contract
     */
    function initialize(
        address operatorRegistry
    ) external;

    /**
     * @notice Opts the operator into a vault and a network via Symbiotic opt-in services.
     * @dev Skips opt-in if the operator is already opted in to the given vault or network.
     * @param operatorVaultOptInService Address of the Symbiotic operator-vault opt-in service
     * @param vault Address of the Symbiotic vault to opt into
     * @param operatorNetworkOptInService Address of the Symbiotic operator-network opt-in service
     * @param network Address of the network to opt into
     */
    function optIn(
        address operatorVaultOptInService,
        address vault,
        address operatorNetworkOptInService,
        address network
    ) external;
}
