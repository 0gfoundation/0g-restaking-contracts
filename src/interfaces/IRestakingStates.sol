// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IRestakingStates
 * @notice Interface for the contract that mirrors Ethereum restaking state on the 0G Chain.
 * @dev Maintains per-rewarder balances, collateral weights, and total supplies synced by an off-chain oracle.
 *      Prevents duplicate submissions using a domain + block height + log index deduplication scheme.
 */
interface IRestakingStates {
    /// @dev Error thrown when attempting to reduce the number of domains
    error ErrSmallerNewDomain();

    /// @dev Error thrown when a domain index is out of range
    error ErrInvalidDomain();

    /// @dev Error thrown when a state update has already been submitted (same height + logIndex)
    error ErrDuplicateSubmission();

    /// @dev Error thrown when a weight update references a block height older than the current one
    error ErrOutdatedWeight();

    /**
     * @dev Emitted when a collateral weight is updated for a domain.
     * @param domain The domain index
     * @param collateral Address of the collateral token
     * @param weight The new weight value (18 decimals)
     * @param height The Ethereum block height at which this weight was set
     */
    event WeightUpdated(uint256 domain, address collateral, uint256 weight, uint256 height);

    /**
     * @dev Emitted when an account's balance changes for a given rewarder/domain/collateral.
     * @param domain The domain index
     * @param rewarder Address of the rewarder contract
     * @param account Address of the account whose balance changed
     * @param collateral Address of the collateral token
     * @param amount The new balance after the update
     */
    event BalanceUpdated(uint256 domain, address rewarder, address account, address collateral, uint256 amount);

    /**
     * @dev Emitted when a state update is submitted (used for deduplication tracking).
     * @param domain The domain index
     * @param height The Ethereum block height of the event
     * @param logIndex The log index of the event within the block
     */
    event Submitted(uint256 domain, uint256 height, uint256 logIndex);

    /**
     * @dev Represents an account's staked balance for a specific domain and collateral.
     * @param domain The domain index
     * @param collateral Address of the collateral token
     * @param amount The staked balance amount
     */
    struct Balance {
        uint256 domain;
        address collateral;
        uint256 amount;
    }

    /**
     * @dev Represents the weighted voting power derived from a collateral supply.
     * @param supply The underlying balance (domain, collateral, amount)
     * @param power The computed voting power (supply.amount * weight / 1e18)
     */
    struct Power {
        Balance supply;
        uint256 power;
    }

    /**
     * @notice Checks whether a state update has already been submitted.
     * @param domain The domain index
     * @param height The Ethereum block height of the event
     * @param logIndex The log index of the event within the block
     * @return found True if this update has already been submitted
     */
    function submitted(uint256 domain, uint256 height, uint256 logIndex) external view returns (bool found);

    /**
     * @notice Returns the number of supported domains.
     * @return The domain count
     */
    function getDomains() external view returns (uint256);

    /**
     * @notice Returns all balances for an account across all domains for a given rewarder.
     * @param rewarder Address of the rewarder contract
     * @param account Address of the account
     * @return balances Array of Balance structs representing the account's stakes
     */
    function getBalances(address rewarder, address account) external view returns (Balance[] memory balances);

    /**
     * @notice Returns the total weighted power for a rewarder across all domains and collaterals.
     * @param rewarder Address of the rewarder contract
     * @return totalPower Sum of all weighted powers
     * @return powers Array of Power structs for each domain/collateral combination
     */
    function getPowers(
        address rewarder
    ) external view returns (uint256 totalPower, Power[] memory powers);
}
