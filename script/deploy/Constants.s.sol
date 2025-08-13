// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

contract Constants {
    uint48 public constant VAULT_EPOCH_DURATION = 1 weeks;
    uint48 public constant VETO_DURATION = 1 days;
    uint48 public constant RESOLVER_SET_EPOCHS_DELAY = 3;
    uint48 public constant SLASHING_WINDOW = VAULT_EPOCH_DURATION - VETO_DURATION;
}
