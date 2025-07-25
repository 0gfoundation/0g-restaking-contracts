// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

contract JsonUtils is Script {
    function loadOrInitJson(
        string memory task
    ) internal returns (string memory json, string memory path) {
        return loadOrInitJsonWithChainId(task, block.chainid);
    }

    function loadOrInitJsonWithChainId(
        string memory task,
        uint256 chainId
    ) internal returns (string memory json, string memory path) {
        path = string.concat(vm.projectRoot(), "/deployments/", string.concat(task, "-", vm.toString(chainId)), ".json");

        try vm.readFile(path) returns (string memory content) {
            json = content;
        } catch {
            json = "{}";
            vm.writeJson(json, path);
        }
    }
}
