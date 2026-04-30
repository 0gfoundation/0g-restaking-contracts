// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title MockA0GIBasePrecompile
 * @notice Solidity mock of the W0G stateful precompile at `0x1002` for Foundry tests.
 * @dev Mirrors the wa0gi_base precompile in revm:
 *      - `mint(minter, amount)` callable only when `caller == storedW0GAddress`. Fails if
 *        `supply + amount > cap`. On success, increments `supplies[minter].supply`.
 *      - `burn(minter, amount)` callable only when `caller == storedW0GAddress`. Fails if
 *        `supply < amount`.
 *      - `setMinterCap(minter, cap, initialSupply)` callable only by `WA0GI_AGENCY_ADDRESS`.
 *      - `minterSupply(minter)` view returning `(cap, supply, initialSupply)`.
 *      Native-balance crediting on the W0G_ADDRESS is handled by the test harness via `vm.deal`
 *      since vm cheatcodes aren't accessible from a contract; the mock tracks per-minter caps
 *      and supplies — sufficient for verifying revert semantics and accounting.
 */
contract MockA0GIBasePrecompile {
    struct Supply {
        uint256 cap;
        uint256 supply;
        uint256 initialSupply;
    }

    /// @notice The W0G ERC-20 address — the only address allowed to call mint/burn.
    address public immutable W0G_ADDRESS;
    /// @notice The Agency address — the only address allowed to set caps.
    address public immutable AGENCY_ADDRESS;

    mapping(address => Supply) internal _supplies;

    constructor(address w0g, address agency) {
        W0G_ADDRESS = w0g;
        AGENCY_ADDRESS = agency;
    }

    /// @dev Called by W0G to mint `amount` against `minter`'s cap. msg.sender must be W0G.
    function mint(address minter, uint256 amount) external {
        require(msg.sender == W0G_ADDRESS, "sender is not WA0GI");
        Supply storage s = _supplies[minter];
        s.supply += amount;
        require(s.supply <= s.cap, "insufficient mint cap");
    }

    /// @dev Called by W0G to burn `amount` against `minter`'s supply. msg.sender must be W0G.
    function burn(address minter, uint256 amount) external {
        require(msg.sender == W0G_ADDRESS, "sender is not WA0GI");
        Supply storage s = _supplies[minter];
        require(s.supply >= amount, "insufficient mint supply");
        s.supply -= amount;
    }

    /// @dev Called by the Agency to set a minter's cap. Mirrors precompile's initialSupply diff
    ///      adjustment on cap rebases.
    function setMinterCap(address minter, uint256 cap, uint256 initialSupply) external {
        require(msg.sender == AGENCY_ADDRESS, "sender is not agency");
        Supply storage s = _supplies[minter];
        if (s.initialSupply > initialSupply) {
            s.supply -= (s.initialSupply - initialSupply);
        } else if (s.initialSupply < initialSupply) {
            s.supply += (initialSupply - s.initialSupply);
        }
        s.cap = cap;
        s.initialSupply = initialSupply;
    }

    /// @notice Returns a minter's supply state.
    function minterSupply(
        address minter
    ) external view returns (uint256 cap, uint256 supply, uint256 initialSupply) {
        Supply memory s = _supplies[minter];
        return (s.cap, s.supply, s.initialSupply);
    }
}
