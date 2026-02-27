// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IRewarder} from "./interfaces/IRewarder.sol";
import {IRestakingStates} from "./interfaces/IRestakingStates.sol";

import {TransferHelper} from "./libraries/TransferHelper.sol";

/**
 * @title Rewarder
 * @notice Per-validator reward distribution contract deployed on the 0G Chain.
 * @dev Accumulates block rewards sent as native ETH and distributes them to stakers proportionally
 *      based on their weighted stake power. Uses an accumulative-reward-per-share model:
 *      when new rewards arrive, they are split across collateral pools by their relative power,
 *      then each staker's share is computed from the delta in accRewardPerShare since their last update.
 *      Deployed as a BeaconProxy via RewarderFactory using Create2 for deterministic addresses.
 */
contract Rewarder is IRewarder, ReentrancyGuardUpgradeable {
    /// @custom:storage-location erc7201:0g.restaking.Rewarder
    struct RewarderStorage {
        /// @dev Address of the RestakingStates contract holding balance and power data
        address restakingStates;
        /// @dev Total unclaimed rewards held in this contract
        uint256 totalUnclaimedRewards;
        /// @dev Accumulative reward per share for each domain/collateral (scaled by 1e18)
        mapping(uint256 => mapping(address => uint256)) accRewardPerShare;
        /// @dev Last snapshot of accRewardPerShare for each account/domain/collateral
        mapping(address => mapping(uint256 => mapping(address => uint256))) lastAccRewardPerShare;
        /// @dev Unclaimed reward balance per account
        mapping(address => uint256) unclaimedRewards;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.restaking.Rewarder")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RewarderStorageLocation =
        0xcaab44e7726ab2cc723db0b51eeedd28b68cd6b479b94dcfdcadc4f8ff1fc900;

    function _getRewarderStorage() internal pure returns (RewarderStorage storage $) {
        assembly {
            $.slot := RewarderStorageLocation
        }
    }

    /// @notice Initializes the rewarder with a reference to the RestakingStates contract.
    /// @param restakingStates Address of the RestakingStates contract
    function initialize(
        address restakingStates
    ) external override initializer {
        __ReentrancyGuard_init();

        RewarderStorage storage $ = _getRewarderStorage();
        $.restakingStates = restakingStates;
    }

    /**
     * @dev Distributes pending rewards across all collateral pools proportional to their voting power.
     *      Pending rewards = contract balance - totalUnclaimedRewards.
     *      Each collateral pool's accRewardPerShare is incremented by: reward * 1e18 / supply.
     */
    function _update() internal {
        // distribute pending rewards to all collateral pools based on their power
        RewarderStorage storage $ = _getRewarderStorage();
        uint256 pendingReward = address(this).balance - $.totalUnclaimedRewards;
        if (pendingReward == 0) {
            return;
        }
        (uint256 totalPower, IRestakingStates.Power[] memory powers) =
            IRestakingStates($.restakingStates).getPowers(address(this));
        uint256 distributed = 0;
        if (totalPower > 0) {
            for (uint256 i = 0; i < powers.length; ++i) {
                if (powers[i].power == 0) {
                    continue;
                }
                uint256 reward = pendingReward * powers[i].power / totalPower;
                $.accRewardPerShare[powers[i].supply.domain][powers[i].supply.collateral] +=
                    reward * 1e18 / powers[i].supply.amount;
                distributed += reward;
            }
        }
        $.totalUnclaimedRewards += distributed;
    }

    /**
     * @dev Updates pending reward distribution, then checkpoints an account's unclaimed rewards
     *      across all their domain/collateral balances.
     * @param account Address of the account to update
     */
    function _update(
        address account
    ) internal {
        _update();
        // update unclaimed rewards and last accumulative reward per share for given account
        RewarderStorage storage $ = _getRewarderStorage();
        IRestakingStates.Balance[] memory balances =
            IRestakingStates($.restakingStates).getBalances(address(this), account);
        for (uint256 i = 0; i < balances.length; ++i) {
            if (balances[i].amount > 0) {
                // calculate reward
                uint256 reward = (
                    $.accRewardPerShare[balances[i].domain][balances[i].collateral]
                        - $.lastAccRewardPerShare[account][balances[i].domain][balances[i].collateral]
                ) * balances[i].amount / 1e18;
                $.unclaimedRewards[account] += reward;
            }
            // update storage
            $.lastAccRewardPerShare[account][balances[i].domain][balances[i].collateral] =
                $.accRewardPerShare[balances[i].domain][balances[i].collateral];
        }
    }

    /**
     * @dev Updates an account's rewards and resets their lastAccRewardPerShare for a specific
     *      domain/collateral. Called by RestakingStates before balance changes.
     * @param account Address of the account
     * @param domain The domain index
     * @param collateral Address of the collateral token
     */
    function _updateWithCollateral(address account, uint256 domain, address collateral) internal {
        _update(account);
        RewarderStorage storage $ = _getRewarderStorage();
        $.lastAccRewardPerShare[account][domain][collateral] = $.accRewardPerShare[domain][collateral];
    }

    /// @notice Claims all accumulated rewards for an account and transfers native ETH.
    /// @param account Address of the account to claim for
    /// @return reward Amount of native token transferred
    function claim(
        address account
    ) external override nonReentrant returns (uint256 reward) {
        _update(account);
        // claim reward
        RewarderStorage storage $ = _getRewarderStorage();
        reward = $.unclaimedRewards[account];
        $.unclaimedRewards[account] = 0;
        $.totalUnclaimedRewards -= reward;
        TransferHelper.safeTransferETH(account, reward);
        emit Claimed(account, reward);
    }

    /// @notice Updates reward accounting for an account within a specific domain and collateral.
    /// @param account Address of the account to update
    /// @param domain The domain index
    /// @param collateral Address of the collateral token
    function update(address account, uint256 domain, address collateral) public override nonReentrant {
        _updateWithCollateral(account, domain, collateral);
    }

    /// @notice Updates reward accounting for an account across all domains and collaterals.
    /// @param account Address of the account to update
    function update(
        address account
    ) public override nonReentrant {
        _update(account);
    }

    receive() external payable {}
}
