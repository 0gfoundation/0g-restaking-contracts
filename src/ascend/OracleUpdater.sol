// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMellowOracle, IMellowSourceCore} from "../interfaces/IMellowSourceCore.sol";
import {IOracleUpdater} from "../interfaces/IOracleUpdater.sol";

/**
 * @title OracleUpdater
 * @notice Bounded writer for the aOG vault's share-price oracle. It holds the oracle's
 *         `SET_VALUE_ROLE` in place of the operator account, and only forwards a value that lies
 *         between the oracle's current value and the share price the vault's on-chain assets back.
 *
 * @dev The lower bound stops a leaked operator key from pricing the vault down: a low price mints
 *      aOG cheaply and pays out more of anything redeemed against it at that price.
 *
 *      The upper bound is the vault's net asset value as seen from this chain: W0G held by the
 *      SourceCore plus W0G locked in its OFT adapter, over the aOG supply. The adapter is a lockbox
 *      that only the SourceCore can send through, so its balance is the amount bridged out, and
 *      nothing short of donating W0G to the vault can raise this figure. A pending withdrawal stays
 *      in both terms until its epoch is handled, which burns the shares and removes their assets in
 *      one call. What this chain cannot see is a loss on the Ethereum leg; that only makes the
 *      bound loose, and lowering the price after a loss remains the multisig's call, made on the
 *      oracle directly.
 */
contract OracleUpdater is AccessControlUpgradeable, IOracleUpdater {
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    /// @custom:storage-location erc7201:0g.restaking.OracleUpdater
    struct OracleUpdaterStorage {
        IMellowSourceCore sourceCore;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.restaking.OracleUpdater")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OracleUpdaterStorageLocation =
        0x7474a41efd251a23474c27eb890a47951f2eaa277fafe1d272ba1e1762a67f00;

    function _getOracleUpdaterStorage() internal pure returns (OracleUpdaterStorage storage $) {
        assembly {
            $.slot := OracleUpdaterStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address sourceCore_, address admin, address updater) external initializer {
        if (sourceCore_ == address(0) || admin == address(0) || updater == address(0)) {
            revert OracleUpdaterZeroAddress();
        }
        if (sourceCore_.code.length == 0) {
            revert OracleUpdaterNotAContract(sourceCore_);
        }

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPDATER_ROLE, updater);

        _getOracleUpdaterStorage().sourceCore = IMellowSourceCore(sourceCore_);
    }

    /// @inheritdoc IOracleUpdater
    function setValue(
        uint256 value
    ) external override onlyRole(UPDATER_ROLE) {
        IMellowOracle oracle = _getOracleUpdaterStorage().sourceCore.oracle();
        // `value()` rather than `getValue()`: the latter reverts once the oracle is stale, and
        // refreshing a stale oracle is one of the things this call must be able to do.
        uint256 current = oracle.value();
        if (value < current) {
            revert OracleUpdaterValueDecrease(current, value);
        }
        uint256 bound = maxValue();
        if (value > bound) {
            revert OracleUpdaterValueAboveNav(bound, value);
        }
        oracle.setValue(value);
    }

    /// @inheritdoc IOracleUpdater
    function maxValue() public view override returns (uint256) {
        IMellowSourceCore core = _getOracleUpdaterStorage().sourceCore;
        uint256 supply = core.totalSupply();
        if (supply == 0) {
            revert OracleUpdaterZeroSupply();
        }
        IERC20 asset = IERC20(core.asset());
        uint256 assets = asset.balanceOf(address(core)) + asset.balanceOf(core.oftAdapter());
        return Math.mulDiv(assets, 1 ether, supply);
    }

    /// @inheritdoc IOracleUpdater
    function sourceCore() external view override returns (IMellowSourceCore) {
        return _getOracleUpdaterStorage().sourceCore;
    }
}
