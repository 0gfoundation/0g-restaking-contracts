// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IRewarder} from "./interfaces/IRewarder.sol";
import {IRestakingStates} from "./interfaces/IRestakingStates.sol";

import {TransferHelper} from "./libraries/TransferHelper.sol";

contract Rewarder is IRewarder, ReentrancyGuardUpgradeable {
    /// @custom:storage-location erc7201:0g.restaking.Rewarder
    struct RewarderStorage {
        address restakingStates;
        // all unclaimed rewards
        uint256 totalUnclaimedRewards;
        // domain => collateral => accumulative reward
        mapping(uint256 => mapping(address => uint256)) accRewardPerShare;
        // account => domain => collateral => last updated accumulative reward
        mapping(address => mapping(uint256 => mapping(address => uint256))) lastAccRewardPerShare;
        // account => unclaimed rewards
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

    function initialize(
        address restakingStates
    ) external override initializer {
        __ReentrancyGuard_init();

        RewarderStorage storage $ = _getRewarderStorage();
        $.restakingStates = restakingStates;
    }

    function _update() internal {
        // distribute pending rewards to all collateral pools based on their power
        RewarderStorage storage $ = _getRewarderStorage();
        uint256 pendingReward = address(this).balance - $.totalUnclaimedRewards;
        if (pendingReward == 0) {
            return;
        }
        (uint256 totalPower, IRestakingStates.Power[] memory powers) =
            IRestakingStates($.restakingStates).getPowers(address(this));
        if (totalPower == 0) {
            return;
        }
        for (uint256 i = 0; i < powers.length; ++i) {
            if (powers[i].power == 0) {
                continue;
            }
            uint256 reward = pendingReward * powers[i].power / totalPower;
            $.accRewardPerShare[powers[i].supply.domain][powers[i].supply.collateral] +=
                reward * 1e18 / powers[i].supply.amount;
        }
        $.totalUnclaimedRewards += pendingReward;
    }

    function _update(
        address account
    ) internal {
        _update();
        // update unclaimed rewards and last accumulative reward per share for given account
        RewarderStorage storage $ = _getRewarderStorage();
        IRestakingStates.Balance[] memory balances =
            IRestakingStates($.restakingStates).getBalances(address(this), account);
        for (uint256 i = 0; i < balances.length; ++i) {
            if (balances[i].amount == 0) {
                continue;
            }
            // calculate reward
            uint256 reward = (
                $.accRewardPerShare[balances[i].domain][balances[i].collateral]
                    - $.lastAccRewardPerShare[account][balances[i].domain][balances[i].collateral]
            ) * balances[i].amount / 1e18;
            // update storage
            $.lastAccRewardPerShare[account][balances[i].domain][balances[i].collateral] =
                $.accRewardPerShare[balances[i].domain][balances[i].collateral];
            $.unclaimedRewards[account] += reward;
        }
    }

    function claim(
        address account
    ) external nonReentrant {
        _update(account);
        // claim reward
        RewarderStorage storage $ = _getRewarderStorage();
        uint256 reward = $.unclaimedRewards[account];
        $.unclaimedRewards[account] = 0;
        $.totalUnclaimedRewards -= reward;
        TransferHelper.safeTransferETH(account, reward);
        emit Claimed(account, reward);
    }

    function update(
        address account
    ) public override nonReentrant {
        _update(account);
    }

    receive() external payable {}
}
