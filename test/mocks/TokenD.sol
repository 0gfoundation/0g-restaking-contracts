// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock ERC-20 with a caller-chosen `decimals()` (the stock `Token` mock is fixed at 18).
///      Used by integration scenarios that exercise cross-chain bridging between tokens whose
///      decimals differ on the two chains (e.g. a 6-decimals USDT).
contract TokenD is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, uint8 decimals_) ERC20(name_, "") {
        _decimals = decimals_;
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals_);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
