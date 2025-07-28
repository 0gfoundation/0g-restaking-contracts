// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {Token} from "../../test/mocks/Token.sol";
import {JsonUtils} from "./Utils.s.sol";

contract MockScript is Script, JsonUtils {
    function run() public {
        uint256 privKey = vm.envUint("PRIVATE_KEY");

        string memory obj = "symbiotic";

        (, string memory path) = loadOrInitJson(obj);

        vm.startBroadcast(privKey);

        Token zgtoken = new Token("ZG");
        vm.writeJson(vm.toString(address(zgtoken)), path, ".ZG");

        Token ethtoken = new Token("ETH");
        vm.writeJson(vm.toString(address(ethtoken)), path, ".ETH");

        vm.stopBroadcast();
    }
}
