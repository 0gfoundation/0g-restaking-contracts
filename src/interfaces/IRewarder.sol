// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IRewarder {
    event Claimed(address account, uint256 reward);

    function initialize(
        address restakingStates
    ) external;

    function update(address account, uint256 domain, address collateral) external;

    function update(
        address account
    ) external;

    function claim(
        address account
    ) external returns (uint256 reward);
}
