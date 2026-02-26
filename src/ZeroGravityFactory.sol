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
import {IBaseMiddlewareReader} from "middleware-sdk/interfaces/IBaseMiddlewareReader.sol";

import {IZeroGravityFactory} from "./interfaces/IZeroGravityFactory.sol";
import {IZeroGravityOperator} from "./interfaces/IZeroGravityOperator.sol";
import {IZeroGravityMiddleware} from "./interfaces/IZeroGravityMiddleware.sol";

import {Create2Helper} from "./libraries/Create2Helper.sol";

import {PauseControl} from "./security/PauseControl.sol";

contract ZeroGravityFactory is IZeroGravityFactory, PauseControl {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
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
        address rewarderFactory; // address of rewarder factory
        bytes32 rewarderInitCodeHash; // init code hash for rewarder in rewarder factory
        EnumerableMap.AddressToUintMap minValidatorDeposit; // minimal amount to deposit when create validator
        mapping(bytes32 => address) operators; // create2 salt => operator address
        mapping(address => mapping(address => address)) createdVaults; // operator => collateral => created vault
        EnumerableSet.UintSet satelliteChains; // satellite chains
        mapping(uint256 => SatelliteChainParams) satelliteChainParams; // satellite chain id => satellite chain params
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

    /// @dev The length of the public key, PUBLIC_KEY_LENGTH bytes.
    uint8 internal constant PUBLIC_KEY_LENGTH = 48;

    /// @dev The length of the signature, SIGNATURE_LENGTH bytes.
    uint8 internal constant SIGNATURE_LENGTH = 96;

    /// @dev The length of the credentials, 1 byte prefix + 11 bytes padding + 20 bytes address = 32 bytes.
    uint8 internal constant CREDENTIALS_LENGTH = 32;

    function initialize(
        bytes memory params
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPDATE_COLLATERAL_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        _setParams(params);
    }

    function _setParams(
        bytes memory params
    ) internal {
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
        $.rewarderFactory = p.rewarderFactory;
        $.rewarderInitCodeHash = p.rewarderInitCodeHash;
    }

    function getParams() external view returns (InitParams memory params) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        params = InitParams({
            vaultConfigurator: $.vaultConfigurator,
            vaultVersion: $.vaultVersion,
            delegatorVersion: $.delegatorVersion,
            slasherVersion: $.slasherVersion,
            epochDuration: $.epochDuration,
            vetoDuration: $.vetoDuration,
            resolverSetEpochsDelay: $.resolverSetEpochsDelay,
            operatorRegistry: $.operatorRegistry,
            operatorBeacon: $.operatorBeacon,
            resolver: $.resolver,
            operatorVaultOptInService: $.operatorVaultOptInService,
            operatorNetworkOptInService: $.operatorNetworkOptInService,
            rewarderFactory: $.rewarderFactory,
            rewarderInitCodeHash: $.rewarderInitCodeHash
        });
    }

    function setParams(
        bytes memory params
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParams(params);
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

    function updateRewarderInitCodeHash(
        bytes32 hash
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        $.rewarderInitCodeHash = hash;
    }

    function updateCollateralConfig(
        address collateral,
        uint256 minValidatorDeposit
    ) external onlyRole(UPDATE_COLLATERAL_ROLE) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        $.minValidatorDeposit.set(collateral, minValidatorDeposit);
    }

    function _createOperatorIfNotExists(
        bytes memory pubkey
    ) internal returns (address operator) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        operator = IBaseMiddlewareReader($.middleware).operatorByKey(pubkey);
        if (operator == address(0)) {
            bytes32 salt = keccak256(pubkey);
            operator = address(
                new BeaconProxy{salt: salt}(
                    $.operatorBeacon, abi.encodeCall(IZeroGravityOperator.initialize, ($.operatorRegistry))
                )
            );
            $.operators[salt] = operator;
        }
    }

    /// @dev Add a satellite chain
    /// @param chainId The id of the satellite chain
    /// @param params The params of the satellite chain
    function addSatelliteChain(
        uint256 chainId,
        SatelliteChainParams memory params
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();

        $.satelliteChains.add(chainId);
        emit AddSatelliteChain(chainId);

        _updateSatelliteChainParams(chainId, params);
    }

    /// @dev Check if a chain is a satellite chain
    function isSatelliteChain(
        uint256 chainId
    ) external view override returns (bool) {
        return _isSatelliteChain(chainId);
    }

    function _isSatelliteChain(
        uint256 chainId
    ) internal view returns (bool) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        return $.satelliteChains.contains(chainId);
    }

    /// @dev Update the params of a satellite chain
    /// @param chainId The id of the satellite chain
    /// @param params The params of the satellite chain
    function updateSatelliteChainParams(
        uint256 chainId,
        SatelliteChainParams memory params
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateSatelliteChainParams(chainId, params);
    }

    function getSatelliteChainParams(
        uint256 chainId
    ) external view override returns (SatelliteChainParams memory params) {
        params = _getSatelliteChainParams(chainId);
    }

    function _getSatelliteChainParams(
        uint256 chainId
    ) internal view returns (SatelliteChainParams memory params) {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        params = $.satelliteChainParams[chainId];
    }

    function _updateSatelliteChainParams(uint256 chainId, SatelliteChainParams memory params) internal {
        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        $.satelliteChainParams[chainId] = params;
        emit UpdateSatelliteChainParams(chainId, params);
    }

    function createSatelliteValidator(
        bytes memory pubkey,
        uint256 chainId,
        bytes memory signature,
        bytes memory _satelliteValidatorInfo
    ) external override whenNotPaused {
        if (pubkey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPubKeyLength();
        }

        if (signature.length != SIGNATURE_LENGTH) {
            revert InvalidSignatureLength();
        }

        if (!_isSatelliteChain(chainId)) {
            revert InvalidSatelliteChain();
        }

        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        if (IBaseMiddlewareReader($.middleware).operatorByKey(pubkey) == address(0)) {
            revert MainChainValidatorNotFound();
        }

        SatelliteChainParams memory params = $.satelliteChainParams[chainId];
        address rewarder;
        if (params.rewarderFactory != address(0) && params.rewarderInitCodeHash != bytes32(0)) {
            rewarder = Create2Helper.computeCreate2Address(
                params.rewarderFactory, keccak256(pubkey), params.rewarderInitCodeHash
            );
        }

        emit SatelliteValidatorCreated(chainId, pubkey, signature, _satelliteValidatorInfo, rewarder);
    }

    function createValidator(
        bytes memory pubkey,
        bytes memory credentials,
        bytes memory signature,
        address onBehalfOf,
        address collateral,
        uint256 amount
    ) external override whenNotPaused {
        if (pubkey.length != PUBLIC_KEY_LENGTH) {
            revert InvalidPubKeyLength();
        }

        if (credentials.length != CREDENTIALS_LENGTH) {
            revert InvalidCredentialsLength();
        }

        if (signature.length != SIGNATURE_LENGTH) {
            revert InvalidSignatureLength();
        }

        ZeroGravityFactoryStorage storage $ = _getZeroGravityFactoryStorage();
        if ($.rewarderFactory == address(0) || $.rewarderInitCodeHash == bytes32(0)) {
            revert MissingRewarderCreate2Info();
        }
        // check collateral, transfer to contract
        if (!$.minValidatorDeposit.contains(collateral)) {
            revert InvalidCollateral();
        } else {
            // check amount, or sender is admin
            if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                uint256 minDeposit = $.minValidatorDeposit.get(collateral);
                if (minDeposit == 0 || amount < minDeposit) {
                    revert InsufficientCollateral();
                }
            }
            if (amount > 0) {
                uint256 balanceBefore = IERC20(collateral).balanceOf(address(this));
                IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
                amount = IERC20(collateral).balanceOf(address(this)) - balanceBefore;
            }
        }
        // calculate rewarder
        address rewarder =
            Create2Helper.computeCreate2Address($.rewarderFactory, keccak256(pubkey), $.rewarderInitCodeHash);
        // create operator contract, register in registry
        address operator = _createOperatorIfNotExists(pubkey);
        // create vault, delegator, slasher if not created
        address vault;
        if ($.createdVaults[operator][collateral] == address(0)) {
            address delegator;
            address slasher;
            (vault, delegator, slasher) = IVaultConfigurator($.vaultConfigurator).create(
                IVaultConfigurator.InitParams({
                    version: $.vaultVersion,
                    owner: address(this),
                    vaultParams: abi.encode(
                        IVault.InitParams({
                            collateral: address(collateral),
                            burner: address(0xdead),
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
            $.createdVaults[operator][collateral] = vault;
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
        }

        vault = $.createdVaults[operator][collateral];
        // emit event anyways, can be used to resubmit signature
        emit ValidatorCreated(pubkey, credentials, signature, collateral, rewarder, vault, operator);

        // deposit on behalf of sender
        if (amount > 0) {
            IERC20(collateral).approve(vault, amount);
            IVault(vault).deposit(onBehalfOf, amount);
        }
    }
}
