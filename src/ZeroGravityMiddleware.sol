// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";
import {IBaseDelegator} from "@symbiotic/interfaces/delegator/IBaseDelegator.sol";
import {IVetoSlasher} from "@symbiotic/interfaces/slasher/IVetoSlasher.sol";
import {Subnetwork} from "@symbiotic/contracts/libraries/Subnetwork.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {KeyManagerBytes} from "middleware-sdk/extensions/managers/keys/KeyManagerBytes.sol";
import {OzAccessControl} from "middleware-sdk/extensions/managers/access/OzAccessControl.sol";
import {Operators} from "middleware-sdk/extensions/operators/Operators.sol";
import {TimestampCapture} from "middleware-sdk/extensions/managers/capture-timestamps/TimestampCapture.sol";
import {SharedVaults} from "middleware-sdk/extensions/SharedVaults.sol";

import {IZeroGravityMiddleware} from "./interfaces/IZeroGravityMiddleware.sol";
import {IZeroGravityFactory} from "./interfaces/IZeroGravityFactory.sol";

import {WeightedStakePower} from "./WeightedStakePower.sol";

/**
 * @title ZeroGravityMiddleware
 * @notice 0G middleware integrated with Symbiotic for operator management, key tracking, and slashing.
 * @dev Inherits from SharedVaults, KeyManagerBytes, Operators, TimestampCapture, OzAccessControl, and
 *      WeightedStakePower. Handles operator registration/deregistration, BLS key management, collateral
 *      weight configuration, and proportional slashing across vaults and subnetworks.
 */
