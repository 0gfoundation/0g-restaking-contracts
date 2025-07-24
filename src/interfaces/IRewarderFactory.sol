// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IRewarderFactory {
    error InvalidPubKeyLength();
    error InvalidDomain();
    error EmptyRestakingStates();
    error RewarderAlreadyDeployed();

    event RewarderCreated(bytes pubkey, address rewarder);

    function rewarderInitCodeHash() external view returns (bytes32);

    function previewRewarder(
        bytes memory pubkey
    ) external view returns (address);

    function getRewarder(
        bytes memory pubkey
    ) external view returns (address);

    function getPubkey(
        address rewarder
    ) external view returns (bytes memory);

    function create(
        bytes memory pubkey
    ) external;
}
