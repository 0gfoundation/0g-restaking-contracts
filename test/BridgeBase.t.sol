// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeAgency} from "../src/bridge/BridgeAgency.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {Token} from "./mocks/Token.sol";

/**
 * @title BridgeBaseTest
 * @notice Common setUp for bridge tests: deploys Bridge / BridgeAgency / BridgeERC20 (impl + beacon
 *         + proxy where applicable) and wires ADMIN_ROLE → Agency.
 * @dev Mirrors the production deployment topology so test scenarios exercise the same trust path
 *      as launch-day. W0G-specific infrastructure (mock precompile + mock W0G token) is set up
 *      separately by W0gIntegrationTest to keep this base lean.
 */
contract BridgeBaseTest is Test {
    address internal owner;
    address internal alice;
    address internal bob;

    Bridge internal bridge;
    BridgeAgency internal agency;

    UpgradeableBeacon internal bridgeBeacon;
    UpgradeableBeacon internal agencyBeacon;
    UpgradeableBeacon internal bridgeERC20Beacon;

    /// @dev This chain's chainID under test. Set via `vm.chainId(...)` in setUp so that
    ///      `Bridge.localChainID()` (which now reads `block.chainid` directly) returns this value.
    uint64 internal constant LOCAL_CID = 1;
    /// @dev Default destination chainID used in user-path tests.
    uint64 internal constant DST_CID = 2;

    function setUp() public virtual {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Pin block.chainid so that Bridge.localChainID() and emitted BridgeOut events carry the
        // same value tests assert against.
        vm.chainId(LOCAL_CID);

        // BridgeERC20 beacon (impl + beacon, no proxy — proxies are deployed per-token at runtime).
        BridgeERC20 erc20Impl = new BridgeERC20();
        bridgeERC20Beacon = new UpgradeableBeacon(address(erc20Impl), owner);

        // Bridge impl + beacon + proxy. Initialize with a dummy agency address; we'll re-init the
        // agency after we know the proxy addresses, so we use a two-step pattern:
        // 1) Deploy bridge impl + beacon.
        // 2) Deploy agency impl + beacon + proxy with bridge address known.
        // 3) Deploy bridge proxy with agency address known.
        Bridge bridgeImpl = new Bridge();
        bridgeBeacon = new UpgradeableBeacon(address(bridgeImpl), owner);

        BridgeAgency agencyImpl = new BridgeAgency();
        agencyBeacon = new UpgradeableBeacon(address(agencyImpl), owner);

        // Break the Bridge↔Agency address cycle by predicting agency proxy address via CREATE
        // nonce determinism, then deploying Bridge proxy first with the predicted agency.
        address predictedAgency = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        // owner doubles as both ADMIN_ROLE-via-agency caller and the DEFAULT_ADMIN_ROLE governance
        // multisig in tests. Production deploy splits these (see Bridge.s.sol BRIDGE_ADMIN env).
        BeaconProxy bridgeProxy = new BeaconProxy(
            address(bridgeBeacon),
            abi.encodeCall(Bridge.initialize, (address(bridgeERC20Beacon), predictedAgency, owner))
        );
        bridge = Bridge(address(bridgeProxy));

        BeaconProxy agencyProxy = new BeaconProxy(
            address(agencyBeacon),
            abi.encodeCall(BridgeAgency.initialize, (address(bridge), address(bridgeERC20Beacon), owner))
        );
        agency = BridgeAgency(address(agencyProxy));

        // Sanity: ensure prediction matches.
        require(address(agency) == predictedAgency, "agency address mismatch");
    }

    /// @dev Deploy a mock LockRelease ERC-20 owned by `recipient`, wire it into the bridge as
    ///      LockRelease, and map a remote token at `DST_CID`.
    function _deployLockReleaseToken(address holder, uint256 supply) internal returns (Token token, address remote) {
        token = new Token("MockLR");
        token.transfer(holder, supply);
        remote = makeAddr("remoteLR");
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);
        agency.mapRemote(address(token), DST_CID, remote);
    }

    /// @dev Deploy a fresh BridgeERC20 via the agency, register as MintBurn, and map remote.
    function _deployMintBurnToken(
        string memory name,
        string memory symbol
    ) internal returns (BridgeERC20 token, address remote) {
        address t = agency.deployAndAddBridgeToken(name, symbol);
        token = BridgeERC20(t);
        remote = makeAddr(string.concat("remote-", symbol));
        agency.mapRemote(t, DST_CID, remote);
    }

    /// @dev Build a single InboundMessage with `feeRecipient = address(0)` (no fee paid out).
    ///      Convenience overload for system-call tests that don't exercise the fee-distribution
    ///      path. Tests that do should call `_msgWithFee` directly.
    function _msg(
        uint64 srcCID,
        uint64 nonce,
        address localToken,
        address recipient,
        uint256 amount
    ) internal pure returns (IBridge.InboundMessage memory) {
        return _msgWithFee(srcCID, nonce, localToken, recipient, amount, address(0));
    }

    /// @dev Build a single InboundMessage with an explicit `feeRecipient` (proposer withdrawal
    ///      address in production; injected by the EL system-call dispatcher).
    function _msgWithFee(
        uint64 srcCID,
        uint64 nonce,
        address localToken,
        address recipient,
        uint256 amount,
        address feeRecipient
    ) internal pure returns (IBridge.InboundMessage memory) {
        return IBridge.InboundMessage({
            srcChainID: srcCID,
            nonce: nonce,
            localToken: localToken,
            recipient: recipient,
            amount: amount,
            feeRecipient: feeRecipient
        });
    }
}
