// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IRewarderFactory {
    error InvalidPubKeyLength();
    error InvalidDomain();
    error EmptyRestakingStates();

    event RewarderCreated(bytes pubkey, address rewarder);
}
