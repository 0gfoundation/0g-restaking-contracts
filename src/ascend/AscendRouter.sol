// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";

import {IWETH} from "../interfaces/IWETH.sol";
import {IAscendRouter} from "../interfaces/IAscendRouter.sol";

contract AscendRouter is AccessControlUpgradeable, IAscendRouter {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:0g.restaking.AscendRouter
    struct AscendRouterStorage {
        address WETH;
        // receivers
        address mellowVault;
        address foundation;
        address paymentLayer;
        // receiver percentage (18 decimals)
        uint256 mellowVaultPercentage;
        uint256 foundationPercentage;
        uint256 paymentLayerPercentage;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.restaking.AscendRouter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AscendRouterStorageLocation =
        0x24b037f3dd1df118cb4b00140f6efdcb8d23d4119a7c1d253bd0c02bb20e7900;

    function _getAscendRouterStorage() internal pure returns (AscendRouterStorage storage $) {
        assembly {
            $.slot := AscendRouterStorageLocation
        }
    }

    function initialize(
        address wETH,
        address mellowVault,
        address foundation,
        address paymentLayer,
        uint256 mellowVaultPercentage,
        uint256 foundationPercentage,
        uint256 paymentLayerPercentage
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        AscendRouterStorage storage $ = _getAscendRouterStorage();
        $.WETH = wETH;
        $.mellowVault = mellowVault;
        $.foundation = foundation;
        $.paymentLayer = paymentLayer;
        $.mellowVaultPercentage = mellowVaultPercentage;
        $.foundationPercentage = foundationPercentage;
        $.paymentLayerPercentage = paymentLayerPercentage;

        _checkParams();
    }

    function _checkParams() internal view {
        AscendRouterStorage storage $ = _getAscendRouterStorage();
        if ($.mellowVaultPercentage + $.foundationPercentage + $.paymentLayerPercentage != 10 ** 18) {
            revert AscendRouterInvalidParams();
        }
    }

    function updateParams(
        address mellowVault,
        address foundation,
        address paymentLayer,
        uint256 mellowVaultPercentage,
        uint256 foundationPercentage,
        uint256 paymentLayerPercentage
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        AscendRouterStorage storage $ = _getAscendRouterStorage();
        $.mellowVault = mellowVault;
        $.foundation = foundation;
        $.paymentLayer = paymentLayer;
        $.mellowVaultPercentage = mellowVaultPercentage;
        $.foundationPercentage = foundationPercentage;
        $.paymentLayerPercentage = paymentLayerPercentage;

        _checkParams();
    }

    // View function to get current parameters
    function getParams()
        external
        view
        override
        returns (
            address WETH,
            address mellowVault,
            address foundation,
            address paymentLayer,
            uint256 mellowVaultPercentage,
            uint256 foundationPercentage,
            uint256 paymentLayerPercentage
        )
    {
        AscendRouterStorage storage $ = _getAscendRouterStorage();
        return (
            $.WETH,
            $.mellowVault,
            $.foundation,
            $.paymentLayer,
            $.mellowVaultPercentage,
            $.foundationPercentage,
            $.paymentLayerPercentage
        );
    }

    function distribute() external override {
        AscendRouterStorage storage $ = _getAscendRouterStorage();
        // swap to WETH
        uint256 amount = address(this).balance;
        IWETH($.WETH).deposit{value: amount}();
        // distribute
        uint256 mellowVaultAmount = (amount * $.mellowVaultPercentage) / 10 ** 18;
        uint256 foundationAmount = (amount * $.foundationPercentage) / 10 ** 18;
        uint256 paymentLayerAmount = (amount * $.paymentLayerPercentage) / 10 ** 18;
        if (mellowVaultAmount > 0 && $.mellowVault != address(0)) {
            IERC20($.WETH).safeTransfer($.mellowVault, mellowVaultAmount);
            emit Distributed($.mellowVault, mellowVaultAmount);
        }
        if (foundationAmount > 0 && $.foundation != address(0)) {
            IERC20($.WETH).safeTransfer($.foundation, foundationAmount);
            emit Distributed($.foundation, foundationAmount);
        }
        if (paymentLayerAmount > 0 && $.paymentLayer != address(0)) {
            IERC20($.WETH).safeTransfer($.paymentLayer, paymentLayerAmount);
            emit Distributed($.paymentLayer, paymentLayerAmount);
        }
    }

    fallback() external payable {}

    receive() external payable {}
}
