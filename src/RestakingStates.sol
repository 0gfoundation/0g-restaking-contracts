// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {IRestakingStates} from "./interfaces/IRestakingStates.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";

contract RestakingStates is IRestakingStates, AccessControlUpgradeable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /// @custom:storage-location erc7201:0g.restaking.RestakingStates
    struct RestakingStatesStorage {
        uint256 domains;
        mapping(uint256 => EnumerableMap.AddressToUintMap) weights; // domain => (collateral => weight)
        mapping(uint256 => mapping(address => uint256)) weightUpdatedAt; // domain => (collateral => height)
        // rewarder => domain => account => (collateral => balance)
        mapping(address => mapping(uint256 => mapping(address => EnumerableMap.AddressToUintMap))) balances;
        // rewarder => domain => (collateral => balance)
        mapping(address => mapping(uint256 => EnumerableMap.AddressToUintMap)) totalSupply;
        // domain => keccak256(block height, logIndex) => bool
        mapping(uint256 => mapping(bytes32 => bool)) submitted;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.restaking.RestakingStates")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RestakingStatesStorageLocation =
        0x4343d365237c91901669a344b875c5bb84fe5cbcba50b64e06e6d6fc67e1cc00;

    function _getRestakingStatesStorage() internal pure returns (RestakingStatesStorage storage $) {
        assembly {
            $.slot := RestakingStatesStorageLocation
        }
    }

    bytes32 public constant UPDATE_ROLE = keccak256("UPDATE_ROLE");

    function getDomains() external view override returns (uint256) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        return $.domains;
    }

    function getBalances(
        address rewarder,
        address account
    ) external view override returns (Balance[] memory balances) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        uint256 domains = $.domains;
        // initialize balances
        uint256 n = 0;
        for (uint256 domain = 0; domain < domains; ++domain) {
            n += $.balances[rewarder][domain][account].length();
        }
        balances = new Balance[](n);
        // get balances
        uint256 idx = 0;
        for (uint256 domain = 0; domain < domains; ++domain) {
            uint256 collateralCnt = $.balances[rewarder][domain][account].length();
            for (uint256 i = 0; i < collateralCnt; ++i) {
                (address collateral, uint256 balance) = $.balances[rewarder][domain][account].at(i);
                balances[idx] = Balance({amount: balance, domain: domain, collateral: collateral});
                ++idx;
            }
        }
    }

    function getPowers(
        address rewarder
    ) external view override returns (uint256 totalPower, Power[] memory powers) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        uint256 domains = $.domains;
        // initialize powers
        uint256 n = 0;
        for (uint256 domain = 0; domain < domains; ++domain) {
            n += $.totalSupply[rewarder][domain].length();
        }
        powers = new Power[](n);
        // calculate powers
        uint256 idx = 0;
        for (uint256 domain = 0; domain < domains; ++domain) {
            uint256 collateralCnt = $.totalSupply[rewarder][domain].length();
            for (uint256 i = 0; i < collateralCnt; ++i) {
                (address collateral, uint256 supply) = $.totalSupply[rewarder][domain].at(i);
                (, uint256 weight) = $.weights[domain].tryGet(collateral);
                uint256 power = weight * supply / 1e18;
                // save to array
                powers[idx] =
                    Power({power: power, supply: Balance({amount: supply, domain: domain, collateral: collateral})});
                totalPower += power;
                ++idx;
            }
        }
    }

    function initialize(
        uint256 domains
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPDATE_ROLE, msg.sender);

        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        $.domains = domains;
    }

    function setDomains(
        uint256 domains
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        if (domains < $.domains) {
            revert ErrSmallerNewDomain();
        }
        $.domains = domains;
    }

    function weightUpdatedAt(uint256 domain, address collateral) external view returns (uint256) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        return $.weightUpdatedAt[domain][collateral];
    }

    function updateWeight(
        uint256 domain,
        address collateral,
        uint256 weight,
        uint256 height
    ) external onlyRole(UPDATE_ROLE) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        if (domain >= $.domains) {
            revert ErrInvalidDomain();
        }
        if ($.weightUpdatedAt[domain][collateral] > height) {
            revert ErrOutdatedWeight();
        }
        $.weights[domain].set(collateral, weight);
        $.weightUpdatedAt[domain][collateral] = height;
        emit WeightUpdated(domain, collateral, weight, height);
    }

    modifier checkSubmitted(uint256 domain, uint256 height, uint256 logIndex) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        (bool found, bytes32 hash) = _submitted(domain, height, logIndex);
        if (found) {
            revert ErrDuplicateSubmission();
        }
        $.submitted[domain][hash] = true;
        _;
    }

    function _submitted(uint256 domain, uint256 height, uint256 logIndex) internal view returns (bool, bytes32) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        bytes32 hash = keccak256(abi.encodePacked(height, logIndex));
        return ($.submitted[domain][hash], hash);
    }

    function submitted(uint256 domain, uint256 height, uint256 logIndex) public view override returns (bool found) {
        (found,) = _submitted(domain, height, logIndex);
    }

    function deposit(
        uint256 domain,
        uint256 height,
        uint256 logIndex,
        address rewarder,
        address account,
        address collateral,
        uint256 amount
    ) external onlyRole(UPDATE_ROLE) checkSubmitted(domain, height, logIndex) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        IRewarder(rewarder).update(account, domain, collateral);
        if (domain >= $.domains) {
            revert ErrInvalidDomain();
        }
        // add balance
        (, uint256 balance) = $.balances[rewarder][domain][account].tryGet(collateral);
        balance += amount;
        $.balances[rewarder][domain][account].set(collateral, balance);
        // add total supply
        (, uint256 supply) = $.totalSupply[rewarder][domain].tryGet(collateral);
        supply += amount;
        $.totalSupply[rewarder][domain].set(collateral, supply);
        emit BalanceUpdated(domain, rewarder, account, collateral, balance);
    }

    function withdraw(
        uint256 domain,
        uint256 height,
        uint256 logIndex,
        address rewarder,
        address account,
        address collateral,
        uint256 amount
    ) external onlyRole(UPDATE_ROLE) checkSubmitted(domain, height, logIndex) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        IRewarder(rewarder).update(account, domain, collateral);
        if (domain >= $.domains) {
            revert ErrInvalidDomain();
        }
        // sub balance
        (, uint256 balance) = $.balances[rewarder][domain][account].tryGet(collateral);
        balance -= amount;
        $.balances[rewarder][domain][account].set(collateral, balance);
        // sub total supply
        (, uint256 supply) = $.totalSupply[rewarder][domain].tryGet(collateral);
        supply -= amount;
        $.totalSupply[rewarder][domain].set(collateral, supply);
        emit BalanceUpdated(domain, rewarder, account, collateral, balance);
    }
}
