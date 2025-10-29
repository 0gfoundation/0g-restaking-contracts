// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

contract Constants {
    // mainnet
    // uint48 public constant VAULT_EPOCH_DURATION = 1 weeks;
    // uint48 public constant VETO_DURATION = 1 days;
    // testnet
    function VAULT_EPOCH_DURATION() internal view returns (uint48) {
        if (block.chainid == 1) {
            return 1 weeks;
        }
        return 1 hours;
    }

    function VETO_DURATION() internal view returns (uint48) {
        if (block.chainid == 1) {
            return 1 days;
        }
        return 600 seconds;
    }

    function RESOLVER_SET_EPOCHS_DELAY() internal pure returns (uint48) {
        return 3;
    }

    function SLASHING_WINDOW() internal view returns (uint48) {
        return VAULT_EPOCH_DURATION() - VETO_DURATION();
    }
}
