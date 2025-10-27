// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";

import {BaseMiddlewareReader} from "middleware-sdk/middleware/BaseMiddlewareReader.sol";

import {IZeroGravityFactory} from "../src/interfaces/IZeroGravityFactory.sol";
import {IZeroGravityMiddleware} from "../src/interfaces/IZeroGravityMiddleware.sol";
import {ZeroGravityFactory} from "../src/ZeroGravityFactory.sol";
import {ZeroGravityMiddleware} from "../src/ZeroGravityMiddleware.sol";
import {ZeroGravityOperator} from "../src/ZeroGravityOperator.sol";
import {RewarderFactory} from "../src/RewarderFactory.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Token} from "../test/mocks/Token.sol";

import {JsonUtils} from "./deploy/Utils.s.sol";

contract TestHelper is Script, JsonUtils {
    function deposit(
        address vault
    ) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        (string memory sjson,) = loadOrInitJson("symbiotic");
        Token eth = Token(vm.parseJsonAddress(sjson, ".ETH"));

        address token = IVault(vault).collateral();
        uint256 amount = 1e18; // zg
        if (token == address(eth)) {
            amount = 1e17;
        }

        vm.startBroadcast(privKey);

        if (IERC20(token).allowance(owner, vault) < amount) {
            IERC20(token).approve(vault, type(uint256).max);
        }
        IVault(vault).deposit(owner, amount);

        vm.stopBroadcast();
    }

    function withdraw(
        address vault
    ) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        uint256 totalStaked = IVault(vault).activeBalanceOf(owner);
        if (totalStaked > 0) {
            vm.startBroadcast(privKey);

            IVault(vault).withdraw(owner, totalStaked);

            vm.stopBroadcast();
        }
    }

    function claim(
        address vault
    ) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        vm.startBroadcast(privKey);

        uint256 epoch = IVault(vault).currentEpoch();

        uint256[] memory epochs = new uint256[](epoch);
        for (uint256 i = 0; i < epoch; ++i) {
            epochs[i] = i;
        }

        IVault(vault).claimBatch(owner, epochs);

        vm.stopBroadcast();
    }

    function status(
        address vault
    ) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        (, string memory path) = loadOrInitJson("tests");

        uint256 totalStaked = IVault(vault).activeBalanceOf(owner);

        vm.writeJson(
            vm.toString(totalStaked),
            path,
            string.concat(".", Strings.toHexString(owner), ".", Strings.toHexString(vault))
        );
    }
}
