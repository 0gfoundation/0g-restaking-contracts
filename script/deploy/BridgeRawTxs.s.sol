// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Bridge} from "../../src/bridge/Bridge.sol";
import {BridgeAgency} from "../../src/bridge/BridgeAgency.sol";
import {BridgeERC20} from "../../src/bridge/BridgeERC20.sol";

import {JsonUtils} from "./Utils.s.sol";

/// @title BridgeRawTxs
/// @notice Generates 8 pre-signed legacy (pre-EIP-155, chainId-less) raw txs that deploy the
///         Bridge contract stack from a single ephemeral deployer at nonces 0..7. Broadcasting
///         these on any chain yields byte-identical contract addresses, because CREATE address
///         depends only on `(sender, nonce)` and the signer's address recovers identically when
///         the signature contains no chainId.
///
///         The `BRIDGE_DEPLOYER_KEY` env var is read once, used to sign 8 txs, and is expected
///         to be discarded by the operator afterwards — same security property as Nick-method:
///         once nobody holds the key, attackers cannot squat the (deployer, nonce) slots on a
///         freshly-launched chain.
///
///         Per-environment outputs (run the script twice with different BRIDGE_OWNER):
///           - Mainnet/testnet: BRIDGE_OWNER = 0x2D7F2d2286994477Ba878f321b17A7e40E52cDa4
///                              (mirrors the W0G Agency owner already in production)
///           - chain-test:      BRIDGE_OWNER = 0x20f33CE90A13a4b5E7697E3544c3083B8F8A51D4
///                              (has a known test key in setup-agency.sh, useful for devnet
///                              admin operations)
///
///         The same private key can sign both sets; only the constructor args (owner) differ,
///         so the deployer address and 8 contract addresses are identical across environments
///         even though the raw tx bytes differ.
contract BridgeRawTxs is Script, JsonUtils {
    // Uniform gas envelope for all 8 txs. Picked with ~4x headroom over the largest measured
    // deployment (BridgeImpl ~2.4M gas), so future bytecode growth up to the 24KB runtime cap
    // remains covered without re-signing.
    uint64 private constant GAS_LIMIT = 10_000_000;
    uint256 private constant GAS_PRICE = 100 gwei;

    // EIP-155 left this as the marker for chainId-less legacy signatures.
    uint8 private constant LEGACY_V_BASE = 27;

    struct Plan {
        address deployer;
        address owner;
        address[8] predicted;
        bytes[8] initCodes;
        string[8] labels;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("BRIDGE_DEPLOYER_KEY");
        address owner = vm.envAddress("BRIDGE_OWNER");

        Plan memory p = _buildPlan(deployerKey, owner);
        _logPlan(p);

        bytes[] memory rawTxs = new bytes[](8);
        for (uint64 i = 0; i < 8; i++) {
            rawTxs[i] = _signLegacyCreate(deployerKey, i, p.initCodes[i]);
            console2.log("--- nonce", uint256(i), p.labels[i], "---");
            console2.log("  contract :", p.predicted[i]);
            console2.log("  rawTx    :");
            console2.logBytes(rawTxs[i]);
        }

        _writeArtifacts(p, rawTxs);
    }

    function _buildPlan(uint256 deployerKey, address owner) internal pure returns (Plan memory p) {
        p.deployer = vm.addr(deployerKey);
        p.owner = owner;

        // Address of a CREATE-deployed contract is keccak256(rlp([sender, nonce]))[12:]. Foundry
        // exposes this directly so we can predict every slot up-front, even the ones whose init
        // code embeds a later-nonce address (BridgeProxy at nonce 4 wants AgencyProxy at nonce 7).
        for (uint64 i = 0; i < 8; i++) {
            p.predicted[i] = vm.computeCreateAddress(p.deployer, i);
        }

        p.labels[0] = "BridgeERC20Impl";
        p.labels[1] = "BridgeERC20Beacon";
        p.labels[2] = "BridgeImpl";
        p.labels[3] = "BridgeBeacon";
        p.labels[4] = "BridgeProxy";
        p.labels[5] = "BridgeAgencyImpl";
        p.labels[6] = "BridgeAgencyBeacon";
        p.labels[7] = "BridgeAgencyProxy";

        // nonce 0: BridgeERC20 logic contract
        p.initCodes[0] = type(BridgeERC20).creationCode;

        // nonce 1: UpgradeableBeacon(impl=predicted[0], owner=OWNER)
        p.initCodes[1] = abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(p.predicted[0], owner));

        // nonce 2: Bridge logic contract
        p.initCodes[2] = type(Bridge).creationCode;

        // nonce 3: UpgradeableBeacon(impl=predicted[2], owner=OWNER)
        p.initCodes[3] = abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(p.predicted[2], owner));

        // nonce 4: BeaconProxy(beacon=predicted[3], data=Bridge.initialize(ERC20Beacon, AgencyProxy, admin))
        //          AgencyProxy is predicted[7] — works because CREATE address is sender+nonce only.
        bytes memory bridgeInitCall = abi.encodeCall(Bridge.initialize, (p.predicted[1], p.predicted[7], owner));
        p.initCodes[4] = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(p.predicted[3], bridgeInitCall));

        // nonce 5: BridgeAgency logic contract
        p.initCodes[5] = type(BridgeAgency).creationCode;

        // nonce 6: UpgradeableBeacon(impl=predicted[5], owner=OWNER)
        p.initCodes[6] = abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(p.predicted[5], owner));

        // nonce 7: BeaconProxy(beacon=predicted[6], data=BridgeAgency.initialize(BridgeProxy, ERC20Beacon, owner))
        bytes memory agencyInitCall = abi.encodeCall(BridgeAgency.initialize, (p.predicted[4], p.predicted[1], owner));
        p.initCodes[7] = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(p.predicted[6], agencyInitCall));
    }

    function _logPlan(
        Plan memory p
    ) internal pure {
        console2.log("=== Bridge raw-tx plan ===");
        console2.log("  deployer (fund this):", p.deployer);
        console2.log("  owner / admin       :", p.owner);
        console2.log("  gasLimit per tx     :", GAS_LIMIT);
        console2.log("  gasPrice per tx     :", GAS_PRICE);
        for (uint256 i = 0; i < 8; i++) {
            console2.log("  predicted", i, p.labels[i]);
            console2.log("    ->", p.predicted[i]);
        }
    }

    function _signLegacyCreate(
        uint256 privKey,
        uint64 nonce,
        bytes memory initCode
    ) internal pure returns (bytes memory) {
        // Unsigned legacy tx for sighash: rlp([nonce, gasPrice, gasLimit, to="", value=0, data])
        // No chainId fields — pre-EIP-155 form so the signature carries no chain binding and the
        // signer recovers identically on every chain. Throwaway-key model gives us the same
        // attacker resistance as Nick-method without needing to hand-pick (r, s).
        bytes[] memory unsigned = new bytes[](6);
        unsigned[0] = _rlpUint(nonce);
        unsigned[1] = _rlpUint(GAS_PRICE);
        unsigned[2] = _rlpUint(GAS_LIMIT);
        unsigned[3] = _rlpBytes(""); // to = empty -> CREATE
        unsigned[4] = _rlpUint(0); // value
        unsigned[5] = _rlpBytes(initCode);
        bytes32 sighash = keccak256(_rlpList(unsigned));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, sighash);
        // vm.sign returns v in {27, 28} which is already the legacy pre-EIP-155 encoding.
        require(v == LEGACY_V_BASE || v == LEGACY_V_BASE + 1, "unexpected v from vm.sign");

        bytes[] memory signed = new bytes[](9);
        for (uint256 i = 0; i < 6; i++) {
            signed[i] = unsigned[i];
        }
        // r/s are RLP integers: minimal big-endian with leading zeros stripped. A fixed-width
        // 32-byte encoding is non-canonical whenever the top byte is zero (~1/256 per value),
        // and both geth and reth hard-reject such txs at decode time.
        signed[6] = _rlpUint(v);
        signed[7] = _rlpUint(uint256(r));
        signed[8] = _rlpUint(uint256(s));
        return _rlpList(signed);
    }

    function _writeArtifacts(Plan memory p, bytes[] memory rawTxs) internal {
        string memory profile = vm.envOr("BRIDGE_RAW_PROFILE", string("default"));
        string memory task = string.concat("bridge-raw-", profile);

        string memory contractsKey = "bridgeRawContracts";
        for (uint256 i = 0; i < 8; i++) {
            vm.serializeAddress(contractsKey, p.labels[i], p.predicted[i]);
        }
        string memory contractsJson = vm.serializeAddress(contractsKey, "deployer", p.deployer);

        string memory root = "bridgeRaw";
        vm.serializeAddress(root, "deployer", p.deployer);
        vm.serializeAddress(root, "owner", p.owner);
        vm.serializeUint(root, "gasLimit", uint256(GAS_LIMIT));
        vm.serializeUint(root, "gasPrice", GAS_PRICE);
        vm.serializeString(root, "contracts", contractsJson);

        string[] memory rawTxHex = new string[](8);
        for (uint256 i = 0; i < 8; i++) {
            rawTxHex[i] = vm.toString(rawTxs[i]);
        }
        string memory finalJson = vm.serializeString(root, "rawTxs", rawTxHex);

        // Write under deployments/, chain-id-agnostic (the whole point of the raw-tx scheme is
        // that one artifact serves all chains in a given environment).
        (, string memory path) = loadOrInitJsonWithChainId(task, 0);
        vm.writeJson(finalJson, path);
        console2.log("Wrote raw-tx artifact:", path);
    }

    // ------------------------------------------------------------------
    // Minimal RLP encoder. Scope: encode unsigned/signed legacy txs.
    // ------------------------------------------------------------------

    function _rlpUint(
        uint256 value
    ) internal pure returns (bytes memory) {
        if (value == 0) {
            // RLP-canonical encoding of integer 0 is the empty byte string (0x80), NOT a
            // single zero byte. Foundry's RLP-decoders reject the latter as non-canonical.
            return hex"80";
        }
        uint256 len = 0;
        uint256 tmp = value;
        while (tmp > 0) {
            len++;
            tmp >>= 8;
        }
        bytes memory raw = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            raw[len - 1 - i] = bytes1(uint8(value >> (8 * i)));
        }
        return _rlpBytes(raw);
    }

    function _rlpBytes(
        bytes memory data
    ) internal pure returns (bytes memory) {
        uint256 len = data.length;
        if (len == 1 && uint8(data[0]) < 0x80) {
            // RLP shortcut: a single byte in [0x00, 0x7f] is its own encoding.
            return data;
        }
        if (len < 56) {
            return abi.encodePacked(bytes1(uint8(0x80 + len)), data);
        }
        bytes memory lenBytes = _toBigEndian(len);
        return abi.encodePacked(bytes1(uint8(0xb7 + lenBytes.length)), lenBytes, data);
    }

    function _rlpList(
        bytes[] memory items
    ) internal pure returns (bytes memory) {
        bytes memory body;
        for (uint256 i = 0; i < items.length; i++) {
            body = abi.encodePacked(body, items[i]);
        }
        uint256 len = body.length;
        if (len < 56) {
            return abi.encodePacked(bytes1(uint8(0xc0 + len)), body);
        }
        bytes memory lenBytes = _toBigEndian(len);
        return abi.encodePacked(bytes1(uint8(0xf7 + lenBytes.length)), lenBytes, body);
    }

    function _toBigEndian(
        uint256 value
    ) internal pure returns (bytes memory) {
        if (value == 0) return new bytes(0);
        uint256 len = 0;
        uint256 tmp = value;
        while (tmp > 0) {
            len++;
            tmp >>= 8;
        }
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[len - 1 - i] = bytes1(uint8(value >> (8 * i)));
        }
        return out;
    }
}
