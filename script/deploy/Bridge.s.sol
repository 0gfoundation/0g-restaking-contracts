// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Bridge} from "../../src/bridge/Bridge.sol";
import {BridgeAgency} from "../../src/bridge/BridgeAgency.sol";
import {BridgeERC20} from "../../src/bridge/BridgeERC20.sol";

import {JsonUtils} from "./Utils.s.sol";

/**
 * @title BridgeScript
 * @notice Deploys the eight bridge contract artifacts using three deterministic deployer keys
 *         under the fixed-address deployment plan.
 *
 *         The plan mandates three ephemeral senders (`BRIDGE_DEPLOYER_A/B/C`) signing legacy
 *         (pre-EIP-155) raw txs with hard-coded `r,s` (Nick-method) so the resulting addresses are
 *         deterministic across all 0G chains. This implementation:
 *           - Uses three test private keys (devnet only) instead of full Nick-method signing.
 *             Stream A finalizes the production senders before mainnet/testnet launch.
 *           - Predicts every contract address up-front using `vm.computeCreateAddress` so that
 *             the constructor of one beacon proxy can refer to a not-yet-deployed peer (Bridge ↔
 *             Agency cycle).
 *           - Records all eight addresses to `deployments/bridge-<chainId>.json`.
 *
 *         Comment-format below mirrors the W0G Agency / DA registry style used by
 *         the wrapped A0GI base precompile in the EL:
 *           Sender A nonce 0: BridgeImpl
 *           Sender A nonce 1: BridgeBeacon = UpgradeableBeacon(BridgeImpl, governanceOwner)
 *           Sender A nonce 2: BridgeProxy  = BeaconProxy(BridgeBeacon, init(ERC20Beacon, AgencyProxy, multisigAdmin))
 *           Sender B nonce 0: BridgeAgencyImpl
 *           Sender B nonce 1: BridgeAgencyBeacon = UpgradeableBeacon(AgencyImpl, governanceOwner)
 *           Sender B nonce 2: BridgeAgencyProxy  = BeaconProxy(AgencyBeacon, init(BridgeProxy, ERC20Beacon, multisig))
 *           Sender C nonce 0: BridgeERC20Impl
 *           Sender C nonce 1: BridgeERC20Beacon = UpgradeableBeacon(BridgeERC20Impl, governanceOwner)
 *
 *         TODO: replace devnet keys with full Nick-method `(r,s)`-fixed signatures and emit raw tx
 *         hex from `getRawTxs()` to be consumed by the chain-spec tooling.
 */
