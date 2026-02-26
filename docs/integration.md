# Integration Guide

This guide explains how to interact with the 0G restaking contracts as a validator, staker, or integrator.

## Creating a Validator (Ethereum)

### Prerequisites

- A BLS key pair (48-byte public key, 96-byte signature)
- Withdrawal credentials (32 bytes: `0x01` prefix + 11 zero bytes + 20-byte address)
- Whitelisted collateral tokens (ERC-20) with sufficient balance
- The collateral token approved for transfer to the Factory

### Step 1: Approve collateral

```solidity
IERC20(collateral).approve(address(factory), amount);
```

### Step 2: Create the validator

```solidity
factory.createValidator(
    pubkey,           // 48 bytes - BLS public key
    credentials,      // 32 bytes - withdrawal credentials
    signature,        // 96 bytes - BLS signature over the registration
    onBehalfOf,       // address to receive vault deposit shares
    collateral,       // whitelisted ERC-20 token address
    amount            // amount of collateral to deposit
);
```

This single call:
1. Creates an operator contract (BeaconProxy) if one doesn't exist for this public key
2. Creates a Symbiotic vault with delegator and VetoSlasher
3. Opts the operator into the vault and network
4. Registers the operator and vault in the middleware
5. Deposits collateral into the vault on behalf of `onBehalfOf`
6. Emits a `ValidatorCreated` event that the 0G Chain node reads

### What happens on the 0G Chain

The 0G Chain consensus nodes monitor `ValidatorCreated` events. They verify the BLS signature and, if valid, register the validator in the beacon state. The validator then participates in consensus with an effective balance combining native stake and restaked collateral.

## Staking into a Validator's Vault

After a validator is created, anyone can deposit collateral into their vault to earn rewards.

### Step 1: Find the vault address

The vault address is emitted in the `ValidatorCreated` event. You can also look it up through the Factory storage.

### Step 2: Deposit

```solidity
IERC20(collateral).approve(vault, amount);
IVault(vault).deposit(depositor, amount);
```

The depositor receives vault shares proportional to their deposit.

## Claiming Rewards (0G Chain)

Restaking rewards accumulate in per-validator Rewarder contracts on the 0G Chain.

### Step 1: Determine the rewarder address

The rewarder address is deterministic (Create2), computed from the validator's public key:

```solidity
address rewarder = rewarderFactory.previewRewarder(pubkey);
// or if already deployed:
address rewarder = rewarderFactory.getRewarder(pubkey);
```

### Step 2: Update reward accounting (optional)

Reward accounting is automatically updated on claim, but you can trigger it explicitly:

```solidity
// Update for all domains and collaterals
IRewarder(rewarder).update(account);

// Update for a specific domain and collateral
IRewarder(rewarder).update(account, domain, collateral);
```

### Step 3: Claim rewards

```solidity
uint256 reward = IRewarder(rewarder).claim(account);
```

This transfers all accumulated native ETH rewards to the specified account.

## Registering a Satellite Chain Validator

Satellite chains reuse the main chain's operator and vault infrastructure. No additional deposit is required.

### Prerequisites

- The validator must already be registered on the main chain via `createValidator()`
- The satellite chain must be registered by the admin via `addSatelliteChain()`

### Register

```solidity
factory.createSatelliteValidator(
    pubkey,                   // 48 bytes - same BLS key as main chain
    chainId,                  // satellite chain ID
    signature,                // 96 bytes - BLS signature for satellite registration
    satelliteValidatorInfo    // chain-specific metadata
);
```

This is permissionless — anyone can call it for any main-chain validator. The satellite chain node reads the emitted `SatelliteValidatorCreated` event and verifies the BLS signature off-chain, ignoring invalid registrations.

## Oracle State Sync

The off-chain oracle synchronizes Ethereum restaking state to the 0G Chain by calling functions on `RestakingStates`:

### Deposits

When a user deposits into a Symbiotic vault on Ethereum:

```solidity
restakingStates.deposit(domain, height, logIndex, rewarder, account, collateral, amount);
```

### Withdrawals

When a user withdraws from a Symbiotic vault:

```solidity
restakingStates.withdraw(domain, height, logIndex, rewarder, account, collateral, amount);
```

### Weight Updates

When collateral weights change on the middleware:

```solidity
restakingStates.updateWeight(domain, collateral, weight, height);
```

All state update functions require `UPDATE_ROLE` and are deduplicated by `(domain, height, logIndex)` to prevent replay.

## Effective Balance Calculation

A validator's effective balance combines native stake and restaked collateral:

```
effectiveBalance = nativeStaked + Σ(staked_c * weight_c) for all collaterals c
```

Where:
- `nativeStaked` — the validator's native 0G Chain stake
- `staked_c` — the amount of collateral `c` staked in the Symbiotic vault
- `weight_c` — the weight assigned to collateral `c`, used to convert collateral amounts to effective balance units

Weights are set by the middleware admin via `setCollateralWeight()` and stored with checkpoint history for historical lookups.

## Key Addresses

Deployment addresses are stored in the `deployments/` directory. Key contracts to know:

| Contract | Chain | Purpose |
|----------|-------|---------|
| ZeroGravityFactory | Ethereum | Validator creation, network registration |
| ZeroGravityMiddleware | Ethereum | Operator management, slashing |
| RestakingStates | 0G Chain | State mirror, oracle target |
| RewarderFactory | 0G Chain | Rewarder deployment |

Rewarder addresses are deterministic and can be computed without querying the chain:

```
rewarder = Create2(factory, keccak256(pubkey), initCodeHash)
```
