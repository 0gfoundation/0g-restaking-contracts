// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultConfigurator} from "@symbiotic/interfaces/IVaultConfigurator.sol";
import {IBaseDelegator} from "@symbiotic/interfaces/delegator/IBaseDelegator.sol";
import {IOperatorNetworkSpecificDelegator} from "@symbiotic/interfaces/delegator/IOperatorNetworkSpecificDelegator.sol";
import {IVetoSlasher} from "@symbiotic/interfaces/slasher/IVetoSlasher.sol";
import {IBaseSlasher} from "@symbiotic/interfaces/slasher/IBaseSlasher.sol";
import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";
import {INetworkRegistry} from "@symbiotic/interfaces/INetworkRegistry.sol";
import {INetworkMiddlewareService} from "@symbiotic/interfaces/service/INetworkMiddlewareService.sol";

import {IOperators} from "middleware-sdk/interfaces/extensions/operators/IOperators.sol";

import {IDefaultStakerRewardsFactory} from
    "rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewardsFactory.sol";
import {IDefaultStakerRewards} from "rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";

import {IZeroGravityFactory} from "./interfaces/IZeroGravityFactory.sol";
import {IZeroGravityOperator} from "./interfaces/IZeroGravityOperator.sol";

contract ZeroGravityFactory is IZeroGravityFactory, AccessControlUpgradeable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:0g.storage.ZeroGravityFactory
    struct ZeroGravityFactoryStorage {
        address middleware; // zero gravity middleware
        address vaultConfigurator; // symbiotic vault configurator
        uint64 vaultVersion; // version of vault to use in symbiotic vault factory
        uint64 delegatorVersion; // version of delegator to use in symbiotic delegator factory
        uint64 slasherVersion; // version of slasher to use in symbiotic slasher factory
        uint48 epochDuration; // vault epoch duration
        uint48 vetoDuration; // duration of the veto period for a slash request
        uint256 resolverSetEpochsDelay; // delay in epochs for a network to update a resolver
        address operatorRegistry; // symbiotic operator registry
        address operatorBeacon; // common beacon contract for 0g operator
        address resolver; // veto slash resolver
        address operatorVaultOptInService; // symbiotic operator -> vault opt in service
        address operatorNetworkOptInService; // symbiotic operator -> network opt in service
        address defaultStakerRewardsFactory; // symbiotic default staker rewards factory
        EnumerableMap.AddressToUintMap minValidatorDeposit; // minimal amount to deposit when create validator
        mapping(bytes32 => bool) created; // create2 salt used
        mapping(bytes32 => ValidatorInfo) validators; // keccak256(pubkey) => created validators
    }

    // keccak256(abi.encode(uint256(keccak256("0g.storage.ZeroGravityFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ZeroGravityFactoryStorageLocation =
        0xd34a72ca804763fc5784df3b4e88cfbfa103b299a30224f8215fd64cba345600;

    function _getZeroGravityFactoryStorage() internal pure returns (ZeroGravityFactoryStorage storage $) {
        assembly {
            $.slot := ZeroGravityFactoryStorageLocation
        }
    }

    bytes32 public constant UPDATE_COLLATERAL_ROLE = keccak256("UPDATE_COLLATERAL_ROLE");
    uint96 internal constant DEFAULT_SUBNETWORK = 0;

    function initialize(
        bytes memory params
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPDATE_COLLATERAL_ROLE, msg.sender);

        InitParams memory p;
        p = abi.decode(params, (InitParams));

        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        $.vaultConfigurator = p.vaultConfigurator;
        $.vaultVersion = p.vaultVersion;
        $.delegatorVersion = p.delegatorVersion;
        $.slasherVersion = p.slasherVersion;
        $.epochDuration = p.epochDuration;
        $.vetoDuration = p.vetoDuration;
        $.resolverSetEpochsDelay = p.resolverSetEpochsDelay;
        $.operatorRegistry = p.operatorRegistry;
        $.operatorBeacon = p.operatorBeacon;
        $.resolver = p.resolver;
        $.operatorVaultOptInService = p.operatorVaultOptInService;
        $.operatorNetworkOptInService = p.operatorNetworkOptInService;
        $.defaultStakerRewardsFactory = p.defaultStakerRewardsFactory;
    }

    function registerNetwork(
        address middleware,
        address networkRegistry,
        address networkMiddlewareService
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        $.middleware = middleware;
        INetworkRegistry(networkRegistry).registerNetwork();
        INetworkMiddlewareService(networkMiddlewareService).setMiddleware(middleware);
    }

    function updateCollateralConfig(
        address collateral,
        uint256 minValidatorDeposit
    ) external onlyRole(UPDATE_COLLATERAL_ROLE) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        $.minValidatorDeposit.set(collateral, minValidatorDeposit);
    }

    function getValidator(
        bytes memory pubkey
    ) external view returns (ValidatorInfo memory) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        return $.validators[keccak256(pubkey)];
    }

    function createValidator(
        bytes memory pubkey,
        bytes memory signature,
        address collateral,
        uint256 amount
    ) external {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        // check collateral, transfer to contract
        if (!$.minValidatorDeposit.contains(collateral)) {
            revert InvalidCollateral();
        } else {
            uint256 minDeposit = $.minValidatorDeposit.get(collateral);
            if (minDeposit == 0 || amount < minDeposit) {
                revert InsufficientCollateral();
            }
            IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        }
        // create operator contract, register in registry
        address operator;
        {
            bytes32 salt = keccak256(pubkey);
            if ($.created[salt]) {
                revert OperatorCreated();
            }
            $.created[salt] = true;
            operator = address(
                new BeaconProxy{salt: salt}(
                    $.operatorBeacon, abi.encodeCall(IZeroGravityOperator.initialize, ($.operatorRegistry))
                )
            );
        }
        // create vault, delegator, slasher
        (address vault, address delegator, address slasher) = IVaultConfigurator($.vaultConfigurator).create(
            IVaultConfigurator.InitParams({
                version: $.vaultVersion,
                owner: address(this),
                vaultParams: abi.encode(
                    IVault.InitParams({
                        collateral: address(collateral),
                        burner: address(0),
                        epochDuration: $.epochDuration,
                        depositWhitelist: false,
                        isDepositLimit: false,
                        depositLimit: 0,
                        defaultAdminRoleHolder: address(this),
                        depositWhitelistSetRoleHolder: address(0),
                        depositorWhitelistRoleHolder: address(0),
                        isDepositLimitSetRoleHolder: address(0),
                        depositLimitSetRoleHolder: address(0)
                    })
                ),
                delegatorIndex: $.delegatorVersion,
                delegatorParams: abi.encode(
                    IOperatorNetworkSpecificDelegator.InitParams({
                        baseParams: IBaseDelegator.BaseParams({
                            defaultAdminRoleHolder: address(this),
                            hook: address(0),
                            hookSetRoleHolder: address(0)
                        }),
                        network: address(this),
                        operator: operator
                    })
                ),
                withSlasher: true,
                slasherIndex: $.slasherVersion,
                slasherParams: abi.encode(
                    IVetoSlasher.InitParams({
                        baseParams: IBaseSlasher.BaseParams({isBurnerHook: false}),
                        vetoDuration: $.vetoDuration,
                        resolverSetEpochsDelay: $.resolverSetEpochsDelay
                    })
                )
            })
        );
        // network opt into the vault
        IBaseDelegator(delegator).setMaxNetworkLimit(DEFAULT_SUBNETWORK, type(uint256).max);
        // set resovler for veto slasher
        IVetoSlasher(slasher).setResolver(DEFAULT_SUBNETWORK, $.resolver, "");
        // operator opt in network and vault
        IZeroGravityOperator(operator).optIn(
            $.operatorVaultOptInService, vault, $.operatorNetworkOptInService, address(this)
        );
        // register operator and vault to middleware
        IOperators($.middleware).registerOperator(operator, pubkey, vault);
        // staker rewards
        address rewards = IDefaultStakerRewardsFactory($.defaultStakerRewardsFactory).create(
            IDefaultStakerRewards.InitParams({
                vault: vault,
                adminFee: 0,
                defaultAdminRoleHolder: address(this),
                adminFeeClaimRoleHolder: address(0),
                adminFeeSetRoleHolder: address(0)
            })
        );
        // deposit on behalf of sender
        IERC20(collateral).approve(vault, amount);
        IVault(vault).deposit(msg.sender, amount);
        // save validator
        $.validators[keccak256(pubkey)] =
            ValidatorInfo({vault: vault, operator: operator, slasher: slasher, rewards: rewards});

        emit ValidatorCreated(pubkey, signature, collateral, vault, operator, rewards);
    }
}