contract BridgeScript is Script, JsonUtils {
    /// @dev Devnet-only test private keys. Each maps to a fresh address with no live state.
    ///      Replaced before testnet/mainnet deployment with deterministic Nick-method senders.
    uint256 private constant DEPLOYER_A_KEY = 0xa11ce0000000000000000000000000000000000000000000000000000000aaaa;
    uint256 private constant DEPLOYER_B_KEY = 0xb0b00000000000000000000000000000000000000000000000000000000000bb;
    uint256 private constant DEPLOYER_C_KEY = 0xc0c00000000000000000000000000000000000000000000000000000000000cc;

    function run() public {
        // Hard guard: the three DEPLOYER_*_KEY constants below are well-known test keys. Running
        // this script against a production chain would either (a) fail because the squatted nonces
        // give address mismatches, or — worse — (b) succeed and produce contracts at addresses an
        // attacker also controls because they hold the matching key. Use Nick-method
        // (`getRawTxs()`) for prod chains; see CLAUDE.md §"Bridge: Nick-method raw tx requirement".
        require(
            block.chainid != 1 && block.chainid != 17_000 && block.chainid != 11_155_111,
            "Bridge.s.sol: prod chains must use Nick-method via getRawTxs(), not test keys"
        );

        address deployerA = vm.addr(DEPLOYER_A_KEY);
        address deployerB = vm.addr(DEPLOYER_B_KEY);
        address deployerC = vm.addr(DEPLOYER_C_KEY);

        // Beacon owner — same governance multisig / timelock for every beacon. Read from env so
        // mainnet/testnet/devnet can supply distinct values without code changes.
        address governanceOwner = vm.envOr("BEACON_OWNER", deployerA);
        // Initial Agency owner (typically a multisig). Falls back to deployerB for tests.
        address agencyOwner = vm.envOr("AGENCY_OWNER", deployerB);
        // Bridge governance admin (DEFAULT_ADMIN_ROLE on Bridge). Typically the same multisig as
        // `agencyOwner`; surfaced as a separate env var so the two roles can diverge in prod if
        // ever needed (e.g., a stricter timelock for role rotation than for token configuration).
        address bridgeAdmin = vm.envOr("BRIDGE_ADMIN", agencyOwner);

        // Predict addresses. legacy CREATE: addr(sender, nonce).
        address predBridgeImpl = vm.computeCreateAddress(deployerA, 0);
        address predBridgeBeacon = vm.computeCreateAddress(deployerA, 1);
        address predBridgeProxy = vm.computeCreateAddress(deployerA, 2);

        address predAgencyImpl = vm.computeCreateAddress(deployerB, 0);
        address predAgencyBeacon = vm.computeCreateAddress(deployerB, 1);
        address predAgencyProxy = vm.computeCreateAddress(deployerB, 2);

        address predERC20Impl = vm.computeCreateAddress(deployerC, 0);
        address predERC20Beacon = vm.computeCreateAddress(deployerC, 1);

        console2.log("Predicted addresses:");
        console2.log("  BridgeImpl     ", predBridgeImpl);
        console2.log("  BridgeBeacon   ", predBridgeBeacon);
        console2.log("  BridgeProxy    ", predBridgeProxy);
        console2.log("  AgencyImpl     ", predAgencyImpl);
        console2.log("  AgencyBeacon   ", predAgencyBeacon);
        console2.log("  AgencyProxy    ", predAgencyProxy);
        console2.log("  ERC20Impl      ", predERC20Impl);
        console2.log("  ERC20Beacon    ", predERC20Beacon);

        // Sender C: 2 txs (impl + beacon).
        vm.startBroadcast(DEPLOYER_C_KEY);
        BridgeERC20 erc20Impl = new BridgeERC20();
        UpgradeableBeacon erc20Beacon = new UpgradeableBeacon(address(erc20Impl), governanceOwner);
        vm.stopBroadcast();
        require(address(erc20Impl) == predERC20Impl, "C0 mismatch");
        require(address(erc20Beacon) == predERC20Beacon, "C1 mismatch");

        // Sender A: 3 txs (impl + beacon + proxy initialized with ERC20Beacon + predicted Agency).
        vm.startBroadcast(DEPLOYER_A_KEY);
        Bridge bridgeImpl = new Bridge();
        UpgradeableBeacon bridgeBeacon = new UpgradeableBeacon(address(bridgeImpl), governanceOwner);
        bytes memory bridgeInit =
            abi.encodeCall(Bridge.initialize, (address(erc20Beacon), predAgencyProxy, bridgeAdmin));
        BeaconProxy bridgeProxy = new BeaconProxy(address(bridgeBeacon), bridgeInit);
        vm.stopBroadcast();
        require(address(bridgeImpl) == predBridgeImpl, "A0 mismatch");
        require(address(bridgeBeacon) == predBridgeBeacon, "A1 mismatch");
        require(address(bridgeProxy) == predBridgeProxy, "A2 mismatch");

        // Sender B: 3 txs (impl + beacon + proxy initialized with bridge + erc20 beacon).
        vm.startBroadcast(DEPLOYER_B_KEY);
        BridgeAgency agencyImpl = new BridgeAgency();
        UpgradeableBeacon agencyBeacon = new UpgradeableBeacon(address(agencyImpl), governanceOwner);
        bytes memory agencyInit =
            abi.encodeCall(BridgeAgency.initialize, (address(bridgeProxy), address(erc20Beacon), agencyOwner));
        BeaconProxy agencyProxy = new BeaconProxy(address(agencyBeacon), agencyInit);
        vm.stopBroadcast();
        require(address(agencyImpl) == predAgencyImpl, "B0 mismatch");
        require(address(agencyBeacon) == predAgencyBeacon, "B1 mismatch");
        require(address(agencyProxy) == predAgencyProxy, "B2 mismatch");

        _writeJson(
            uint64(block.chainid),
            deployerA,
            deployerB,
            deployerC,
            address(bridgeImpl),
            address(bridgeBeacon),
            address(bridgeProxy),
            address(agencyImpl),
            address(agencyBeacon),
            address(agencyProxy),
            address(erc20Impl),
            address(erc20Beacon)
        );
    }

    function _writeJson(
        uint64 chainId,
        address deployerA,
        address deployerB,
        address deployerC,
        address bridgeImpl,
        address bridgeBeacon,
        address bridgeProxy,
        address agencyImpl,
        address agencyBeacon,
        address agencyProxy,
        address erc20Impl,
        address erc20Beacon
    ) internal {
        string memory obj = "bridge";
        vm.serializeAddress(obj, "deployerA", deployerA);
        vm.serializeAddress(obj, "deployerB", deployerB);
        vm.serializeAddress(obj, "deployerC", deployerC);
        vm.serializeAddress(obj, "bridgeImpl", bridgeImpl);
        vm.serializeAddress(obj, "bridgeBeacon", bridgeBeacon);
        vm.serializeAddress(obj, "bridgeProxy", bridgeProxy);
        vm.serializeAddress(obj, "agencyImpl", agencyImpl);
        vm.serializeAddress(obj, "agencyBeacon", agencyBeacon);
        vm.serializeAddress(obj, "agencyProxy", agencyProxy);
        vm.serializeAddress(obj, "bridgeERC20Impl", erc20Impl);
        string memory finalJson = vm.serializeAddress(obj, "bridgeERC20Beacon", erc20Beacon);

        (, string memory path) = loadOrInitJsonWithChainId("bridge", uint256(chainId));
        vm.writeJson(finalJson, path);
        console2.log("Bridge deployment JSON written to", path);
    }

    /// @notice Stub for future Nick-method raw-tx export.
    /// @dev Stream A will replace this with code that emits the eight signed legacy txs as hex
    ///      strings, ready for chain-spec genesis tooling to broadcast. See Bridge.s.sol header
    ///      and CLAUDE.md §"Bridge: Nick-method raw tx requirement" for the full design.
    function getRawTxs() external pure returns (bytes[] memory) {
        revert("BridgeScript: Nick-method TODO -- see Bridge.s.sol header and CLAUDE.md");
    }
}
