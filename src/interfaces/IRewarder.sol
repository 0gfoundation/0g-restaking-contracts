// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IRewarder
 * @notice Interface for per-validator reward distribution contracts on the 0G Chain.
 * @dev Each validator has a dedicated Rewarder that accumulates block rewards and distributes
 *      them to stakers proportionally based on their weighted stake power across collateral types.
 */
interface IRewarder {
    /**
     * @dev Emitted when an account claims accumulated rewards.
     * @param account Address of the account claiming rewards
     * @param reward Amount of ETH/native token claimed
     */
    event Claimed(address account, uint256 reward);

    /**
     * @notice Initializes the rewarder with a reference to the RestakingStates contract.
     * @param restakingStates Address of the RestakingStates contract that holds balance and power data
     */
    function initialize(
        address restakingStates
    ) external;

    /**
     * @notice Updates reward accounting for an account within a specific domain and collateral.
     * @dev Called by RestakingStates before balance changes to checkpoint pending rewards.
     * @param account Address of the account to update
     * @param domain The domain index for the collateral
     * @param collateral Address of the collateral token
     */
    function update(address account, uint256 domain, address collateral) external;

    /**
     * @notice Updates reward accounting for an account across all domains and collaterals.
     * @param account Address of the account to update
     */
    function update(
        address account
    ) external;

    /**
     * @notice Claims all accumulated rewards for an account and transfers them as native ETH.
     * @param account Address of the account to claim rewards for
     * @return reward Amount of native token transferred to the account
     */
    function claim(
        address account
    ) external returns (uint256 reward);
}
