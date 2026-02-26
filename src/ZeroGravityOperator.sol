// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IOperatorRegistry} from "@symbiotic/interfaces/IOperatorRegistry.sol";
import {IOptInService} from "@symbiotic/interfaces/service/IOptInService.sol";

import {IZeroGravityOperator} from "./interfaces/IZeroGravityOperator.sol";

/**
 * @title ZeroGravityOperator
 * @notice Operator contract deployed as a BeaconProxy for each 0G validator.
 * @dev Registers with Symbiotic's OperatorRegistry on initialization and provides
 *      admin-controlled opt-in to vaults and networks. One operator per validator public key.
 */
contract ZeroGravityOperator is IZeroGravityOperator, AccessControlUpgradeable {
    /// @notice Initializes the operator, sets up access control, and registers in Symbiotic.
    /// @param operatorRegistry Address of the Symbiotic OperatorRegistry contract
    function initialize(
        address operatorRegistry
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        IOperatorRegistry(operatorRegistry).registerOperator();
    }

    /// @notice Opts the operator into a vault and network via Symbiotic opt-in services.
    /// @dev Idempotent — skips opt-in if already opted in to the given vault or network.
    /// @param operatorVaultOptInService Address of the operator-vault opt-in service
    /// @param vault Address of the Symbiotic vault to opt into
    /// @param operatorNetworkOptInService Address of the operator-network opt-in service
    /// @param network Address of the network to opt into
    function optIn(
        address operatorVaultOptInService,
        address vault,
        address operatorNetworkOptInService,
        address network
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!IOptInService(operatorVaultOptInService).isOptedIn(address(this), vault)) {
            IOptInService(operatorVaultOptInService).optIn(vault);
        }
        if (!IOptInService(operatorNetworkOptInService).isOptedIn(address(this), network)) {
            IOptInService(operatorNetworkOptInService).optIn(network);
        }
    }
}
