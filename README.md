# 0G Restaking Contracts

[![Solidity](https://img.shields.io/badge/Solidity-0.8.25-blue)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://book.getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**0g-restaking-contracts** is part of the **restaking module** for the 0G Chain.
It is **built on top of the [Symbiotic](https://symbiotic.fi/) protocol**, enabling validators to restake their assets in Symbiotic and participate in 0G Chain consensus.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Git with submodule support

## Quick Start

```bash
# Clone the repository
git clone --recursive https://github.com/0glabs/0g-restaking-contracts.git
cd 0g-restaking-contracts

# Install dependencies (git submodules)
git submodule update --init --recursive

# Build
forge build

# Run tests
forge test

# Run tests with gas report
forge test --gas-report

# Format code
forge fmt
```

## Overview

The repository consists of two main components deployed on different chains:

### Ethereum-Side Contracts

| Contract | Description |
|----------|-------------|
| **ZeroGravityFactory** | Main entry point. Creates validator infrastructure — operator contracts, vaults, delegators, slashers. Manages collateral whitelisting and satellite chain configs. Also acts as the Symbiotic network. |
| **ZeroGravityMiddleware** | Symbiotic middleware integration. Handles operator key management, collateral weight tracking, and proportional slashing across vaults. |
| **ZeroGravityOperator** | Per-validator operator contract (BeaconProxy). Registers with Symbiotic and opts into vaults and networks. |
| **WeightedStakePower** | Converts stake amounts to voting power using per-collateral weights with checkpoint history. |
| **PauseControl** | Emergency pause functionality with role-based access control. |

### 0G Chain-Side Contracts

| Contract | Description |
|----------|-------------|
| **RestakingStates** | Mirrors Ethereum restaking state (balances, weights) synced by an off-chain oracle. |
| **RewarderFactory** | Creates per-validator rewarder contracts via Create2 for deterministic addresses. |
| **Rewarder** | Per-validator reward distribution. Accumulates block rewards and distributes based on weighted stake power. |

### Supporting Libraries

| Library | Description |
|---------|-------------|
| **Create2Helper** | Computes deterministic Create2 deployment addresses. |
| **TransferHelper** | Safe native ETH transfer utility. |

## Satellite Chains

Multiple 0G Chains with distinct chain IDs can share a single Ethereum-side restaking module:

- **Main Chain**: The primary 0G Chain where validators are first registered via `createValidator()`, creating operator/vault/stake infrastructure.
- **Satellite Chains**: Additional 0G Chains that reuse the main chain's operator, vaults, and stake — no new vault or deposit required.
- **Registration**: `createSatelliteValidator()` is permissionless. The satellite chain node reads the emitted event and verifies the BLS signature off-chain.
- **Configuration**: Per-chain config (`chainType`, `rewarderFactory`, `rewarderInitCodeHash`, `customMetadata`) managed by admin via `addSatelliteChain` / `updateSatelliteChainParams`.

## Restaking Flow

```mermaid
flowchart TD
    subgraph ETH["Ethereum"]
        E1["Validator calls Factory.createValidator()"]
        E2["Factory deploys Operator + Vault<br/>Emits ValidatorCreated"]
        E5["Stakers deposit / withdraw collateral<br/>Vault emits Deposit / Withdraw"]
        E7["Admin updates collateral weights<br/>Middleware emits WeightUpdated"]

        E1 --> E2
    end

    subgraph CL["0G Consensus Layer (Beacon Chain)"]
        C1["Each validator node runs its own ETH node<br/>and reads Symbiotic events directly"]
        C2["Block proposer includes SymbioticRequests<br/>+ SymbioticSyncHeight in new beacon block"]
        C3["All validators verify: read own ETH node,<br/>confirm SymbioticRequests for blocks h₀+1 .. h₁ match"]
        C5["ValidatorCreated → every node verifies BLS sig<br/>→ register validator + set rewarder in beacon state"]
        C6["BalanceChange → update SymbioticBalances<br/>WeightUpdated → update SymbioticWeights"]
        C8["Compute effectiveBalance =<br/>nativeStaked + Σ(staked_c × weight_c)"]
        C9["Reward split proportional to contributions:<br/>Withdrawals#91;0#93; → native staker withdrawal credential<br/>Withdrawals#91;1#93; → validator Rewarder contract"]

        C1 --> C2 --> C3
        C3 --> C5 & C6
        C5 & C6 --> C8 --> C9
    end

    subgraph EL["0G Execution Layer (Contracts)"]
        L1["Oracle syncs events<br/>to RestakingStates contract"]
        L2["RewarderFactory deploys per-validator<br/>Rewarder (Create2 + BeaconProxy)"]
        L3["Restaking rewards arrive at Rewarder<br/>as native balance via Withdrawals#91;1#93;"]
        L4["Rewarder distributes to stakers<br/>based on RestakingStates balances & weights"]
        L5["Stakers call Rewarder.claim()"]

        L1 --> L4
        L2 --> L3 --> L4 --> L5
    end

    E2 --> C1
    E5 --> C1
    E7 --> C1
    E5 --> L1
    E7 --> L1
    C9 --> L3
```

### Validator Creation Flow

```mermaid
sequenceDiagram
    participant User
    participant Factory as ZeroGravityFactory
    participant Op as ZeroGravityOperator<br/>(BeaconProxy)
    participant VC as Symbiotic VaultConfigurator
    participant MW as ZeroGravityMiddleware
    participant Nodes as 0G Validator Nodes<br/>(each runs own ETH node)

    User->>Factory: createValidator(pubkey, credentials, signature, collateral, amount)
    Factory->>Factory: Validate pubkey, credentials, signature lengths
    Factory->>Factory: Check collateral whitelist & minimum deposit
    Factory->>User: Transfer collateral via safeTransferFrom
    Factory->>Factory: Compute deterministic rewarder address (Create2)
    Factory->>Op: Deploy BeaconProxy (if new pubkey)
    Factory->>VC: Create Vault + Delegator + VetoSlasher
    Factory->>Op: optIn(vault, network)
    Factory->>MW: registerOperator(operator, pubkey, vault)
    Factory-->>User: Emit ValidatorCreated event
    Factory->>VC: Deposit collateral on behalf of user

    Note over Nodes: Each node's restaking sync module<br/>reads Ethereum blocks continuously
    Nodes->>Nodes: Read ValidatorCreated event from own ETH node
    Nodes->>Nodes: Verify BLS signature against pubkey
    Nodes->>Nodes: Block proposer includes CreateVault<br/>in SymbioticRequests of new beacon block
    Nodes->>Nodes: All validators independently verify<br/>SymbioticRequests match their own ETH node
    Nodes->>Nodes: Register validator in beacon state<br/>Set rewarder address in RestakingRewarders
```

## Security

### Access Control Roles

| Role | Contract | Permissions |
|------|----------|-------------|
| `DEFAULT_ADMIN_ROLE` | Factory | Set params, register network, add satellite chains |
| `UPDATE_COLLATERAL_ROLE` | Factory | Whitelist collaterals, set minimum deposits |
| `PAUSER_ROLE` | Factory (PauseControl) | Pause/unpause validator creation |
| `SLASHER_ROLE` | Middleware | Execute slashing |
| `REGISTER_OPERATOR_ROLE` | Middleware | Register operators (granted to Factory) |
| `WEIGHT_SET_ROLE` | Middleware | Set collateral weights |
| `UPDATE_ROLE` | RestakingStates | Submit oracle state updates |

### Safety Mechanisms

- **VetoSlasher**: Slash requests have a configurable veto period during which a resolver can veto
- **PauseControl**: Emergency pause for validator creation functions
- **Deduplication**: Oracle state updates are deduplicated by (domain, blockHeight, logIndex)
- **Reentrancy Protection**: Rewarder uses OpenZeppelin's ReentrancyGuard

## Deployment

Scripts are in `script/deploy/`. Required environment variables:

| Variable | Description |
|----------|-------------|
| `PRIVATE_KEY` | Deployer private key |
| `ETH_RPC_URL` | Ethereum RPC endpoint |
| `ETH_RPC_URL_HOLESKY` | Holesky testnet RPC endpoint |
| `ZG_RPC` | 0G Chain RPC endpoint |

```bash
# Deploy core Symbiotic contracts
forge script script/deploy/Core.s.sol --rpc-url "$ETH_RPC" --broadcast --slow

# Deploy ZeroGravity contracts (Factory + Middleware)
forge script script/deploy/ZeroGravity.s.sol --rpc-url "$ETH_RPC" --broadcast --slow

# Deploy Rewarder contracts on 0G Chain
forge script script/deploy/Rewarder.s.sol --rpc-url "$ZG_RPC" --broadcast --slow
```

Deployment artifacts are stored in `deployments/`.

## Architecture

See [docs/architecture.md](docs/architecture.md) for detailed architecture documentation including contract dependency graphs, storage layout, and design patterns.

## Protocol Specification

See [docs/restaking.md](docs/restaking.md) for the consensus-layer protocol specification including ChainSpec fields, BeaconBlock/BeaconState extensions, effective balance formula, reward distribution, and restaking request types.

## Integration Guide

See [docs/integration.md](docs/integration.md) for step-by-step integration instructions including validator creation, staking, reward claiming, and satellite chain registration.

## License

This project is licensed under the MIT License.
