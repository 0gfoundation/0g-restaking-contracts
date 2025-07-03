// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

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

import {IZeroGravityFactory} from "../../src/interfaces/IZeroGravityFactory.sol";
import {IZeroGravityMiddleware} from "../../src/interfaces/IZeroGravityMiddleware.sol";
import {ZeroGravityFactory} from "../../src/ZeroGravityFactory.sol";
import {ZeroGravityMiddleware} from "../../src/ZeroGravityMiddleware.sol";
import {ZeroGravityOperator} from "../../src/ZeroGravityOperator.sol";

import {Token} from "../../test/mocks/Token.sol";
import {JsonUtils} from "./Utils.s.sol";

contract CoreScript is Script, JsonUtils {
    uint48 public constant VAULT_EPOCH_DURATION = 2 weeks;
    uint48 public constant VETO_DURATION = 1 days;
    uint48 public constant RESOLVER_SET_EPOCHS_DELAY = 1 days;
    uint48 public constant SLASHING_WINDOW = 1 weeks;

    function run() public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        string memory obj = "zerogravity";

        (, string memory path) = loadOrInitJson(obj);
        (string memory json,) = loadOrInitJson("symbiotic");

        vm.startBroadcast(privKey);

        // use owner as resolver
        address resolver = owner;

        // operator beacon
        ZeroGravityOperator operatorImpl = new ZeroGravityOperator();
        UpgradeableBeacon operatorBeacon = new UpgradeableBeacon(address(operatorImpl), owner);
        vm.serializeAddress(obj, "OperatorBeacon", address(operatorBeacon));

        // network init params

        IZeroGravityFactory.InitParams memory networkInitParams = IZeroGravityFactory.InitParams({
            vaultConfigurator: vm.parseJsonAddress(json, ".VaultConfigurator"),
            vaultVersion: 1,
            delegatorVersion: uint64(vm.parseJsonUint(json, ".OperatorNetworkSpecificDelegatorType")),
            slasherVersion: uint64(vm.parseJsonUint(json, ".VetoSlasherType")),
            epochDuration: VAULT_EPOCH_DURATION,
            vetoDuration: VETO_DURATION,
            resolverSetEpochsDelay: RESOLVER_SET_EPOCHS_DELAY,
            operatorRegistry: vm.parseJsonAddress(json, ".OperatorRegistry"),
            operatorBeacon: address(operatorBeacon),
            resolver: resolver,
            operatorVaultOptInService: vm.parseJsonAddress(json, ".OperatorVaultOptInService"),
            operatorNetworkOptInService: vm.parseJsonAddress(json, ".OperatorNetworkOptInService")
        });

        // network
        bytes memory params = abi.encode(networkInitParams);
        ZeroGravityFactory factoryImpl = new ZeroGravityFactory();
        vm.serializeAddress(obj, "ZeroGravityFactoryImpl", address(factoryImpl));

        UpgradeableBeacon factoryBeacon = new UpgradeableBeacon(address(factoryImpl), owner);
        vm.serializeAddress(obj, "ZeroGravityFactoryBeacon", address(factoryBeacon));

        BeaconProxy factoryProxy =
            new BeaconProxy(address(factoryBeacon), abi.encodeCall(ZeroGravityFactory.initialize, (params)));
        ZeroGravityFactory network = ZeroGravityFactory(address(factoryProxy));
        vm.serializeAddress(obj, "ZeroGravityFactory", address(factoryProxy));

        // middleware
        BaseMiddlewareReader middlewareReader = new BaseMiddlewareReader();
        vm.serializeAddress(obj, "BaseMiddlewareReader", address(middlewareReader));

        IZeroGravityMiddleware.InitParams memory middlewareInitParams = IZeroGravityMiddleware.InitParams({
            network: address(network),
            slashingWindow: SLASHING_WINDOW,
            vaultRegistry: vm.parseJsonAddress(json, ".VaultFactory"),
            operatorRegistry: vm.parseJsonAddress(json, ".OperatorRegistry"),
            operatorNetOptin: vm.parseJsonAddress(json, ".OperatorNetworkOptInService"),
            reader: address(middlewareReader),
            defaultAdmin: owner
        });
        vm.serializeAddress(obj, "BaseMiddlewareReader", address(middlewareReader));

        params = abi.encode(middlewareInitParams);
        ZeroGravityMiddleware middlewareImpl = new ZeroGravityMiddleware();
        vm.serializeAddress(obj, "ZeroGravityMiddlewareImpl", address(middlewareImpl));

        UpgradeableBeacon middlewareBeacon = new UpgradeableBeacon(address(middlewareImpl), owner);
        vm.serializeAddress(obj, "ZeroGravityMiddlewareBeacon", address(middlewareBeacon));

        BeaconProxy middlewareProxy =
            new BeaconProxy(address(middlewareBeacon), abi.encodeCall(ZeroGravityMiddleware.initialize, (params)));
        string memory finalJson = vm.serializeAddress(obj, "ZeroGravityMiddleware", address(middlewareProxy));

        ZeroGravityMiddleware middleware = ZeroGravityMiddleware(address(middlewareProxy));
        middleware.grantRole(middleware.SLASHER_ROLE(), owner);
        middleware.grantRole(middleware.WEIGHT_SET_ROLE(), owner);

        network.registerNetwork(
            address(middleware),
            vm.parseJsonAddress(json, ".NetworkRegistry"),
            vm.parseJsonAddress(json, ".NetworkMiddlewareService")
        );

        vm.stopBroadcast();
        vm.writeJson(finalJson, path);
    }
}
