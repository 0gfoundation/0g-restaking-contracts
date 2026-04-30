// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockA0GIBasePrecompile} from "./MockA0GIBasePrecompile.sol";

/**
 * @title MockWrappedA0GI
 * @notice Foundry-test mock of the on-chain W0G ERC-20 (`0x1cd0690ff…`).
 * @dev Like the real W0G contract, mint/burnFrom are publicly callable but funnel into the
 *      precompile at `0x1002` via a regular CALL — so the precompile's `caller == W0G_ADDRESS`
 *      check works correctly. The Bridge and any other minter must first be registered via
 *      `Agency.setMinterCap(minter, cap, init)` on the precompile or mint/burn will revert.
 *      Native-balance crediting (`balance_incr/decr` of W0G_ADDRESS) is omitted from this mock —
 *      the precompile checks tracked here are the gating semantics that matter for tests.
 */
contract MockWrappedA0GI is ERC20 {
    /// @notice The mock precompile address. In production this is fixed at 0x1002.
    address public immutable PRECOMPILE;

    constructor(
        address precompile
    ) ERC20("Wrapped A0GI Mock", "W0G") {
        PRECOMPILE = precompile;
    }

    /// @notice Mints W0G to `to`, gated by the precompile's per-minter cap.
    /// @dev Anyone can call (matches W0G semantics), but the call falls through to the precompile
    ///      with `msg.sender == address(this)` — so the precompile sees the caller as W0G itself.
    ///      The minter's identity (the Bridge, in production) is recorded by the precompile from
    ///      our msg.sender (which is the original caller).
    function mint(address to, uint256 amount) external {
        // tx.origin can't tell the precompile who originally called; instead, we forward the
        // address that called *us* (i.e., msg.sender of this fn) as the minter argument.
        MockA0GIBasePrecompile(PRECOMPILE).mint(msg.sender, amount);
        _mint(to, amount);
    }

    /// @notice Burns W0G from `from`, gated by the precompile's per-minter supply.
    /// @dev No allowance check — the privileged caller (Bridge) is expected to have validated
    ///      intent. Real W0G's `burnFrom` similarly skips allowance because the precompile is
    ///      the gatekeeper. Bridge.burnAndSend uses transferFrom + burn(uint256) instead, but
    ///      we keep burnFrom available for tests that exercise the legacy path.
    function burnFrom(address from, uint256 amount) external {
        MockA0GIBasePrecompile(PRECOMPILE).burn(msg.sender, amount);
        _burn(from, amount);
    }

    /// @notice Self-burn (matches W0G's `burn(uint256)` selector 0x42966c68 and BridgeERC20's
    ///         `burn(uint256)` self-burn). Bridge.burnAndSend uses this after transferFrom.
    /// @dev Burns msg.sender's balance and decrements precompile MinterSupply[msg.sender].
    function burn(
        uint256 amount
    ) external {
        MockA0GIBasePrecompile(PRECOMPILE).burn(msg.sender, amount);
        _burn(msg.sender, amount);
    }
}
