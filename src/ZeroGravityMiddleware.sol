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

import {IDefaultStakerRewards} from "rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";

import {IZeroGravityMiddleware} from "./interfaces/IZeroGravityMiddleware.sol";
import {IZeroGravityFactory} from "./interfaces/IZeroGravityFactory.sol";

import {WeightedStakePower} from "./WeightedStakePower.sol";

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
        address network; // network
    }

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant REGISTER_OPERATOR_ROLE = keccak256("REGISTER_OPERATOR_ROLE");
    bytes32 public constant WEIGHT_SET_ROLE = keccak256("WEIGHT_SET_ROLE");

    // keccak256(abi.encode(uint256(keccak256("0g.storage.ZeroGravityMiddleware")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ZeroGravityMiddlewareStorageLocation =
        0xac44c5fd66003021ef4b929366b736fca6f51990a213b46844b02b2973a39d00;

    function _getZeroGravityMiddlewareStorage() internal pure returns (ZeroGravityMiddlewareStorage storage $) {
        assembly {
            $.slot := ZeroGravityMiddlewareStorageLocation
        }
    }

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

    function _getOperatorParams(
        uint48 captureTimestamp,
        bytes memory key
    ) internal view returns (OperatorParams memory params) {
        params.operator = operatorByKey(key);
        params.vaults = _activeVaultsAt(captureTimestamp, params.operator);
        params.subnetworks = _activeSubnetworksAt(captureTimestamp);
        params.totalPower = _getOperatorPowerAt(captureTimestamp, params.operator, params.vaults, params.subnetworks);
    }

    /* 
     * @notice Slashes a validator based on the provided parameters.
     * Here are the hints getter
     * https://github.com/symbioticfi/core/blob/main/src/contracts/hints/VetoSlasherHints.sol
     * https://github.com/symbioticfi/core/blob/main/src/contracts/hints/DelegatorHints.sol
     * @param epoch The epoch for which the slashing occurs.
     * @param key The key of the operator to slash.
     * @param amount The amount to slash.
     * @param stakeHints Hints for determining stakes.
     * @param slashHints Hints for the slashing process.
     */
    function slash(
        uint48 captureTimestamp,
        bytes memory key,
        uint256 power,
        bytes[][] memory stakeHints,
        bytes[] memory slashHints
    ) public override checkAccess {
        OperatorParams memory params = _getOperatorParams(captureTimestamp, key);

        _checkCanSlash(captureTimestamp, key, params.operator);

        uint256 vaultsLength = params.vaults.length;
        uint256 subnetworksLength = params.subnetworks.length;

        // Validate hints lengths upfront
        if (stakeHints.length != slashHints.length || stakeHints.length != vaultsLength) {
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

                uint256 slashAmount =
                    powerToStake(vault, Math.mulDiv(power, stakeToPower(vault, stake), params.totalPower));
                if (slashAmount == 0) {
                    continue;
                }

                _slashVault(captureTimestamp, vault, subnetwork, params.operator, slashAmount, slashHints[i]);
            }
        }
    }

    function executeSlashs(address[] memory vaults, uint256[] memory slashIndexes, bytes[] memory hints) external {
        for (uint256 i = 0; i < vaults.length; ++i) {
            _executeSlash(vaults[i], slashIndexes[i], hints[i]);
        }
    }

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

    function distributeRewards(
        bytes memory key,
        uint48 captureTimestamp,
        address token,
        uint256 amount,
        bytes[][] memory stakeHints
    ) external override {
        ZeroGravityMiddlewareStorage storage $ = _getZeroGravityMiddlewareStorage();
        // move token
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        amount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        // get operator vaults
        OperatorParams memory params = _getOperatorParams(captureTimestamp, key);
        if (params.operator == address(0)) {
            revert InvalidOperator();
        }
        // distribute rewards
        uint256 vaultsLength = params.vaults.length;
        uint256 subnetworksLength = params.subnetworks.length;

        for (uint256 i; i < vaultsLength; ++i) {
            address vault = params.vaults[i];
            for (uint256 j; j < subnetworksLength; ++j) {
                bytes32 subnetwork = _NETWORK().subnetwork(uint96(params.subnetworks[j]));
                uint256 stake = IBaseDelegator(IVault(vault).delegator()).stakeAt(
                    subnetwork, params.operator, captureTimestamp, stakeHints[i][j]
                );

                uint256 rewardAmount = Math.mulDiv(amount, stakeToPower(vault, stake), params.totalPower);
                if (rewardAmount == 0) {
                    continue;
                }

                address rewarder = IZeroGravityFactory($.network).getRewarder(vault);
                IERC20(token).approve(rewarder, rewardAmount);
                IDefaultStakerRewards(rewarder).distributeRewards(
                    $.network,
                    token,
                    rewardAmount,
                    abi.encode(captureTimestamp, IDefaultStakerRewards(rewarder).adminFee(), "", "")
                );
            }
        }
    }
}
