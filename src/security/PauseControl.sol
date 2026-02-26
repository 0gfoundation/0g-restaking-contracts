// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

/**
 * @title PauseControl
 * @notice Emergency pause functionality using OpenZeppelin's Pausable with role-based access control.
 * @dev Contracts inheriting PauseControl can use the `whenNotPaused` modifier to gate functions.
 *      Only accounts with PAUSER_ROLE can pause or unpause.
 */
contract PauseControl is PausableUpgradeable, AccessControlEnumerableUpgradeable {
    // role
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Pauses the contract, disabling functions guarded by `whenNotPaused`.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling functions guarded by `whenNotPaused`.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
