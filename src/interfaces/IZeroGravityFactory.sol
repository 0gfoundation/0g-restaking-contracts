// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title IZeroGravityFactory
 * @notice Interface for the main entry point that creates validator infrastructure on Ethereum.
 * @dev Creates operator contracts (BeaconProxy), Symbiotic vaults, delegators, and slashers.
 *      Manages collateral whitelisting and satellite chain configurations.
 */
interface IZeroGravityFactory {
    /// @dev Error thrown when the collateral token is not whitelisted
    error InvalidCollateral();

    /// @dev Error thrown when the deposit amount is below the minimum required for validator creation
    error InsufficientCollateral();

    /// @dev Error thrown when attempting to create a duplicate vault for the same operator and collateral
    error VaultCreated();

    /// @dev Error thrown when referencing an unregistered operator
    error InvalidOperator();

    /// @dev Error thrown when no vault exists for the given operator
    error OperatorVaultNotFound();

    /// @dev Error thrown when the public key length is not 48 bytes
    error InvalidPubKeyLength();

    /// @dev Error thrown when the credentials length is not 32 bytes
    error InvalidCredentialsLength();

    /// @dev Error thrown when the signature length is not 96 bytes
    error InvalidSignatureLength();

    /// @dev Error thrown when the rewarder factory or init code hash is not configured
    error MissingRewarderCreate2Info();

    /// @dev Error thrown when the specified chain ID is not a registered satellite chain
    error InvalidSatelliteChain();

    /// @dev Error thrown when the validator has not been registered on the main chain
    error MainChainValidatorNotFound();

    /**
     * @dev Initialization parameters for the factory contract.
     * @param vaultConfigurator Address of the Symbiotic VaultConfigurator
     * @param vaultVersion Version index for vault creation in Symbiotic
     * @param delegatorVersion Version index for delegator creation in Symbiotic
     * @param slasherVersion Version index for slasher creation in Symbiotic
     * @param epochDuration Duration of vault epochs in seconds
     * @param vetoDuration Duration of the veto period for slash requests in seconds
     * @param resolverSetEpochsDelay Delay in epochs before a network can update a resolver
     * @param operatorRegistry Address of the Symbiotic OperatorRegistry
     * @param operatorBeacon Address of the UpgradeableBeacon for operator proxies
     * @param resolver Address of the veto slash resolver
     * @param operatorVaultOptInService Address of the Symbiotic operator-vault opt-in service
     * @param operatorNetworkOptInService Address of the Symbiotic operator-network opt-in service
     * @param rewarderFactory Address of the RewarderFactory on the 0G Chain
     * @param rewarderInitCodeHash Init code hash for rewarder Create2 address computation
     */
    struct InitParams {
        address vaultConfigurator;
        uint64 vaultVersion;
        uint64 delegatorVersion;
        uint64 slasherVersion;
        uint48 epochDuration;
        uint48 vetoDuration;
        uint256 resolverSetEpochsDelay;
        address operatorRegistry;
        address operatorBeacon;
        address resolver;
        address operatorVaultOptInService;
        address operatorNetworkOptInService;
        address rewarderFactory;
        bytes32 rewarderInitCodeHash;
    }

    /**
     * @dev Supported chain types for satellite chains.
     */
    enum ChainType {
        EVM
    }

    /// @dev Params for creating a satellite chain
    /// @param chainType The type of the satellite chain
    /// @param rewarderFactory The address of the rewarder factory contract
    /// @param rewarderInitCodeHash The init code hash of the rewarder contract
    /// @param customMetadata The custom metadata for the satellite chain
    struct SatelliteChainParams {
        ChainType chainType;
        address rewarderFactory;
        bytes32 rewarderInitCodeHash;
        bytes customMetadata;
    }

    /**
     * @dev Emitted when a new validator is created on the main chain.
     * @param pubkey Validator's BLS public key (48 bytes)
     * @param credentials Validator withdrawal credentials (32 bytes)
     * @param signature BLS signature authorizing this registration (96 bytes)
     * @param collateral Address of the collateral token used for restaking
     * @param rewarder Deterministic address of the validator's rewarder on the 0G Chain
     * @param vault Address of the Symbiotic vault created for this validator
     * @param operator Address of the operator contract created for this validator
     */
    event ValidatorCreated(
        bytes pubkey,
        bytes credentials,
        bytes signature,
        address collateral,
        address rewarder,
        address vault,
        address operator
    );

    /**
     * @dev Emitted when a validator is registered on a satellite chain.
     * @param chainId The satellite chain ID
     * @param pubkey Validator's BLS public key (48 bytes)
     * @param signature BLS signature authorizing this satellite registration (96 bytes)
     * @param satelliteValidatorInfo Satellite-chain-specific validator metadata
     * @param rewarder Deterministic address of the validator's rewarder on the satellite chain
     */
    event SatelliteValidatorCreated(
        uint256 indexed chainId, bytes pubkey, bytes signature, bytes satelliteValidatorInfo, address rewarder
    );

    /// @dev Emitted when a satellite chain is added
    /// @param chainId The id of the satellite chain
    event AddSatelliteChain(uint256 chainId);

    /// @dev Emitted when the params of a satellite chain is updated
    /// @param chainId The id of the satellite chain
    /// @param params The new params of the satellite chain
    event UpdateSatelliteChainParams(uint256 chainId, SatelliteChainParams params);

    /**
     * @notice Checks whether a chain ID is a registered satellite chain.
     * @param chainId The chain ID to check
     * @return True if the chain ID is a registered satellite chain
     */
    function isSatelliteChain(
        uint256 chainId
    ) external view returns (bool);

    /**
     * @notice Returns the configuration parameters for a satellite chain.
     * @param chainId The satellite chain ID
     * @return params The satellite chain parameters
     */
    function getSatelliteChainParams(
        uint256 chainId
    ) external view returns (SatelliteChainParams memory params);

    /**
     * @notice Creates a new validator with operator, vault, delegator, and slasher infrastructure.
     * @dev Creates an operator BeaconProxy (if one doesn't exist for this pubkey), a Symbiotic vault,
     *      and handles all opt-ins and registrations. Transfers collateral from the caller.
     *      The 0G Chain node reads the emitted ValidatorCreated event and verifies the BLS signature off-chain.
     * @param pubkey Validator's BLS public key (48 bytes)
     * @param credentials Validator withdrawal credentials (32 bytes: 1 prefix + 11 padding + 20 address)
     * @param signature BLS signature authorizing this registration (96 bytes)
     * @param onBehalfOf Address to deposit collateral on behalf of (receives vault shares)
     * @param collateral Address of the whitelisted collateral token
     * @param amount Amount of collateral to deposit into the vault
     */
    function createValidator(
        bytes memory pubkey,
        bytes memory credentials,
        bytes memory signature,
        address onBehalfOf,
        address collateral,
        uint256 amount
    ) external;

    /**
     * @notice Registers an existing main-chain validator on a satellite chain.
     * @dev Permissionless — any caller can register a main-chain validator on a satellite chain.
     *      No validator info is stored on-chain; the satellite chain node reads the emitted event
     *      and verifies the BLS signature off-chain, ignoring invalid registrations.
     * @param pubkey Validator's BLS public key (48 bytes), must already be registered on the main chain
     * @param chainId The target satellite chain ID (must be registered)
     * @param signature BLS signature authorizing this satellite registration (96 bytes)
     * @param satelliteValidatorInfo Satellite-chain-specific validator metadata
     */
    function createSatelliteValidator(
        bytes memory pubkey,
        uint256 chainId,
        bytes memory signature,
        bytes memory satelliteValidatorInfo
    ) external;
}
