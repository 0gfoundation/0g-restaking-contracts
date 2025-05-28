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

import {DefaultStakerRewardsFactory} from "rewards/src/contracts/defaultStakerRewards/DefaultStakerRewardsFactory.sol";
import {DefaultStakerRewards} from "rewards/src/contracts/defaultStakerRewards/DefaultStakerRewards.sol";

import {BaseMiddlewareReader} from "middleware-sdk/middleware/BaseMiddlewareReader.sol";

import {Token} from "./mocks/Token.sol";

import {IZeroGravityFactory} from "../src/interfaces/IZeroGravityFactory.sol";
import {IZeroGravityMiddleware} from "../src/interfaces/IZeroGravityMiddleware.sol";
import {ZeroGravityFactory} from "../src/ZeroGravityFactory.sol";
import {ZeroGravityMiddleware} from "../src/ZeroGravityMiddleware.sol";
import {ZeroGravityOperator} from "../src/ZeroGravityOperator.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";

contract ZeroGravityBaseTest is Test {
    address owner;
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
    DefaultStakerRewardsFactory defaultStakerRewardsFactory;

    Token collateral;
    VaultConfigurator vaultConfigurator;

    ZeroGravityFactory network;
    ZeroGravityMiddleware middleware;

    address resolver;
    uint256 resolverPrivateKey;

    function setUp() public {
        _deploySymbiotic();

        // resolver
        (resolver, resolverPrivateKey) = makeAddrAndKey("resolver");

        // operator beacon
        ZeroGravityOperator operatorImpl = new ZeroGravityOperator();
        UpgradeableBeacon operatorBeacon = new UpgradeableBeacon(address(operatorImpl), owner);

        // factory
        bytes memory params = abi.encode(
            IZeroGravityFactory.InitParams({
                vaultConfigurator: address(vaultConfigurator),
                vaultVersion: 1,
                delegatorVersion: 4, // operatorNetworkSpecificDelegatorImpl
                slasherVersion: 2, // vetoSlasherImpl
                epochDuration: 2 weeks,
                vetoDuration: 1 days,
                resolverSetEpochsDelay: 1 days,
                operatorRegistry: address(operatorRegistry),
                operatorBeacon: address(operatorBeacon),
                resolver: resolver,
                operatorVaultOptInService: address(operatorVaultOptInService),
                operatorNetworkOptInService: address(operatorNetworkOptInService),
                defaultStakerRewardsFactory: address(defaultStakerRewardsFactory)
            })
        );
        ZeroGravityFactory factoryImpl = new ZeroGravityFactory();
        UpgradeableBeacon factoryBeacon = new UpgradeableBeacon(address(factoryImpl), owner);
        BeaconProxy factoryProxy =
            new BeaconProxy(address(factoryBeacon), abi.encodeCall(ZeroGravityFactory.initialize, (params)));
        network = ZeroGravityFactory(address(factoryProxy));

        // middleware
        VaultRegistry vaultRegistry = new VaultRegistry();
        BaseMiddlewareReader reader = new BaseMiddlewareReader();
        params = abi.encode(
            IZeroGravityMiddleware.InitParams({
                network: address(network),
                slashingWindow: 1 weeks,
                vaultRegistry: address(vaultRegistry),
                operatorRegistry: address(operatorRegistry),
                operatorNetOptin: address(operatorNetworkOptInService),
                reader: address(reader),
                defaultAdmin: owner,
                epochDuration: 1 hours
            })
        );
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

        collateral = new Token("Token");

        vaultConfigurator =
            new VaultConfigurator(address(vaultFactory), address(delegatorFactory), address(slasherFactory));

        address defaultStakerRewards_ =
            address(new DefaultStakerRewards(address(vaultFactory), address(networkMiddlewareService)));

        defaultStakerRewardsFactory = new DefaultStakerRewardsFactory(defaultStakerRewards_);
    }
}