contract ZeroGravityMiddleware is
    IZeroGravityMiddleware,
    SharedVaults,
    KeyManagerBytes,
    Operators,
    TimestampCapture,
    OzAccessControl,
    WeightedStakePower
{
    using Subnetwork for address;
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:0g.storage.ZeroGravityMiddleware
    struct ZeroGravityMiddlewareStorage {
        /// @dev Address of the network (ZeroGravityFactory)
        address network;
    }

    /// @dev Role required to execute slashing
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    /// @dev Role required to register operators
    bytes32 public constant REGISTER_OPERATOR_ROLE = keccak256("REGISTER_OPERATOR_ROLE");

    /// @dev Role required to set collateral weights
    bytes32 public constant WEIGHT_SET_ROLE = keccak256("WEIGHT_SET_ROLE");

    // keccak256(abi.encode(uint256(keccak256("0g.storage.ZeroGravityMiddleware")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ZeroGravityMiddlewareStorageLocation =
        0xac44c5fd66003021ef4b929366b736fca6f51990a213b46844b02b2973a39d00;

    function _getZeroGravityMiddlewareStorage() internal pure returns (ZeroGravityMiddlewareStorage storage $) {
        assembly {
            $.slot := ZeroGravityMiddlewareStorageLocation
        }
    }

    /// @notice Initializes the middleware with Symbiotic infrastructure and access control roles.
    /// @param params ABI-encoded InitParams struct
    function initialize(
        bytes memory params
    ) external initializer {
        InitParams memory p;
        p = abi.decode(params, (InitParams));

        __BaseMiddleware_init(
            p.network, p.slashingWindow, p.vaultRegistry, p.operatorRegistry, p.operatorNetOptin, p.reader
        );
        __OzAccessControl_init(p.defaultAdmin);

        // setup roles
        _setSelectorRole(Operators.registerOperator.selector, REGISTER_OPERATOR_ROLE);
        _grantRole(REGISTER_OPERATOR_ROLE, p.network);
        _setSelectorRole(IZeroGravityMiddleware.slash.selector, SLASHER_ROLE);
        _setSelectorRole(WeightedStakePower.setCollateralWeight.selector, WEIGHT_SET_ROLE);

        ZeroGravityMiddlewareStorage storage $ = _getZeroGravityMiddlewareStorage();
        $.network = p.network;
    }

    /// @notice Updates the slashing window duration.
    /// @param slashingWindow The new slashing window duration in seconds
    function setSlashingWindow(
        uint48 slashingWindow
    ) external checkAccess {
        assembly {
            sstore(0x937e0d2984afc3afaa413d74098ba180cc0c6aae6527cc2713827ed6bc72f200, slashingWindow)
        }
    }

    /**
     * @dev Registers an operator and optionally associates a vault. If the operator is not yet
     *      registered, registers them and sets their BLS key. If a vault is provided, registers
     *      the operator-vault association.
     * @param operator Address of the operator contract
     * @param key The operator's BLS public key
     * @param vault Address of the vault to associate (or address(0) to skip)
     */
    function _registerOperatorImpl(address operator, bytes memory key, address vault) internal override {
        if (!_isOperatorRegistered(operator)) {
            _beforeRegisterOperator(operator, key, vault);
            _registerOperator(operator);
            _updateOperatorKeyImpl(operator, key);
        }
        if (vault != address(0)) {
            _beforeRegisterOperatorVault(operator, vault);
            _registerOperatorVault(operator, vault);
        }
    }

    /**
     * @dev Resolves an operator's full state at a capture timestamp: their address, active vaults,
     *      active subnetworks, and total voting power.
     * @param captureTimestamp The timestamp at which to capture the operator's state
     * @param key The operator's BLS public key
     * @return params The operator's resolved state
     */
    function _getOperatorParams(
        uint48 captureTimestamp,
        bytes memory key
    ) internal view returns (OperatorParams memory params) {
        params.operator = operatorByKey(key);
        params.vaults = _activeVaultsAt(captureTimestamp, params.operator);
        params.subnetworks = _activeSubnetworksAt(captureTimestamp);
        params.totalPower = _getOperatorPowerAt(captureTimestamp, params.operator, params.vaults, params.subnetworks);
    }

    /**
     * @notice Slashes a validator proportionally across all their vaults and subnetworks.
     * @dev The slash amount is distributed proportionally based on each vault's weighted power
     *      relative to the operator's total power. For each vault/subnetwork pair, the power-based
     *      slash is converted back to a stake amount using the collateral's weight.
     *      Hint arrays must match vault/subnetwork dimensions.
     *      See https://github.com/symbioticfi/core/blob/main/src/contracts/hints/VetoSlasherHints.sol
     *      and https://github.com/symbioticfi/core/blob/main/src/contracts/hints/DelegatorHints.sol
     * @param captureTimestamp The timestamp at which stake state is captured for slashing
     * @param key The BLS public key identifying the operator to slash
     * @param power The total voting power amount to slash
     * @param stakeHints Hints for stake lookups, indexed [vault][subnetwork]
     * @param slashHints Hints for the VetoSlasher, indexed per vault
     * @param weightHints Hints for collateral weight lookups, indexed per vault
     */
    function slash(
        uint48 captureTimestamp,
        bytes memory key,
        uint256 power,
        bytes[][] memory stakeHints,
        bytes[] memory slashHints,
        bytes[] memory weightHints
    ) public override checkAccess {
        OperatorParams memory params = _getOperatorParams(captureTimestamp, key);

        _checkCanSlash(captureTimestamp, key, params.operator);

        uint256 vaultsLength = params.vaults.length;
        uint256 subnetworksLength = params.subnetworks.length;

        // Validate hints lengths upfront
        if (
            stakeHints.length != slashHints.length || stakeHints.length != vaultsLength
                || weightHints.length != slashHints.length
        ) {
            revert InvalidHints();
        }

        for (uint256 i; i < vaultsLength; ++i) {
            if (stakeHints[i].length != subnetworksLength) {
                revert InvalidHints();
            }

            address vault = params.vaults[i];
            for (uint256 j; j < subnetworksLength; ++j) {
                bytes32 subnetwork = _NETWORK().subnetwork(uint96(params.subnetworks[j]));
                uint256 stake = IBaseDelegator(IVault(vault).delegator()).stakeAt(
                    subnetwork, params.operator, captureTimestamp, stakeHints[i][j]
                );
                address collateral = IVault(vault).collateral();
                uint256 weight = _getCollateralWeight(collateral, captureTimestamp, weightHints[i]);
                uint256 vaultPower = _stakeToPower(stake, weight, collateral);
                uint256 slashAmount =
                    _powerToStake(Math.mulDiv(power, vaultPower, params.totalPower), weight, collateral);
                if (slashAmount == 0) {
                    continue;
                }

                _slashVault(captureTimestamp, vault, subnetwork, params.operator, slashAmount, slashHints[i]);
            }
        }
    }

    /// @notice Executes pending slash requests across multiple vaults.
    /// @param vaults Array of vault addresses with pending slashes
    /// @param slashIndexes Array of slash request indexes to execute
    /// @param hints Array of execution hints for each slash
    function executeSlashs(address[] memory vaults, uint256[] memory slashIndexes, bytes[] memory hints) external {
        for (uint256 i = 0; i < vaults.length; ++i) {
            _executeSlash(vaults[i], slashIndexes[i], hints[i]);
        }
    }

    /**
     * @dev Validates that a slash can be performed: the operator must exist, the key must have
     *      been active, and the operator must have been active at the capture timestamp.
     * @param epochStart The capture timestamp for the slash
     * @param key The operator's BLS public key
     * @param operator The operator's contract address
     */
    function _checkCanSlash(uint48 epochStart, bytes memory key, address operator) internal view {
        if (operator == address(0)) {
            revert NotExistKeySlash(); // Revert if the operator does not exist
        }

        if (!keyWasActiveAt(epochStart, key)) {
            revert InactiveKeySlash(); // Revert if the key is inactive
        }

        if (!_operatorWasActiveAt(epochStart, operator)) {
            revert InactiveOperatorSlash(); // Revert if the operator wasn't active
        }
    }
}
