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
    /// @dev EIP-7685-style system caller — the only address allowed to park inbound messages.
    address internal constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    address internal owner;
    address internal alice;
    address internal bob;

    Bridge internal bridge;
    BridgeAgency internal agency;

    UpgradeableBeacon internal bridgeBeacon;
    UpgradeableBeacon internal agencyBeacon;
    UpgradeableBeacon internal bridgeERC20Beacon;

    /// @dev This chain's chainID under test. Set via `vm.chainId(...)` in setUp so that
    ///      emitted `BridgeOut` events carry this value as `srcChainID`.
    uint64 internal constant LOCAL_CID = 1;
    /// @dev Default destination chainID used in user-path tests.
    uint64 internal constant DST_CID = 2;

    function setUp() public virtual {
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Pin block.chainid so emitted BridgeOut events carry the same value tests assert against.
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
        // multisig in tests. Production deploy hardcodes both roles to the same OWNER address
        // baked into the bridge raw-tx artifact (see BridgeRawTxs.s.sol).
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
    ///      The CREATE2 salt is derived from `(name, symbol)` so test cases that use distinct
    ///      `(name, symbol)` pairs get distinct addresses without callers having to manage salts.
    function _deployMintBurnToken(
        string memory name,
        string memory symbol
    ) internal returns (BridgeERC20 token, address remote) {
        bytes32 salt = keccak256(abi.encode(name, symbol));
        address t = agency.deployAndAddBridgeToken(name, symbol, 18, salt);
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

    /// @dev Park a batch as the system caller. Delivery tests follow up with `bridge.deliver` /
    ///      `bridge.deliverBatch` — the park-then-deliver two-step every inbound message takes.
    function _park(
        IBridge.InboundMessage[] memory msgs
    ) internal {
        vm.prank(SYSTEM);
        bridge.parkRemoteMessages(msgs);
    }

    /// @dev Park a single message as the system caller.
    function _parkOne(
        IBridge.InboundMessage memory m
    ) internal {
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = m;
        _park(msgs);
    }

    /// @dev Build a 7-field TokenSpamControl. Argument order mirrors the struct.
    function _cfg(
        uint256 minCrossOutAmount,
        uint16 proposerFeeBps,
        uint256 proposerFeeMin,
        uint256 proposerFeeMax,
        uint16 keeperFeeBps,
        uint256 keeperFeeMin,
        uint256 keeperFeeMax
    ) internal pure returns (IBridge.TokenSpamControl memory) {
        return IBridge.TokenSpamControl({
            minCrossOutAmount: minCrossOutAmount,
            proposerFeeBps: proposerFeeBps,
            proposerFeeMin: proposerFeeMin,
            proposerFeeMax: proposerFeeMax,
            keeperFeeBps: keeperFeeBps,
            keeperFeeMin: keeperFeeMin,
            keeperFeeMax: keeperFeeMax
        });
    }

    /// @dev Empty spam-control config (all-zero) — disables every knob.
    function _zeroCfg() internal pure returns (IBridge.TokenSpamControl memory) {
        return _cfg(0, 0, 0, 0, 0, 0, 0);
    }

    /// @dev Bridge-side deliverability oracle, recomputed purely from public state views. This is
    ///      the off-chain equivalent of the front-of-`_deliverOne` checks a keeper applies to decide
    ///      whether a parked message would clear the bridge's own gates, plus the resulting fee
    ///      split. Applies the identical checks and per-leg fee formula:
    ///        - not deliverable if the message is already consumed or not parked;
    ///        - per-leg fee = clamp((amount * bps) / 10_000, [feeMin, feeMax]); leg is 0 when
    ///          `bps == 0 && feeMin == 0` or `feeMax == 0`; proposer leg forced to 0 when the
    ///          parked `feeRecipient` is the zero address;
    ///        - not deliverable if `proposerFee + keeperFee >= amount` (`FeeExceedsAmount`).
    ///      This does NOT simulate the token calls — a `deliverable == true` message can still
    ///      revert at deliver time (disabled token, escrow shortfall, token revert).
    function _deliverableOracle(
        uint64 srcCID,
        uint64 nonce
    ) internal view returns (bool deliverable, uint256 toRecipient, uint256 proposerFee, uint256 keeperFee) {
        if (bridge.inboundConsumed(srcCID, nonce)) return (false, 0, 0, 0);
        IBridge.InboundMessage memory m = bridge.pendingMessage(srcCID, nonce);
        // A never-parked nonce reads back as an all-zero struct; mirror the contract's `!hasPending`
        // short-circuit. A real parked message always carries a nonzero nonce (the CL assigns nonces
        // from 1), so a zero nonce read here means "not parked".
        if (m.nonce == 0) return (false, 0, 0, 0);

        IBridge.TokenSpamControl memory s = bridge.spamControl(m.localToken);
        proposerFee = _oracleFeeLeg(m.amount, s.proposerFeeBps, s.proposerFeeMin, s.proposerFeeMax);
        keeperFee = _oracleFeeLeg(m.amount, s.keeperFeeBps, s.keeperFeeMin, s.keeperFeeMax);
        if (m.feeRecipient == address(0)) proposerFee = 0;
        if (proposerFee + keeperFee >= m.amount) return (false, 0, 0, 0);
        return (true, m.amount - proposerFee - keeperFee, proposerFee, keeperFee);
    }

    /// @dev One fee leg, identical to the contract's `_computeFee`: bps fee clamped to
    ///      `[feeMin, feeMax]`; zero when the leg is unconfigured (`bps == 0 && feeMin == 0`)
    ///      and clamped to zero by `feeMax == 0`.
    function _oracleFeeLeg(
        uint256 amount,
        uint16 bps,
        uint256 feeMin,
        uint256 feeMax
    ) private pure returns (uint256 fee) {
        if (bps == 0 && feeMin == 0) return 0;
        fee = (amount * bps) / 10_000;
        if (fee < feeMin) fee = feeMin;
        if (fee > feeMax) fee = feeMax;
    }
}
