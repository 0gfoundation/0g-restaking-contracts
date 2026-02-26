# Restaking Protocol Specification

## Abstract

Adds a new mechanism to allow validators to participate in the consensus of the 0G Chain by staking through restaking protocols deployed on other chains. This is a breaking change that requires a hard fork.

The currently supported restaking protocol is [Symbiotic](https://symbiotic.fi/). The corresponding hard fork is named **Rssymbiotic**. The following sections will describe the technical details of supporting Symbiotic-based restaking. More restaking protocols may be supported in the future, but the overall design will remain consistent.

## Specification

After enabling restaking, all validator nodes are required to additionally run nodes of the chains hosting the restaking protocols and enable the 0G Chain's restaking sync module to read the restaking protocol's state changes. Non-validator nodes are not required to do this and may run only the 0G Chain itself.

State changes of the restaking protocol are synchronized into the beacon state through consensus voting, so this does not affect the security assumptions of the 0G Chain.

### ChainSpec

Following fields are added to chain spec:

| Name | Value | Comment |
| --- | --- | --- |
| `DomainTypeSymbiotic` | `1001` | domain for symbiotic signatures |
| `RssymbioticForkTime` | TBD | rssymbiotic hardfork timestamp |
| `SymbioticSyncStartBlock` | TBD | starting Ethereum block number for syncing Symbiotic events |
| `SymbioticFactoryAddress` | TBD | address of 0g-symbiotic factory contract |
| `SymbioticMiddlewareAddress` | TBD | address of 0g-symbiotic middleware contract |

### BeaconBlock

Following fields are added to beacon block:

| Name | Comment |
| --- | --- |
| SymbioticRequests | State changes from Symbiotic include validator creation, validator balance changes, and collateral weight changes |
| SymbioticSyncHeight | The Ethereum block number corresponding to the Symbiotic state currently synced |

During each round of consensus voting, all validators will perform additional verification on the new beacon block containing restaking information. They will use the `SymbioticSyncHeight` value $h_1$ in the new block and compare it with the `SymbioticSyncHeight` value $h_0$ from the previous block to determine that the new block includes Symbiotic state changes from Ethereum blocks $h_0 + 1$ through $h_1$. Then, they will compare the `SymbioticRequests` in the new block with the Symbiotic state changes read from the corresponding Ethereum blocks via their own Ethereum nodes. The new beacon block will only be accepted and signed if they match exactly.

Similarly, when the proposer constructs a new block, they need to read the latest Symbiotic state changes from their own Ethereum node and include them in the new block.

### BeaconState

Following fields are added to beacon state:

| Name | Comment |
| --- | --- |
| SymbioticSyncHeight | The Ethereum block number corresponding to the Symbiotic state currently synced |
| SymbioticBalances | Similar to validator balances, an array to save the restaking balances of all validators |
| SymbioticWeights | The weights of different collaterals, used to calculate the effective balance |
| RestakingRewarders | The address a validator uses to receive the portion of mining rewards attributed to restaking |

These fields will be updated during the processing of a new beacon block, along with the included `SymbioticRequests`.

### Effective Balance

The calculation of effective balance of a validator is changed to:

$$
effectiveBalance = nativeStaked + \sum_{c \in collaterals} staked_c * weight_c
$$

Where $nativeStaked$ is the balance of the validator on the 0G Chain, $collaterals$ is the set of all tokens that can be used as collaterals in the restaking protocol, $staked_c$ is the staked amount of a given token in the restaking protocol, and $weight_c$ is the weight of a given token, used to convert the amount of collateral token into effective balance.

### Reward Distribution

In the current implementation, the first entry in the `Withdrawals` array within the payload sent from the consensus layer to the execution layer is the block reward allocated to the block proposer's withdrawal credential address.

After introducing restaking, the block proposer's reward will be split between the native staker and the restaker according to their respective contributions to the effective balance. For the native staker, the reward will be sent as before—to the proposer's withdrawal credential address as the first entry in the Withdrawals array. For the restaker, the second entry in the Withdrawals array will be set as a special withdrawal sending the restaker's portion of the reward to the block proposer's restaking rewarder address.

For each validator, its restaking rewarder address is fixed and cannot be customized. It will be a contract similar to a liquidity mining contract, deployed via a factory contract on the 0G Chain using `create2`. Therefore, its address is predictable. The deployment uses the beacon proxy pattern so that all validators' rewarder contracts share the same version.

When distributing restaking rewards, the execution layer will specially handle the corresponding withdrawal by directly adding balance to the rewarder contract. Inside the rewarder contract, a cross-chain bridge will synchronize the staking state from the restaking protocol and allocate block rewards according to the staking status.

### Execution Layer

The execution layer runs a parallel sync path to distribute restaking rewards to individual stakers:

1. **Oracle sync**: An off-chain oracle monitors Ethereum restaking events (deposits, withdrawals, weight changes) and submits them to the `RestakingStates` contract on the 0G Chain. This is separate from the consensus-layer sync described above.
2. **Rewarder deployment**: `RewarderFactory` deploys a per-validator `Rewarder` contract using Create2 with BeaconProxy, giving each validator a deterministic and upgradeable rewarder address.
3. **Reward accumulation**: As the consensus layer sends restaking rewards to each validator's Rewarder contract via `Withdrawals[1]`, the Rewarder accumulates these rewards internally using an accumulative reward-per-share model across multiple collateral domains.
4. **Claiming**: Stakers call `Rewarder.claim()` to withdraw their proportional share of accumulated rewards, calculated from their stake balance and the collateral weights tracked in `RestakingStates`.

### Restaking Requests

We support multiple types of restaking requests to represent state changes resulting from different operations in the restaking protocol. They often have corresponding on-chain events.

#### CreateVault

An event in the 0g-symbiotic factory contract that creates a new vault dedicated to a specific validator:

```
ValidatorCreated(bytes pubkey, bytes credentials, bytes signature, address collateral, address rewarder, address vault, address operator)
```

1. `pubkey`: Validator BLS public key.
2. `credentials`: Validator withdrawal credential, used when creating the validator structure in the beacon state and is used for withdrawals in native staking. If the validator is already a registered native staker, this field has no effect here.
3. `signature`: A signature made by the validator's BLS key, signing this validator restaking registration.
4. `collateral`: The collateral token used for restaking.
5. `rewarder`: The address the validator uses to receive the portion of mining rewards attributed to restaking.

When processing a `CreateVault` request, the signature will first be verified. If the verification passes, an attempt will be made to create the corresponding validator in the beacon state. Then, the rewarder address for this validator in the beacon state will be updated.

#### BalanceChange

Events in the Symbiotic vault contract that reflect staked balance changes:

```
Deposit(address indexed depositor, address indexed onBehalfOf, uint256 amount, uint256 shares)
Withdraw(address indexed withdrawer, address indexed claimer, uint256 amount, uint256 burnedShares, uint256 mintedShares)
OnSlash(uint256 amount, uint48 captureTimestamp, uint256 slashedAmount)
```

These balance changes will be applied to `SymbioticBalances` in the beacon state. The set of Symbiotic vaults that validators monitor is kept updated — it monitors the vaults from all the `ValidatorCreated` events that have already occurred.

#### WeightUpdated

An event in the 0g-symbiotic middleware contract that updates the weight of a collateral:

```
WeightUpdated(address collateral, uint256 weight, uint48 timestamp)
```

The weight updates will be applied to `SymbioticWeights` in the beacon state.

#### CreateSatelliteVault

Multiple 0G Chains with distinct chain IDs can share a single Ethereum-side restaking module. When a validator that is already registered on the main chain wants to participate in a satellite chain, the following event is emitted by the factory contract:

```
SatelliteValidatorCreated(uint256 indexed chainId, bytes pubkey, bytes signature, bytes satelliteValidatorInfo, address rewarder)
```

1. `chainId`: The satellite chain's identifier.
2. `pubkey`: The validator's BLS public key (must already be registered on the main chain).
3. `signature`: A BLS signature authorizing the satellite chain registration.
4. `satelliteValidatorInfo`: Chain-specific validator metadata (e.g., withdrawal credentials for the satellite chain).
5. `rewarder`: The deterministic rewarder address on the satellite chain, distinct from the main chain rewarder.

The `createSatelliteValidator()` function is permissionless — any caller can invoke it for an existing main chain validator. No new vault or deposit is required; the satellite chain reuses the main chain's operator, vaults, and stake.

The satellite chain node reads the `SatelliteValidatorCreated` event and performs BLS signature verification off-chain. Invalid registrations (bad signature, unknown pubkey) are simply ignored.

Each satellite chain is configured with `SatelliteChainParams` (`chainType`, `rewarderFactory`, `rewarderInitCodeHash`, `customMetadata`), managed by admin via `addSatelliteChain` / `updateSatelliteChainParams`.

## Related Documentation

- [Architecture](architecture.md) — Contract dependency graph, storage layout, proxy patterns, access control matrix, reward distribution model, slashing model
- [Integration Guide](integration.md) — Step-by-step integration instructions for validators, stakers, and satellite chains
