// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";

/// @title BridgeScript
/// @notice Stable Foundry entrypoint that re-exports the 8 pre-signed bridge raw txs to
///         downstream chain-spec tooling. The raw txs themselves are generated offline by
///         `BridgeRawTxs.s.sol` from a single throwaway private key (signed once, key
///         discarded), then broadcast by `integration-tests/scripts/deploy-bridge-raw.sh`
///         (devnet) or equivalent chain-spec genesis tooling (prod). The deterministic
///         addresses are byte-identical across every 0G chain.
///
///         Bridge contract address allocation (single deployer, sequential nonces):
///           nonce 0: BridgeERC20Impl
///           nonce 1: BridgeERC20Beacon  = UpgradeableBeacon(impl, OWNER)
///           nonce 2: BridgeImpl
///           nonce 3: BridgeBeacon       = UpgradeableBeacon(impl, OWNER)
///           nonce 4: BridgeProxy        = BeaconProxy(BridgeBeacon, Bridge.initialize(ERC20Beacon, predicted-AgencyProxy, OWNER))
///           nonce 5: BridgeAgencyImpl
///           nonce 6: BridgeAgencyBeacon = UpgradeableBeacon(impl, OWNER)
///           nonce 7: BridgeAgencyProxy  = BeaconProxy(BridgeAgencyBeacon, BridgeAgency.initialize(BridgeProxy, ERC20Beacon, OWNER))
contract BridgeScript is Script {
    /// @notice Return the 8 pre-signed legacy (pre-EIP-155, chainId-less) raw txs that deploy
    ///         the bridge stack at deterministic addresses. Read from the on-disk artifact so
    ///         chain-spec tooling can request the bytes through a stable Solidity entrypoint.
    /// @dev Artifact path is `<projectRoot>/deployments/bridge-raw-prod-0.json`. The chainId
    ///      segment is fixed to `0` on purpose — the raw txs are chain-agnostic and one
    ///      artifact covers mainnet + every testnet + every satellite chain. Devnet uses a
    ///      different owner address baked into init code, so its artifact lives at
    ///      `bridge-raw-devnet-0.json` and is not exposed through this getter.
    function getRawTxs() external view returns (bytes[] memory) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/bridge-raw-prod-0.json");
        string memory json = vm.readFile(path);
        bytes[] memory rawTxs = vm.parseJsonBytesArray(json, ".rawTxs");
        require(rawTxs.length == 8, "BridgeScript: bridge-raw-prod artifact must contain exactly 8 raw txs");
        return rawTxs;
    }
}
