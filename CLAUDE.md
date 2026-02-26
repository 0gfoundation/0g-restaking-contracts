# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

0G Restaking Contracts — Solidity contracts integrating with the Symbiotic restaking protocol to enable 0G Chain validators to participate in liquid restaking on Ethereum. Two-chain system: Ethereum (validator/vault/middleware) and 0G Chain (rewards/state).

## Build & Test Commands

```bash
# Build
forge build

# Run all tests
forge test

# Run a specific test file
forge test --match-path test/ZeroGravityFactory.t.sol

# Run a specific test function
forge test --match test_CreateValidators

# Run tests with gas report
forge test --gas-report

# Run tests with traces
forge test -vvvv

# Format code
forge fmt

# Check formatting without modifying
forge fmt --check

# Install/update submodules
git submodule update --init --recursive
```

## Architecture

### Ethereum-Side Contracts

- **ZeroGravityFactory** (`src/ZeroGravityFactory.sol`): Main entry point. Creates validator infrastructure — operator contracts (BeaconProxy), vaults, delegators, slashers via Symbiotic. Manages collateral whitelisting and satellite chain configurations.
- **ZeroGravityMiddleware** (`src/ZeroGravityMiddleware.sol`): Symbiotic middleware integration. Inherits from `SharedVaults`, `KeyManagerBytes`, `Operators`, `TimestampCapture`, `OzAccessControl`, `WeightedStakePower`. Handles slashing, operator key management, collateral weight tracking.
- **ZeroGravityOperator** (`src/ZeroGravityOperator.sol`): Operator contract using BeaconProxy pattern. Registers with Symbiotic's OperatorRegistry, opts into vaults and networks.

### 0G Chain-Side Contracts

- **RewarderFactory** (`src/RewarderFactory.sol`): Creates per-validator rewarder contracts via Create2 deterministic deployment with BeaconProxy.
- **Rewarder** (`src/Rewarder.sol`): Per-validator reward distribution. Accumulates block rewards, distributes based on weighted stake power across multiple domains (collateral types). Checkpoint-based reward tracking.
- **RestakingStates** (`src/RestakingStates.sol`): Mirrors Ethereum restaking state. Maintains balances per rewarder/account/collateral, tracks collateral weights, prevents duplicate submissions.

### Supporting

- **WeightedStakePower** (`src/WeightedStakePower.sol`): Converts stake to voting power using collateral-specific weights with checkpoint history.
- **AscendRouter** (`src/ascend/AscendRouter.sol`): Payment splitting router distributing funds to multiple receivers.
- **PauseControl** (`src/security/PauseControl.sol`): Emergency pause functionality.

### Satellite Chains

Multiple 0G Chains with distinct chain IDs can share a single Ethereum-side restaking module:

- **Main Chain**: The primary 0G Chain where validators are first registered via `createValidator()`, creating operator/vault/stake infrastructure.
- **Satellite Chains**: Additional 0G Chains that reuse the main chain's operator, vaults, and stake — no new vault or deposit required.
- **`SatelliteChainParams`**: Per-chain config (`chainType`, `rewarderFactory`, `rewarderInitCodeHash`, `customMetadata`). Managed by admin via `addSatelliteChain` / `updateSatelliteChainParams`.
- **Registration flow**: `createSatelliteValidator(pubkey, chainId, signature, info)` is permissionless — any caller can invoke it for an existing main chain validator. The contract computes the deterministic satellite rewarder address and emits `SatelliteValidatorCreated`. No validator info is stored on-chain; the blockchain node reads the event and performs BLS signature verification off-chain, ignoring invalid registrations.
- **Key storage**: `satelliteChains` (`EnumerableSet.UintSet`), `satelliteChainParams` (mapping).

### Key Flows

1. **Validator Setup**: `Factory.createValidator()` → creates Operator (BeaconProxy) → creates Vault/Delegator/Slasher → Operator opts into vault+network → Middleware registers operator+vault
2. **Reward Distribution**: Oracle syncs Ethereum state → RestakingStates → RewarderFactory creates Rewarder → block rewards accumulated → users claim via `Rewarder.claim()`
3. **Slashing**: `Middleware.slash()` with proof hints → proportional slashing across collaterals → VetoSlasher handles veto period

## Design Patterns

- **BeaconProxy**: Upgradeable operators and rewarders
- **ERC7201 Namespaced Storage**: For upgradeable contract storage layout
- **Role-Based Access Control**: OpenZeppelin AccessControl
- **Create2**: Deterministic rewarder deployment

## Solidity Conventions

- Solidity `0.8.25`, EVM target `cancun`, optimizer 200 runs, `via_ir = true`
- Line length: 120 chars
- `int_types = "long"` (use `uint256` not `uint`)
- Double quotes for strings
- No bracket spacing (`{a: 1}` not `{ a: 1 }`)
- Multiline function headers: params first

## Deployment

Scripts in `script/deploy/`. Key env vars: `PRIVATE_KEY`, `ETH_RPC_URL`, `ETH_RPC_URL_HOLESKY`, `ZG_RPC`. Deployment artifacts stored in `deployments/`.

```bash
forge script script/deploy/Core.s.sol --rpc-url "$ETH_RPC" --broadcast --slow
forge script script/deploy/ZeroGravity.s.sol --rpc-url "$ETH_RPC" --broadcast --slow
forge script script/deploy/Rewarder.s.sol --rpc-url "$ZG_RPC" --broadcast --slow
```

## Testing Patterns

Test base class `ZeroGravityBase.t.sol` sets up the full Symbiotic infrastructure (registries, factories, services). Tests use mock tokens and create validators/operators through the factory. `RewarderBase.t.sol` provides helpers for rewarder testing on the 0G chain side.
