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
import {RewarderFactory} from "../../src/RewarderFactory.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Token} from "../../test/mocks/Token.sol";

contract DevScript is CoreScript, ZeroGravityScript {
    function run(
        uint256 zgChainId
    ) public override(ZeroGravityScript) {
        // CoreScript.run();
        ZeroGravityScript.run(zgChainId);

        /*
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
        */
    }

    function _validatorInfo(
        uint256 index
    ) internal pure returns (bytes memory pubkey, bytes memory cred, bytes memory sig) {
        if (index == 0) {
            pubkey =
                hex"872e648c3b12a24a2a85b539dc669e722f2463ef8ed67304551db381e313f78ebf879d9835d57617f64e8d50658fdf1e";
            cred = hex"01000000000000000000000008fc637a7802c1210cc071c2dc65bcad26badbdf";
            sig =
                hex"a4ca626c31f89d88354ba596c8823ba107eafadb8df2a29f552e8f20b86d72b1d56590b60c2a53b210f4384ba6e24b930aac348eb25a31a4c2c56adce91901d39f28ac34985a6b82a6f7ffddcbda246e3e633c30c868f392e826328af069c003";
        } else if (index == 1) {
            pubkey =
                hex"872e648c3b12a24a2a85b539dc669e722f2463ef8ed67304551db381e313f78ebf879d9835d57617f64e8d50658fdf1e";
            cred = hex"01000000000000000000000008fc637a7802c1210cc071c2dc65bcad26badbdf";
            sig =
                hex"b02c97dc4e930f4111dc5349fb9b5741dc21018976945ffb347387e62ed3d8abc1aebebf442678fff3d3567ce7fc8e46018c63c6bc437e85995d284e7ba63e0c0142f4288e757f1c322b575c4078d3804b46cabb2732dd789c134eb226ecc7a2";
        } else if (index == 2) {
            pubkey =
                hex"b0d6091bc5d40ed082900c87a93ff45bda1d5494c028bc1632365b22a373dcf691b7f75642c0dbfeafcda052f259d768";
            cred = hex"010000000000000000000000a96d3f1228115a3945045d5aa18c5b7a9f4d943e";
            sig =
                hex"8f66b6702e2d9a77f0596dd3836d2d77284c970cded7066c61a51ccd2806817f419ad01fb5f7375fab5398473a44b1c401b9f4bd42bd2d76dd02b4d6ca0f30237a3577d4bcc99b9a3a10e0ff1bcc89422e50826e53660126a959c2a1b115a49a";
        } else if (index == 3) {
            pubkey =
                hex"b0d6091bc5d40ed082900c87a93ff45bda1d5494c028bc1632365b22a373dcf691b7f75642c0dbfeafcda052f259d768";
            cred = hex"010000000000000000000000a96d3f1228115a3945045d5aa18c5b7a9f4d943e";
            sig =
                hex"8af0679b1207782ba2e22d30b9cd23296d69ad18c8c8a3424f4c8fc4f37b24721ce238dce9014947e383e3647b0ef04e0c7f6fc801abacafa86ba89562cc5f4115ced99a8eb38bb343e09b80de63eb416fc44c209942509f9aacde1f3f396f52";
        } else if (index == 4) {
            pubkey =
                hex"a8a9672bc571aae5f454bcc8d59a45a844194811b3e44d8cef94ea967653ce7d0b93914a8c2dfef5f15f146ea8923c1e";
            cred = hex"010000000000000000000000cc6e4f0a7fc8754c247a4cc7c189d94e3c844213";
            sig =
                hex"8d860f54728e62ff91a265e5cefc8be443ffe6ac363052f5ac01ceb85640054500ba2967d748cde3e3dd24722141f38d1332fb621b6b479f9962a33630bd846d503499ad3b4f3e0bcc94de8a6b6982a4ee21c2de09c18746dc76afae5d4f29f7";
        } else if (index == 5) {
            pubkey =
                hex"a8a9672bc571aae5f454bcc8d59a45a844194811b3e44d8cef94ea967653ce7d0b93914a8c2dfef5f15f146ea8923c1e";
            cred = hex"010000000000000000000000cc6e4f0a7fc8754c247a4cc7c189d94e3c844213";
            sig =
                hex"8c5aa2560717b5b057f39f39754a45bf6f2779a015fbde349ac4f685d5a8aaa11ea24d0f089c32fa0d255e4e350b441e0a2c25aaa5510143590d6c79ce7e1409ce95e53b91cfd3e68b39490c3601968a786284cb6c6abb22e8435e827d72a276";
        } else if (index == 6) {
            pubkey =
                hex"973191a914e10526cf374397edb4a0f8b5749ae13759fae02c3fde989c09ac7b8d7ac453590935abb09da12e19596598";
            cred = hex"0100000000000000000000008936421339b144259187e7ecbe185771bfc1bbd4";
            sig =
                hex"93d6ba99a1c90866d883f56061be16971186334dce0d785763a1fe92305fd1712e4b73462c0e3a78117eefdfeed88cda0f3fe3afaaa0c606515ae9978830db404224e19f4eec5883b2708aac26abc18a8e9b57a1af8e0f50416f676be2431a17";
        } else if (index == 7) {
            pubkey =
                hex"973191a914e10526cf374397edb4a0f8b5749ae13759fae02c3fde989c09ac7b8d7ac453590935abb09da12e19596598";
            cred = hex"0100000000000000000000008936421339b144259187e7ecbe185771bfc1bbd4";
            sig =
                hex"96f1b9d6c06cbe883887a6994b1e3b722cd1cd53dddf0e63a63c25bdc3112f02a85fb0560876b9e9d88670c74d639db904bf466894ef2ccfa2fcd5f936094a71a518e715a9d9c856d843340a1877d6f6f47b6e70d8bdcac7c561491d184c76bb";
        } else if (index == 8) {
            pubkey =
                hex"872e648c3b12a24a2a85b539dc669e722f2463ef8ed67304551db381e313f78ebf879d9835d57617f64e8d50658fdf1e";
            cred = hex"01000000000000000000000008fc637a7802c1210cc071c2dc65bcad26badbdf";
            sig =
                hex"943c3dce0efaaed0b64e6e4f67d85d7d6d7c2c4401ca39b9a109ee66294e7679431a87eaa63a02ec3ea6a54cd7dcdb430e11dc5e053bbb3d669199260f82559dd9231d41c71374bcd249890d5fff22be54cd8b0a1b84a25bfe2264ab690f47bf";
        }
    }

    function _registerInfo(
        uint256 index
    ) internal returns (bytes memory pubkey, bytes memory cred, bytes memory sig, address token, uint256 amount) {
        (string memory sjson,) = loadOrInitJson("symbiotic");
        Token zgtoken = Token(vm.parseJsonAddress(sjson, ".ZG"));
        Token eth = Token(vm.parseJsonAddress(sjson, ".ETH"));
        Token mellowOFT = Token(vm.parseJsonAddress(sjson, ".MellowOFT"));
        (pubkey, cred, sig) = _validatorInfo(index);
        if (index == 0) {
            token = address(zgtoken);
            amount = 32 * 1e18;
        } else if (index == 1) {
            token = address(eth);
            amount = 32 * 1e17;
        } else if (index == 2) {
            token = address(zgtoken);
            amount = 32 * 1e18;
        } else if (index == 3) {
            token = address(eth);
            amount = 32 * 1e17;
        } else if (index == 4) {
            token = address(zgtoken);
            amount = 32 * 1e18;
        } else if (index == 5) {
            token = address(eth);
            amount = 32 * 1e17;
        } else if (index == 6) {
            token = address(zgtoken);
            amount = 32 * 1e18;
        } else if (index == 7) {
            token = address(eth);
            amount = 32 * 1e17;
        } else if (index == 8) {
            token = address(mellowOFT);
            amount = 0;
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

    function claim(uint256 index, uint256 epoch) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(privKey);

        (string memory json,) = loadOrInitJson("zerogravity");

        vm.startBroadcast(privKey);

        ZeroGravityMiddleware middleware = ZeroGravityMiddleware(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));

        (bytes memory pubkey,,, address token,) = _registerInfo(index);
        address operator = middleware.operatorByKey(pubkey);
        console2.log(operator);
        BaseMiddlewareReader reader = BaseMiddlewareReader(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
        address[] memory vaults = reader.activeOperatorVaults(operator);
        console2.log("vaults length: ", vaults.length);
        for (uint256 i = 0; i < vaults.length; ++i) {
            console2.log(vaults[i]);
            if (IVault(vaults[i]).collateral() == token) {
                IVault(vaults[i]).claim(owner, epoch);
            }
        }

        vm.stopBroadcast();
    }

    function vaults() public {
        (string memory json,) = loadOrInitJson("zerogravity");

        ZeroGravityMiddleware middleware = ZeroGravityMiddleware(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
        for (uint256 index = 0; index < 8; index += 2) {
            (bytes memory pubkey,,,,) = _registerInfo(index);
            console2.logBytes(pubkey);
            address operator = middleware.operatorByKey(pubkey);
            BaseMiddlewareReader reader = BaseMiddlewareReader(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
            address[] memory vaults = reader.activeOperatorVaults(operator);
            console2.log("vaults length: ", vaults.length);
            for (uint256 i = 0; i < vaults.length; ++i) {
                console2.log("collateral: ", IVault(vaults[i]).collateral(), ", vault: ", vaults[i]);
            }
        }
    }

    function checkVault(bytes memory pubkey, address collateral, uint256 staked) public {
        (string memory json,) = loadOrInitJson("zerogravity");

        ZeroGravityMiddleware middleware = ZeroGravityMiddleware(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
        address operator = middleware.operatorByKey(pubkey);
        BaseMiddlewareReader reader = BaseMiddlewareReader(vm.parseJsonAddress(json, ".ZeroGravityMiddleware"));
        address[] memory vaults = reader.activeOperatorVaults(operator);
        for (uint256 i = 0; i < vaults.length; ++i) {
            if (IVault(vaults[i]).collateral() == collateral) {
                uint256 balance = IERC20(collateral).balanceOf(vaults[i]);
                require(
                    balance >= staked,
                    string.concat(
                        "balance < staked amount: balance=", vm.toString(balance), ", staked=", vm.toString(staked)
                    )
                );
                console2.log("0g staked: ", staked, ", vault balance: ", balance);
                return;
            }
        }
        revert("vault not found");
    }

    function createRewarder(
        uint256 index
    ) public {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");

        (string memory json,) = loadOrInitJson("rewarder");

        vm.startBroadcast(privKey);

        RewarderFactory rewarderFactory = RewarderFactory(vm.parseJsonAddress(json, ".RewarderFactory"));
        (bytes memory pubkey,,) = _validatorInfo(index);
        rewarderFactory.create(pubkey);
        console2.log("created rewarder: ", rewarderFactory.getRewarder(pubkey));

        vm.stopBroadcast();
    }
}
