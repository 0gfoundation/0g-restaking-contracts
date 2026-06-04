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
- **Registration flow**: `createSatelliteValidator(pubkey, chainId, signature, info)` is permissionless — any caller can invoke it for an existing main chain validator. The contract computes the deterministic satellite rewarder address and emits `SatelliteValidatorCreated`, followed by `SatelliteBalanceSnapshot` events per vault to provide the initial `activeStake` snapshot. No validator info is stored on-chain; the blockchain node reads the events and performs BLS signature verification off-chain, ignoring invalid registrations.
- **Satellite Chain Sync**: `SatelliteBalanceSnapshot` events provide the initial `activeStake` per vault so the satellite node doesn't need to replay all historical Deposit/Withdraw/OnSlash events.
- **Key storage**: `satelliteChains` (`EnumerableSet.UintSet`), `satelliteChainParams` (mapping).

### Key Flows

1. **Validator Setup**: `Factory.createValidator()` → creates Operator (BeaconProxy) → creates Vault/Delegator/Slasher → Operator opts into vault+network → Middleware registers operator+vault
2. **Reward Distribution**: Oracle syncs Ethereum state → RestakingStates → RewarderFactory creates Rewarder → block rewards accumulated → users claim via `Rewarder.claim()`
3. **Slashing**: `Middleware.slash()` with proof hints → proportional slashing across collaterals → VetoSlasher handles veto period
4. **Symbiotic Vault Stake Semantics**: `activeStake()` = actively slashable collateral (deposits − withdrawals − active slash portion). `totalStake()` = `activeStake()` + pending withdrawals for current and next epoch.
5. **Factory Storage Patterns**: `minValidatorDeposit` (EnumerableMap) is the source of truth for iterating all collaterals (never removed). `createdVaults[operator][collateral]` maps to vault addresses.

### Blockchain Node & Consensus Integration

- Each validator node runs its own Ethereum node and reads Symbiotic events directly via the **restaking sync module**. Non-validator nodes are not required to run an Ethereum node.
- **Block proposer** reads the latest Symbiotic state changes from their ETH node and includes `SymbioticRequests` + `SymbioticSyncHeight` (h₁) in the new beacon block.
- **All validator nodes independently verify**: they read their own ETH node for blocks h₀+1 through h₁ and confirm the `SymbioticRequests` in the proposed block match exactly. The block is only accepted and signed if they match.
- **BLS signature verification** happens on every validator node (not just the proposer) when processing a `CreateVault` (ValidatorCreated) request.
- **Two parallel sync paths**:
  - **Consensus layer**: Symbiotic events → `SymbioticBalances` / `SymbioticWeights` in beacon state → effective balance calculation → reward split between native and restaking
  - **Execution layer**: Oracle → `RestakingStates` contracts → per-staker balance tracking → `Rewarder` distributes rewards proportionally
- **Effective balance**: `effectiveBalance = nativeStaked + Σ(staked_c × weight_c)`
- **Reward split**: Consensus layer creates `Withdrawals[0]` (native staker's withdrawal credential) and `Withdrawals[1]` (validator's Rewarder contract address), proportional to each side's contribution to effective balance.

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

## Documentation Conventions

- Use Mermaid for all diagrams (flowcharts, sequences, dependency graphs)
- Flowcharts: `flowchart TD` (top-down) with subgraphs for grouping
- Sequence diagrams: `sequenceDiagram` with participant aliases
- Node shapes: `["text"]` for standard boxes
- Arrows: `-->` for flow, `-->|label|` for labeled edges
- Subgraph naming: `name["Display Name"]`

## Deployment

Scripts in `script/deploy/`. Key env vars: `PRIVATE_KEY`, `ETH_RPC_URL`, `ETH_RPC_URL_HOLESKY`, `ZG_RPC`. Deployment artifacts stored in `deployments/`.

```bash
forge script script/deploy/Core.s.sol --rpc-url "$ETH_RPC" --broadcast --slow
forge script script/deploy/ZeroGravity.s.sol --rpc-url "$ETH_RPC" --broadcast --slow
forge script script/deploy/Rewarder.s.sol --rpc-url "$ZG_RPC" --broadcast --slow
```

### Bridge: deterministic raw-tx deployment (throwaway-key model)

`script/deploy/BridgeRawTxs.s.sol` generates the deploy: it signs the 8 Bridge-stack deploy
txs from a **single ephemeral deployer** at nonces 0..7 as legacy (pre-EIP-155, chainId-less)
raw txs, so broadcasting the same bytes on any chain yields **byte-identical contract
addresses** (BridgeProxy `0x54EbF70B…0750`, etc.). The `BRIDGE_DEPLOYER_KEY` env var is read
once to sign, then is expected to be discarded by the operator — the throwaway-key model gives
the same attacker-resistance as classic Nick-method without hand-picking an `(r, s)` pair.
Generated artifacts live in `deployments/bridge-raw-{devnet,prod}-0.json` (the only difference
between profiles is the `owner` baked into init code); `integration-tests/scripts/deploy-bridge-raw.sh`
broadcasts them. Live-verified by the prod-deploy-owner integration scenario (all 8 contracts
land at the deterministic addresses with every owner/role slot set to the prod governance EOA).

**Security property (why the deployer key must be discarded):**
> After the raw txs are produced the deployer private key must be destroyed. Otherwise an
> attacker on a freshly-launched chain could pre-fund that sender and broadcast their *own*
> txs from the same `(sender, nonce 0..7)` slots, claiming the deterministic addresses with
> attacker-controlled bytecode. The throwaway-key model relies on the operator actually
> discarding the key; if a mainnet launch wants the stronger "no key ever existed" guarantee,
> switch to strict keyless Nick-method (hand-picked `(r, s)` + `ecrecover`-derived sender) —
> a hardening option, not a correctness gap in the current deploy path.

## Testing Patterns

Test base class `ZeroGravityBase.t.sol` sets up the full Symbiotic infrastructure (registries, factories, services). Tests use mock tokens and create validators/operators through the factory. `RewarderBase.t.sol` provides helpers for rewarder testing on the 0G chain side.

## Reference Documentation

- `docs/restaking.md` — Protocol specification: ChainSpec, BeaconBlock, BeaconState, effective balance formula, reward distribution, restaking request types (CreateVault, BalanceChange, WeightUpdated, CreateSatelliteVault)
- `docs/architecture.md` — Contract dependency graph, storage layout, proxy patterns, access control matrix, reward distribution model, slashing model
- `docs/integration.md` — Step-by-step integration guide for validators, stakers, and satellite chains
