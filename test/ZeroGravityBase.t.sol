// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {VaultFactory} from "@symbiotic/contracts/VaultFactory.sol";
import {DelegatorFactory} from "@symbiotic/contracts/DelegatorFactory.sol";
import {SlasherFactory} from "@symbiotic/contracts/SlasherFactory.sol";
import {NetworkRegistry} from "@symbiotic/contracts/NetworkRegistry.sol";
import {OperatorRegistry} from "@symbiotic/contracts/OperatorRegistry.sol";
import {NetworkMiddlewareService} from "@symbiotic/contracts/service/NetworkMiddlewareService.sol";
import {OptInService} from "@symbiotic/contracts/service/OptInService.sol";
import {VaultConfigurator} from "@symbiotic/contracts/VaultConfigurator.sol";
import {Vault} from "@symbiotic/contracts/vault/Vault.sol";
import {NetworkRestakeDelegator} from "@symbiotic/contracts/delegator/NetworkRestakeDelegator.sol";
import {FullRestakeDelegator} from "@symbiotic/contracts/delegator/FullRestakeDelegator.sol";
import {OperatorSpecificDelegator} from "@symbiotic/contracts/delegator/OperatorSpecificDelegator.sol";
import {OperatorNetworkSpecificDelegator} from "@symbiotic/contracts/delegator/OperatorNetworkSpecificDelegator.sol";
import {Slasher} from "@symbiotic/contracts/slasher/Slasher.sol";
import {VetoSlasher} from "@symbiotic/contracts/slasher/VetoSlasher.sol";

import {BaseMiddlewareReader} from "middleware-sdk/middleware/BaseMiddlewareReader.sol";

import {Token} from "./mocks/Token.sol";

import {IZeroGravityFactory} from "../src/interfaces/IZeroGravityFactory.sol";
import {IZeroGravityMiddleware} from "../src/interfaces/IZeroGravityMiddleware.sol";
import {ZeroGravityFactory} from "../src/ZeroGravityFactory.sol";
import {ZeroGravityMiddleware} from "../src/ZeroGravityMiddleware.sol";
import {ZeroGravityOperator} from "../src/ZeroGravityOperator.sol";

import {RewarderFactoryTest} from "./RewarderFactory.t.sol";

