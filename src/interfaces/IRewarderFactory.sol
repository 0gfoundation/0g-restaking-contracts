// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IRewarderFactory
 * @notice Interface for the factory that deploys per-validator Rewarder contracts via Create2.
 * @dev Uses BeaconProxy + Create2 for deterministic deployment so rewarder addresses can be
 *      computed off-chain before deployment.
 */
interface IRewarderFactory {
    /// @dev Error thrown when a public key does not have the expected length (48 bytes)
    error InvalidPubKeyLength();

    /// @dev Error thrown when the domain index is invalid
    error InvalidDomain();

    /// @dev Error thrown when the RestakingStates address is not configured
    error EmptyRestakingStates();

    /// @dev Error thrown when a rewarder for the given public key has already been deployed
    error RewarderAlreadyDeployed();

    /**
     * @dev Emitted when a new rewarder contract is deployed for a validator.
     * @param pubkey The validator's BLS public key (48 bytes)
     * @param rewarder Address of the newly deployed rewarder contract
     */
    event RewarderCreated(bytes pubkey, address rewarder);

    /**
     * @notice Returns the init code hash used for Create2 address computation.
     * @return The keccak256 hash of the BeaconProxy init code with constructor arguments
     */
    function rewarderInitCodeHash() external view returns (bytes32);

    /**
     * @notice Computes the deterministic address of a rewarder for the given public key.
     * @dev The rewarder may or may not have been deployed yet.
     * @param pubkey The validator's BLS public key (48 bytes)
     * @return The computed Create2 address of the rewarder
     */
    function previewRewarder(
        bytes memory pubkey
    ) external view returns (address);

    /**
     * @notice Returns the deployed rewarder address for a validator, or zero if not yet deployed.
     * @param pubkey The validator's BLS public key (48 bytes)
     * @return The rewarder address, or address(0) if not deployed
     */
    function getRewarder(
        bytes memory pubkey
    ) external view returns (address);

    /**
     * @notice Returns the public key associated with a deployed rewarder address.
     * @param rewarder Address of the rewarder contract
     * @return The validator's BLS public key (48 bytes)
     */
    function getPubkey(
        address rewarder
    ) external view returns (bytes memory);

    /**
     * @notice Deploys a new rewarder contract for a validator using Create2.
     * @dev Reverts if a rewarder already exists for this public key or if RestakingStates is not set.
     * @param pubkey The validator's BLS public key (48 bytes)
     */
    function create(
        bytes memory pubkey
    ) external;
}
