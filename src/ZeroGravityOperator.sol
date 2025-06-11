// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IOperatorRegistry} from "@symbiotic/interfaces/IOperatorRegistry.sol";
import {IOptInService} from "@symbiotic/interfaces/service/IOptInService.sol";

import {IZeroGravityOperator} from "./interfaces/IZeroGravityOperator.sol";

contract ZeroGravityOperator is IZeroGravityOperator, AccessControlUpgradeable {
    function initialize(
        address operatorRegistry
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        IOperatorRegistry(operatorRegistry).registerOperator();
    }

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