contract ZeroGravityBaseTest is RewarderFactoryTest {
    uint48 public constant VAULT_EPOCH_DURATION = 2 weeks;
    uint48 public constant VETO_DURATION = 1 days;
    uint48 public constant RESOLVER_SET_EPOCHS_DELAY = 1 days;
    uint48 public constant SLASHING_WINDOW = 1 weeks;

    address private owner;
    address alice;
    uint256 alicePrivateKey;
    address bob;
    uint256 bobPrivateKey;

    VaultFactory vaultFactory;
    DelegatorFactory delegatorFactory;
    SlasherFactory slasherFactory;
    NetworkRegistry networkRegistry;
    OperatorRegistry operatorRegistry;
    NetworkMiddlewareService networkMiddlewareService;
    OptInService operatorVaultOptInService;
    OptInService operatorNetworkOptInService;

    uint64 operatorNetworkSpecificDelegatorType;
    uint64 vetoSlasherType;

    Token zgtoken;
    Token eth;
    VaultConfigurator vaultConfigurator;

    ZeroGravityFactory network;
    ZeroGravityMiddleware middleware;

    address resolver;
    uint256 resolverPrivateKey;

    UpgradeableBeacon operatorBeacon;
    BaseMiddlewareReader middlewareReader; // the BaseMiddlewareReader contract
    BaseMiddlewareReader reader; // the network contract but with reader interface

    function _topUpTokens(
        address val
    ) internal {
        eth.transfer(val, 32 * 1e18);
        zgtoken.transfer(val, 32 * 1e18);
        vm.deal(val, 1 ether);
        vm.startPrank(val);
        zgtoken.approve(address(network), type(uint256).max);
        eth.approve(address(network), type(uint256).max);
        vm.stopPrank();
    }

    function _networkInitParams() internal view returns (IZeroGravityFactory.InitParams memory) {
        return IZeroGravityFactory.InitParams({
            vaultConfigurator: address(vaultConfigurator),
            vaultVersion: 1,
            delegatorVersion: operatorNetworkSpecificDelegatorType,
            slasherVersion: vetoSlasherType,
            epochDuration: VAULT_EPOCH_DURATION,
            vetoDuration: VETO_DURATION,
            resolverSetEpochsDelay: RESOLVER_SET_EPOCHS_DELAY,
            operatorRegistry: address(operatorRegistry),
            operatorBeacon: address(operatorBeacon),
            resolver: resolver,
            operatorVaultOptInService: address(operatorVaultOptInService),
            operatorNetworkOptInService: address(operatorNetworkOptInService),
            rewarderFactory: address(rewarderFactory),
            rewarderInitCodeHash: rewarderFactory.rewarderInitCodeHash()
        });
    }

    function _middlewareInitParams() internal view returns (IZeroGravityMiddleware.InitParams memory) {
        return IZeroGravityMiddleware.InitParams({
            network: address(network),
            slashingWindow: SLASHING_WINDOW,
            vaultRegistry: address(vaultFactory),
            operatorRegistry: address(operatorRegistry),
            operatorNetOptin: address(operatorNetworkOptInService),
            reader: address(middlewareReader),
            defaultAdmin: address(this)
        });
    }

    function setUp() public virtual override {
        super.setUp();

        vm.warp(1 days * 365);

        _deploySymbiotic();

        // resolver
        (resolver, resolverPrivateKey) = makeAddrAndKey("resolver");
        vm.deal(resolver, 1 ether);

        // operator beacon
        ZeroGravityOperator operatorImpl = new ZeroGravityOperator();
        operatorBeacon = new UpgradeableBeacon(address(operatorImpl), owner);

        // network
        bytes memory params = abi.encode(_networkInitParams());
        ZeroGravityFactory factoryImpl = new ZeroGravityFactory();
        UpgradeableBeacon factoryBeacon = new UpgradeableBeacon(address(factoryImpl), owner);
        BeaconProxy factoryProxy =
            new BeaconProxy(address(factoryBeacon), abi.encodeCall(ZeroGravityFactory.initialize, (params)));
        network = ZeroGravityFactory(address(factoryProxy));

        // middleware
        middlewareReader = new BaseMiddlewareReader();
        params = abi.encode(_middlewareInitParams());
        ZeroGravityMiddleware middlewareImpl = new ZeroGravityMiddleware();
        UpgradeableBeacon middlewareBeacon = new UpgradeableBeacon(address(middlewareImpl), owner);
        BeaconProxy middlewareProxy =
            new BeaconProxy(address(middlewareBeacon), abi.encodeCall(ZeroGravityMiddleware.initialize, (params)));
        middleware = ZeroGravityMiddleware(address(middlewareProxy));
        reader = BaseMiddlewareReader(address(middlewareProxy));
        middleware.grantRole(middleware.SLASHER_ROLE(), address(this));
        middleware.grantRole(middleware.WEIGHT_SET_ROLE(), address(this));

        network.registerNetwork(address(middleware), address(networkRegistry), address(networkMiddlewareService));

        vm.warp(block.timestamp + 1);
    }

    function _stakeHints(bytes memory pubkey, uint48 timestamp) internal view returns (bytes[][] memory stakeHints) {
        address operator = middleware.operatorByKey(pubkey);
        uint256 len = reader.activeOperatorVaultsAt(timestamp, operator).length;
        stakeHints = new bytes[][](len);
        for (uint256 i = 0; i < len; ++i) {
            stakeHints[i] = new bytes[](1);
        }
    }

    function _deploySymbiotic() internal {
        owner = address(this);

        vaultFactory = new VaultFactory(owner);
        delegatorFactory = new DelegatorFactory(owner);
        slasherFactory = new SlasherFactory(owner);
        networkRegistry = new NetworkRegistry();
        operatorRegistry = new OperatorRegistry();
        networkMiddlewareService = new NetworkMiddlewareService(address(networkRegistry));
        operatorVaultOptInService =
            new OptInService(address(operatorRegistry), address(vaultFactory), "OperatorVaultOptInService");
        operatorNetworkOptInService =
            new OptInService(address(operatorRegistry), address(networkRegistry), "OperatorNetworkOptInService");

        address vaultImpl =
            address(new Vault(address(delegatorFactory), address(slasherFactory), address(vaultFactory)));
        vaultFactory.whitelist(vaultImpl);

        address networkRestakeDelegatorImpl = address(
            new NetworkRestakeDelegator(
                address(networkRegistry),
                address(vaultFactory),
                address(operatorVaultOptInService),
                address(operatorNetworkOptInService),
                address(delegatorFactory),
                delegatorFactory.totalTypes()
            )
        );
        delegatorFactory.whitelist(networkRestakeDelegatorImpl);

        address fullRestakeDelegatorImpl = address(
            new FullRestakeDelegator(
                address(networkRegistry),
                address(vaultFactory),
                address(operatorVaultOptInService),
                address(operatorNetworkOptInService),
                address(delegatorFactory),
                delegatorFactory.totalTypes()
            )
        );
        delegatorFactory.whitelist(fullRestakeDelegatorImpl);

        address operatorSpecificDelegatorImpl = address(
            new OperatorSpecificDelegator(
                address(operatorRegistry),
                address(networkRegistry),
                address(vaultFactory),
                address(operatorVaultOptInService),
                address(operatorNetworkOptInService),
                address(delegatorFactory),
                delegatorFactory.totalTypes()
            )
        );
        delegatorFactory.whitelist(operatorSpecificDelegatorImpl);

        operatorNetworkSpecificDelegatorType = delegatorFactory.totalTypes();
        address operatorNetworkSpecificDelegatorImpl = address(
            new OperatorNetworkSpecificDelegator(
                address(operatorRegistry),
                address(networkRegistry),
                address(vaultFactory),
                address(operatorVaultOptInService),
                address(operatorNetworkOptInService),
                address(delegatorFactory),
                delegatorFactory.totalTypes()
            )
        );
        delegatorFactory.whitelist(operatorNetworkSpecificDelegatorImpl);

        address slasherImpl = address(
            new Slasher(
                address(vaultFactory),
                address(networkMiddlewareService),
                address(slasherFactory),
                slasherFactory.totalTypes()
            )
        );
        slasherFactory.whitelist(slasherImpl);

        vetoSlasherType = slasherFactory.totalTypes();
        address vetoSlasherImpl = address(
            new VetoSlasher(
                address(vaultFactory),
                address(networkMiddlewareService),
                address(networkRegistry),
                address(slasherFactory),
                slasherFactory.totalTypes()
            )
        );
        slasherFactory.whitelist(vetoSlasherImpl);

        zgtoken = new Token("ZG");
        eth = new Token("ETH");

        vaultConfigurator =
            new VaultConfigurator(address(vaultFactory), address(delegatorFactory), address(slasherFactory));
    }
}
