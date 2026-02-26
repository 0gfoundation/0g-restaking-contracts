// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IZeroGravityFactory {
    error InvalidCollateral(); // Error thrown when get unregistered collateral
    error InsufficientCollateral(); // Error thrown when given amount is smaller than minimal deposit at validator creation
    error VaultCreated(); // Error thrown when try to create duplicate vault for the same pubkey
    error InvalidOperator(); // Error thrown when try to find invalid operator
    error OperatorVaultNotFound(); // Error thrown when there is no corresponding vault of an operator
    error InvalidPubKeyLength();
    error InvalidCredentialsLength();
    error InvalidSignatureLength();
    error MissingRewarderCreate2Info();
    error InvalidSatelliteChain();
    error MainChainValidatorNotFound();

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

    event ValidatorCreated(
        bytes pubkey,
        bytes credentials,
        bytes signature,
        address collateral,
        address rewarder,
        address vault,
        address operator
    );

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

    function isSatelliteChain(
        uint256 chainId
    ) external view returns (bool);

    function getSatelliteChainParams(
        uint256 chainId
    ) external view returns (SatelliteChainParams memory params);

    function createValidator(
        bytes memory pubkey,
        bytes memory credentials,
        bytes memory signature,
        address onBehalfOf,
        address collateral,
        uint256 amount
    ) external;

    function createSatelliteValidator(
        bytes memory pubkey,
        uint256 chainId,
        bytes memory signature,
        bytes memory satelliteValidatorInfo
    ) external;

    function getSatelliteValidatorInfo(bytes memory pubkey, uint256 chainId) external view returns (bytes memory);
}
