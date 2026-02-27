// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title Create2Helper
 * @notice Utility library for computing deterministic Create2 deployment addresses.
 */
library Create2Helper {
    /**
     * @dev Computes the address of a contract deployed via Create2.
     * @param deployer Address of the contract performing the Create2 deployment
     * @param salt The salt used in the Create2 deployment
     * @param initCodeHash The keccak256 hash of the contract's init code (creation code + constructor args)
     * @return The deterministic address where the contract will be deployed
     */
    function computeCreate2Address(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash));

        return address(uint160(uint256(hash)));
    }
}
