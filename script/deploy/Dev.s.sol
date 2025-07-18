// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";

import {BaseMiddlewareReader} from "middleware-sdk/middleware/BaseMiddlewareReader.sol";

import {CoreScript} from "./Core.s.sol";
import {ZeroGravityScript} from "./ZeroGravity.s.sol";

import {IZeroGravityFactory} from "../../src/interfaces/IZeroGravityFactory.sol";
import {IZeroGravityMiddleware} from "../../src/interfaces/IZeroGravityMiddleware.sol";
import {ZeroGravityFactory} from "../../src/ZeroGravityFactory.sol";
import {ZeroGravityMiddleware} from "../../src/ZeroGravityMiddleware.sol";
import {ZeroGravityOperator} from "../../src/ZeroGravityOperator.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Token} from "../../test/mocks/Token.sol";

contract DevScript is CoreScript, ZeroGravityScript {
    function run() public override(CoreScript, ZeroGravityScript) {
        CoreScript.run();
        ZeroGravityScript.run();

        uint256 privKey = vm.envUint("PRIVATE_KEY");

        (string memory json,) = loadOrInitJson("zerogravity");
        (string memory sjson,) = loadOrInitJson("symbiotic");

        vm.startBroadcast(privKey);
        // update collateral config
        ZeroGravityFactory network = ZeroGravityFactory(vm.parseJsonAddress(json, ".ZeroGravityFactory"));
        ZeroGravityMiddleware middleware = ZeroGravityMiddleware(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
        Token zgtoken = Token(vm.parseJsonAddress(sjson, ".ZG"));
        Token eth = Token(vm.parseJsonAddress(sjson, ".ETH"));
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        middleware.setCollateralWeight(address(zgtoken), 1e9);
        network.updateCollateralConfig(address(eth), 1 * 1e18);
        middleware.setCollateralWeight(address(eth), 10 * 1e9);

        vm.stopBroadcast();
    }

    function _registerInfo(
        uint256 index
    ) internal returns (bytes memory pubkey, bytes memory cred, bytes memory sig, address token, uint256 amount) {
        (string memory sjson,) = loadOrInitJson("symbiotic");
        Token zgtoken = Token(vm.parseJsonAddress(sjson, ".ZG"));
        Token eth = Token(vm.parseJsonAddress(sjson, ".ETH"));
        if (index == 0) {
            pubkey =
                hex"a825c1eb32f341160b831534c10b76b381090d182554cc821d25a513ef6b4793269a7d51a694d6e5045cc314219ea76f";
            cred = hex"01000000000000000000000020f33ce90a13a4b5e7697e3544c3083b8f8a51d4";
            sig =
                hex"a05db8993b86aafa2e685253c5de13f76ecf84d2ebd29ac305444b72d17e5a95671d9aaf91a528aab6c5931b8ea0c94505acd5e0a84eb7109618d797a939fc1fa88fdab09c2a77d1ec0ff30f58df90838f8bfd2c9e2917bc1c0436858c0fa617";
            token = address(zgtoken);
            amount = 64 * 1e18;
        } else if (index == 1) {
            pubkey =
                hex"92d5362bcef04e374264e7a7446e20dc37fc13efd36834496a1afc9d04531a83603452fa924b9ed60e0103193848b721";
            cred = hex"01000000000000000000000020f33ce90a13a4b5e7697e3544c3083b8f8a51d5";
            sig =
                hex"b67b5524e59801793b4268e93f492751365d59fb9686959b560ee5bdcede7a9ecd02a990f2301e50190593a33c6b1d3a00f939551d724ce5431ad99eac0d760e38a5346c64a8ec27a056c083e8fe61928843f7d3bf9f81b7b0cef19e9ff7faf8";
            token = address(eth);
            amount = 5 * 1e18;
        }
    }

    function register(
        uint256 index
    ) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        (string memory json,) = loadOrInitJson("zerogravity");
        (string memory sjson,) = loadOrInitJson("symbiotic");
        Token zgtoken = Token(vm.parseJsonAddress(sjson, ".ZG"));
        Token eth = Token(vm.parseJsonAddress(sjson, ".ETH"));

        vm.startBroadcast(privKey);

        ZeroGravityFactory network = ZeroGravityFactory(vm.parseJsonAddress(json, ".ZeroGravityFactory"));
        ZeroGravityMiddleware middleware = ZeroGravityMiddleware(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));

        // approve
        zgtoken.approve(address(network), type(uint256).max);
        eth.approve(address(network), type(uint256).max);
        (bytes memory pubkey, bytes memory cred, bytes memory sig, address token, uint256 amount) = _registerInfo(index);
        network.createValidator(pubkey, cred, sig, owner, token, amount);

        vm.stopBroadcast();

        address operator = middleware.operatorByKey(pubkey);
        console2.log("zg operator: ", operator);

        BaseMiddlewareReader reader = BaseMiddlewareReader(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
        console2.log("zg registered: ", reader.isOperatorRegistered(operator));
    }

    function deposit(
        uint256 index
    ) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        (string memory json,) = loadOrInitJson("zerogravity");

        vm.startBroadcast(privKey);

        ZeroGravityMiddleware middleware = ZeroGravityMiddleware(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));

        (bytes memory pubkey,,, address token, uint256 amount) = _registerInfo(index);
        address operator = middleware.operatorByKey(pubkey);
        BaseMiddlewareReader reader = BaseMiddlewareReader(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
        address[] memory vaults = reader.activeOperatorVaults(operator);
        for (uint256 i = 0; i < vaults.length; ++i) {
            if (IVault(vaults[i]).collateral() == token) {
                IERC20(token).approve(vaults[i], amount);
                IVault(vaults[i]).deposit(owner, amount);
            }
        }

        vm.stopBroadcast();
    }

    function withdraw(
        uint256 index
    ) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        (string memory json,) = loadOrInitJson("zerogravity");

        vm.startBroadcast(privKey);

        ZeroGravityMiddleware middleware = ZeroGravityMiddleware(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));

        (bytes memory pubkey,,, address token, uint256 amount) = _registerInfo(index);
        address operator = middleware.operatorByKey(pubkey);
        console2.log(operator);
        BaseMiddlewareReader reader = BaseMiddlewareReader(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
        address[] memory vaults = reader.activeOperatorVaults(operator);
        console2.log("vaults length: ", vaults.length);
        for (uint256 i = 0; i < vaults.length; ++i) {
            console2.log(vaults[i]);
            if (IVault(vaults[i]).collateral() == token) {
                IVault(vaults[i]).withdraw(owner, amount);
            }
        }

        vm.stopBroadcast();
    }
}
