// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

library Create2Helper {
    function computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash));

        return address(uint160(uint256(hash)));
    }
}
