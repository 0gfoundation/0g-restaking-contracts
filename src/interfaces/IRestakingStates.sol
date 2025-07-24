// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IRestakingStates {
    error ErrSmallerNewDomain();
    error ErrInvalidDomain();

    event WeightUpdated(uint256 domain, address collateral, uint256 weight);
    event BalanceUpdated(uint256 domain, address rewarder, address account, address collateral, uint256 amount);

    struct Balance {
        uint256 domain;
        address collateral;
        uint256 amount;
    }

    struct Power {
        Balance supply;
        uint256 power;
    }

    function getDomains() external view returns (uint256);
    function getBalances(address rewarder, address account) external view returns (Balance[] memory balances);
    function getPowers(
        address rewarder
    ) external view returns (uint256 totalPower, Power[] memory powers);
}
