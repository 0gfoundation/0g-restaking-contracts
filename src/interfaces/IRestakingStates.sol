// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IRestakingStates {
    error ErrSmallerNewDomain();
    error ErrInvalidDomain();
    error ErrDuplicateSubmission();
    error ErrOutdatedWeight();

    event WeightUpdated(uint256 domain, address collateral, uint256 weight, uint256 height);
    event BalanceUpdated(uint256 domain, address rewarder, address account, address collateral, uint256 amount);
    event Submitted(uint256 domain, uint256 height, uint256 logIndex);

    struct Balance {
        uint256 domain;
        address collateral;
        uint256 amount;
    }

    struct Power {
        Balance supply;
        uint256 power;
    }

    function submitted(uint256 domain, uint256 height, uint256 logIndex) external view returns (bool found);
    function getDomains() external view returns (uint256);
    function getBalances(address rewarder, address account) external view returns (Balance[] memory balances);
    function getPowers(
        address rewarder
    ) external view returns (uint256 totalPower, Power[] memory powers);
}
