// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IRewarder} from "./interfaces/IRewarder.sol";

contract Rewarder is IRewarder, Initializable {
    /// @custom:storage-location erc7201:0g.restaking.Rewarder
    struct RewarderStorage {
        address restakingStates;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.restaking.Rewarder")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RewarderStorageLocation =
        0xcaab44e7726ab2cc723db0b51eeedd28b68cd6b479b94dcfdcadc4f8ff1fc900;

    function _getRewarderStorage() internal pure returns (RewarderStorage storage $) {
        assembly {
            $.slot := RewarderStorageLocation
        }
    }

    function initialize(
        address restakingStates
    ) external override initializer {
        RewarderStorage storage $ = _getRewarderStorage();
        $.restakingStates = restakingStates;
    }
}
