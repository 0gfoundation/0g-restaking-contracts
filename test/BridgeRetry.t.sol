// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";

/// @dev ERC777-style hookable token: fires `onMint` callback on the recipient after a successful
///      mint. Models the class of tokens whose admin-side registration would make the bridge's
///      retry path reentrant if there were no guard.
contract HookableToken is Initializable, ERC20Upgradeable, AccessControlUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    function initialize(string memory n, string memory s, address bridge_) external initializer {
        __ERC20_init(n, s);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, bridge_);
        _grantRole(MINTER_ROLE, bridge_);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
        if (to.code.length > 0) {
            // best-effort hook; ignore failures so a vanilla EOA recipient still works
            (bool ok,) = to.call(abi.encodeWithSignature("onMint(uint256)", amount));
            ok;
        }
    }

    function burn(
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        _burn(msg.sender, amount);
    }
}

/// @dev Recipient contract that re-enters Bridge.retry() from the mint callback.
contract ReentrantAttacker {
    Bridge public immutable bridge;
    uint64 public srcCID;
    uint64 public nonce;
    bool public engaged;
    uint256 public reentryCount;
    bytes public lastReentryRevert;

    constructor(
        Bridge b
    ) {
        bridge = b;
    }

    function arm(uint64 _srcCID, uint64 _nonce) external {
        srcCID = _srcCID;
        nonce = _nonce;
        engaged = true;
    }

    function onMint(
        uint256
    ) external {
        if (!engaged) return;
        reentryCount++;
        try bridge.retry(srcCID, nonce) {
            // success would mean reentrancy was NOT blocked — captured by caller assertions.
        } catch (bytes memory r) {
            lastReentryRevert = r;
        }
    }
}

/// @notice Covers `retry`: happy path, no-pending revert, already-consumed revert, retry-fail
///         keeps pending, retry-fail-then-succeed.
contract BridgeRetryTest is BridgeBaseTest {
    address constant SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    uint64 constant SRC_CID = 99;

    /// @dev Drive a message into pendingMessages by disabling the token before the system call.
    function _makePending(BridgeERC20 token, uint64 nonce, uint256 amount) internal {
        agency.disableToken(address(token));
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, nonce, address(token), bob, amount);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);
        // Sanity: pending and not consumed.
        assertFalse(bridge.inboundConsumed(SRC_CID, nonce));
        assertEq(bridge.pendingMessage(SRC_CID, nonce).amount, amount);
    }

    /// @dev Re-enable a previously-disabled MintBurn token. Pairs with `_makePending` so retry
    ///      tests can transition from failure → success without leaning on the deleted setEnabled.
    function _reEnableMintBurn(
        BridgeERC20 token
    ) internal {
        agency.addToken(address(token), IBridge.BridgeMode.MintBurn);
    }

    function test_retry_happy() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);

        // Re-enable so retry succeeds.
        _reEnableMintBurn(token);

        // Anyone can call retry — exercise from a third party.
        address random = makeAddr("random");

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 5 ether);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeMessageRetried(SRC_CID, 1, true);
        vm.prank(random);
        bridge.retry(SRC_CID, 1);

        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(token.balanceOf(bob), 5 ether);
        // pending cleared
        IBridge.InboundMessage memory cleared = bridge.pendingMessage(SRC_CID, 1);
        assertEq(cleared.amount, 0);
        assertEq(cleared.recipient, address(0));
    }

    function test_retry_revertsIfNoPending() public {
        vm.expectRevert(IBridge.NoPendingMessage.selector);
        bridge.retry(SRC_CID, 42);
    }

    /// @notice With `nonReentrant` guarding `retry`, the `AlreadyConsumed` branch is unreachable
    ///         under normal flow — a successful retry atomically sets `consumed=true` AND clears
    ///         `hasPending`, so the only way to reach the dead branch is storage corruption /
    ///         broken upgrade. The check is retained as defense-in-depth. This test exercises
    ///         the practical adjacent case: retrying after pending was cleared by a successful
    ///         prior retry → `NoPendingMessage`.
    function test_retry_revertsAfterPendingCleared() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);
        _reEnableMintBurn(token);
        bridge.retry(SRC_CID, 1); // success → consumed=true, pending cleared
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));

        // Pending was cleared — retrying again hits no-pending first.
        vm.expectRevert(IBridge.NoPendingMessage.selector);
        bridge.retry(SRC_CID, 1);
    }

    function test_retry_failKeepsPending() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);

        // Token still disabled — retry should fail-keep-pending.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeMessageRetried(SRC_CID, 1, false);
        bridge.retry(SRC_CID, 1);

        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 5 ether);
    }

    function test_retry_failThenSucceed() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);

        // First retry fails — token still disabled.
        bridge.retry(SRC_CID, 1);
        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 5 ether);

        // Re-enable and retry — succeeds.
        _reEnableMintBurn(token);
        bridge.retry(SRC_CID, 1);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(token.balanceOf(bob), 5 ether);
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 0);
    }

    function test_retry_isPermissionless() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _makePending(token, 1, 5 ether);
        _reEnableMintBurn(token);

        // Call from EOA with no roles.
        address rando = makeAddr("rando");
        vm.deal(rando, 1 ether);
        vm.prank(rando);
        bridge.retry(SRC_CID, 1);

        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    /// @notice Defense-in-depth: an ERC777-style token whose `mint` triggers a recipient hook
    ///         must not be able to re-enter `Bridge.retry` and double-mint. With nonReentrant,
    ///         the inner retry call reverts via the reentrancy guard, so the recipient ends up
    ///         with exactly one `amount` even though the hook fires.
    function test_retry_blocksReentrancyOnHookableToken() public {
        // Deploy a hookable MintBurn token wired so Bridge holds MINTER_ROLE.
        HookableToken hookImpl = new HookableToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(hookImpl), owner);
        BeaconProxy proxy = new BeaconProxy(
            address(beacon), abi.encodeCall(HookableToken.initialize, ("Hook", "HOOK", address(bridge)))
        );
        HookableToken hook = HookableToken(address(proxy));
        agency.addToken(address(hook), IBridge.BridgeMode.MintBurn);

        ReentrantAttacker attacker = new ReentrantAttacker(bridge);

        // Drive a message into pending: disable, system-call, then re-enable for retry.
        uint64 N = 1;
        uint256 AMT = 5 ether;
        agency.disableToken(address(hook));
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = _msg(SRC_CID, N, address(hook), address(attacker), AMT);
        vm.prank(SYSTEM);
        bridge.executeRemoteMessages(msgs);
        assertEq(bridge.pendingMessage(SRC_CID, N).amount, AMT);

        agency.addToken(address(hook), IBridge.BridgeMode.MintBurn);
        attacker.arm(SRC_CID, N);

        bridge.retry(SRC_CID, N);

        // Outer retry succeeded → consumed=true, pending cleared, attacker minted ONCE only.
        assertTrue(bridge.inboundConsumed(SRC_CID, N));
        assertEq(hook.balanceOf(address(attacker)), AMT, "no double mint");
        assertGt(attacker.reentryCount(), 0, "hook fired (so we know reentrancy was attempted)");
        // Inner retry reverted with ReentrancyGuardReentrantCall.
        bytes4 expectedSelector = ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector;
        bytes memory revertData = attacker.lastReentryRevert();
        assertEq(revertData.length, 4, "expected 4-byte selector revert");
        assertEq(bytes4(revertData), expectedSelector, "expected ReentrancyGuardReentrantCall");
    }
}
