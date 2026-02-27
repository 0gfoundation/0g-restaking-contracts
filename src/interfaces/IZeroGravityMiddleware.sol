// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title IZeroGravityMiddleware
 * @notice Interface for the 0G middleware that integrates with Symbiotic for operator management and slashing.
 * @dev Handles operator registration, key management, collateral weight tracking, and proportional slashing
 *      across multiple vaults and subnetworks.
 */
interface IZeroGravityMiddleware {
    /**
     * @dev Parameters describing an operator's state at a given capture timestamp.
     * @param operator Address of the operator contract
     * @param totalPower The operator's total weighted voting power across all vaults
     * @param vaults Array of active vault addresses for this operator
     * @param subnetworks Array of active subnetwork identifiers
     */
    struct OperatorParams {
        address operator;
        uint256 totalPower;
        address[] vaults;
        uint160[] subnetworks;
    }

    /**
     * @dev Initialization parameters for the middleware contract.
     * @param network The address of the network (should be the ZeroGravityFactory)
     * @param slashingWindow The duration of the slashing window (must be < epoch duration)
     * @param vaultRegistry The address of the Symbiotic vault registry
     * @param operatorRegistry The address of the Symbiotic operator registry
     * @param operatorNetOptin The address of the operator-network opt-in service
     * @param reader The address of the reader contract used for delegatecall
     * @param defaultAdmin The address of the default admin role holder
     */
    struct InitParams {
        address network;
        uint48 slashingWindow;
        address vaultRegistry;
        address operatorRegistry;
        address operatorNetOptin;
        address reader;
        address defaultAdmin;
    }

    /// @dev Error thrown when trying to slash a key that is not active at the capture timestamp
    error InactiveKeySlash();

    /// @dev Error thrown when trying to slash an operator that is not active at the capture timestamp
    error InactiveOperatorSlash();

    /// @dev Error thrown when the key does not correspond to any registered operator
    error NotExistKeySlash();

    /// @dev Error thrown when hint arrays have mismatched lengths
    error InvalidHints();

    /// @dev Error thrown when referencing an invalid or unregistered operator
    error InvalidOperator();

    /**
     * @notice Slashes a validator proportionally across all their vaults and subnetworks.
     * @dev The slash amount is distributed proportionally based on each vault's weighted power
     *      relative to the operator's total power. Hint arrays must match vault/subnetwork lengths.
     *      See https://github.com/symbioticfi/core/blob/main/src/contracts/hints/VetoSlasherHints.sol
     *      and https://github.com/symbioticfi/core/blob/main/src/contracts/hints/DelegatorHints.sol
     * @param captureTimestamp The timestamp at which stake state is captured for slashing
     * @param key The BLS public key identifying the operator to slash
     * @param amount The total voting power amount to slash
     * @param stakeHints Hints for stake lookups, indexed [vault][subnetwork]
     * @param slashHints Hints for the VetoSlasher, indexed per vault
     * @param weightHints Hints for collateral weight lookups, indexed per vault
     */
    function slash(
        uint48 captureTimestamp,
        bytes memory key,
        uint256 amount,
        bytes[][] memory stakeHints,
        bytes[] memory slashHints,
        bytes[] memory weightHints
    ) external;
}
