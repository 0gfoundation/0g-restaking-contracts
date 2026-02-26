// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {IRestakingStates} from "./interfaces/IRestakingStates.sol";
import {IRewarder} from "./interfaces/IRewarder.sol";

/**
 * @title RestakingStates
 * @notice Mirrors Ethereum restaking state on the 0G Chain, synced by an off-chain oracle.
 * @dev Maintains per-rewarder account balances and collateral weights across multiple domains.
 *      Each state update (deposit, withdraw, weight update) is deduplicated using a hash of
 *      (domain, blockHeight, logIndex) to prevent replay. Only accounts with UPDATE_ROLE can
 *      submit state updates. Before any balance change, the corresponding Rewarder is notified
 *      to checkpoint pending rewards.
 */
contract RestakingStates is IRestakingStates, AccessControlUpgradeable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /// @custom:storage-location erc7201:0g.restaking.RestakingStates
    struct RestakingStatesStorage {
        /// @dev Number of supported domains (e.g., one per source chain)
        uint256 domains;
        /// @dev Collateral weights per domain: domain => (collateral => weight in 18 decimals)
        mapping(uint256 => EnumerableMap.AddressToUintMap) weights;
        /// @dev Block height of the last weight update per domain/collateral
        mapping(uint256 => mapping(address => uint256)) weightUpdatedAt;
        /// @dev Account balances: rewarder => domain => account => (collateral => balance)
        mapping(address => mapping(uint256 => mapping(address => EnumerableMap.AddressToUintMap))) balances;
        /// @dev Total supply per rewarder/domain: rewarder => domain => (collateral => total)
        mapping(address => mapping(uint256 => EnumerableMap.AddressToUintMap)) totalSupply;
        /// @dev Deduplication tracking: domain => keccak256(blockHeight, logIndex) => submitted
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

    /// @dev Role required to submit state updates (deposits, withdrawals, weight changes)
    bytes32 public constant UPDATE_ROLE = keccak256("UPDATE_ROLE");

    /// @notice Returns the number of supported domains.
    /// @return The domain count
    function getDomains() external view override returns (uint256) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        return $.domains;
    }

    /// @notice Returns all balances for an account across all domains for a given rewarder.
    /// @param rewarder Address of the rewarder contract
    /// @param account Address of the account
    /// @return balances Array of Balance structs
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

    /// @notice Returns the total weighted power for a rewarder across all domains and collaterals.
    /// @param rewarder Address of the rewarder contract
    /// @return totalPower Sum of all weighted powers
    /// @return powers Array of Power structs for each domain/collateral
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

    /// @notice Initializes the contract with the given number of domains and grants roles to the deployer.
    /// @param domains Initial number of supported domains
    function initialize(
        uint256 domains
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPDATE_ROLE, msg.sender);

        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        $.domains = domains;
    }

    /// @notice Increases the number of supported domains.
    /// @dev Cannot decrease the number of domains.
    /// @param domains New domain count (must be >= current)
    function setDomains(
        uint256 domains
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        if (domains < $.domains) {
            revert ErrSmallerNewDomain();
        }
        $.domains = domains;
    }

    /// @notice Returns the block height at which a collateral's weight was last updated.
    /// @param domain The domain index
    /// @param collateral Address of the collateral token
    /// @return The Ethereum block height of the last weight update
    function weightUpdatedAt(uint256 domain, address collateral) external view returns (uint256) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        return $.weightUpdatedAt[domain][collateral];
    }

    /// @notice Updates the weight for a collateral in a given domain.
    /// @dev Rejects updates with a block height older than the current stored height.
    /// @param domain The domain index
    /// @param collateral Address of the collateral token
    /// @param weight The new weight value (18 decimals)
    /// @param height The Ethereum block height at which this weight was set
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

    /**
     * @dev Modifier that prevents duplicate submissions of the same state update.
     *      Hashes (height, logIndex) and checks against the submitted mapping.
     * @param domain The domain index
     * @param height The Ethereum block height of the event
     * @param logIndex The log index of the event within the block
     */
    modifier checkSubmitted(uint256 domain, uint256 height, uint256 logIndex) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        (bool found, bytes32 hash) = _submitted(domain, height, logIndex);
        if (found) {
            revert ErrDuplicateSubmission();
        }
        $.submitted[domain][hash] = true;
        emit Submitted(domain, height, logIndex);
        _;
    }

    /// @dev Returns whether a state update has been submitted and the corresponding hash.
    function _submitted(uint256 domain, uint256 height, uint256 logIndex) internal view returns (bool, bytes32) {
        RestakingStatesStorage storage $ = _getRestakingStatesStorage();
        bytes32 hash = keccak256(abi.encodePacked(height, logIndex));
        return ($.submitted[domain][hash], hash);
    }

    /// @notice Checks whether a state update has already been submitted.
    /// @param domain The domain index
    /// @param height The Ethereum block height of the event
    /// @param logIndex The log index of the event within the block
    /// @return found True if this update was already submitted
    function submitted(uint256 domain, uint256 height, uint256 logIndex) public view override returns (bool found) {
        (found,) = _submitted(domain, height, logIndex);
    }

    /**
     * @notice Records a deposit (balance increase) synced from Ethereum.
     * @dev Notifies the rewarder to checkpoint rewards before updating balances.
     * @param domain The domain index
     * @param height Ethereum block height of the deposit event
     * @param logIndex Log index of the deposit event
     * @param rewarder Address of the validator's rewarder contract
     * @param account Address of the depositor
     * @param collateral Address of the collateral token
     * @param amount Amount deposited
     */
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

    /**
     * @notice Records a withdrawal (balance decrease) synced from Ethereum.
     * @dev Notifies the rewarder to checkpoint rewards before updating balances.
     * @param domain The domain index
     * @param height Ethereum block height of the withdrawal event
     * @param logIndex Log index of the withdrawal event
     * @param rewarder Address of the validator's rewarder contract
     * @param account Address of the withdrawer
     * @param collateral Address of the collateral token
     * @param amount Amount withdrawn
     */
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
