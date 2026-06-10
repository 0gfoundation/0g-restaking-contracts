// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {Bridge} from "../src/bridge/Bridge.sol";
import {BridgeERC20} from "../src/bridge/BridgeERC20.sol";
import {IBridge} from "../src/bridge/IBridge.sol";

import {BridgeBaseTest} from "./BridgeBase.t.sol";
import {Token} from "./mocks/Token.sol";

/// @dev MintBurn token whose mint can be toggled to revert with a recognizable reason — models an
///      upstream failure (e.g. a precompile cap) that single `deliver` must bubble verbatim.
contract RevertingMintToken is ERC20 {
    bool public blocked = true;

    constructor() ERC20("RV", "") {}

    function setBlocked(
        bool b
    ) external {
        blocked = b;
    }

    function mint(address to, uint256 amount) external {
        if (blocked) revert("mint blocked");
        _mint(to, amount);
    }

    function burn(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
    }
}

/// @dev ERC777-style hookable token: fires `onMint` callback on the recipient after a successful
///      mint. Models the class of tokens whose admin-side registration would make the bridge's
///      delivery path reentrant if there were no guard.
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

/// @dev Recipient contract that re-enters Bridge.deliver() from the mint callback.
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
        try bridge.deliver(srcCID, nonce) {
            // success would mean reentrancy was NOT blocked — captured by caller assertions.
        } catch (bytes memory r) {
            lastReentryRevert = r;
        }
    }
}

/// @notice Covers the permissionless delivery half of park-then-deliver: `deliver` happy paths and
///         reverts (NoPendingMessage / AlreadyConsumed / bubbled token reasons), `deliverBatch`
///         per-message isolation, keeper-fee payment to msg.sender, permissionlessness, and the
///         reentrancy guard.
contract BridgeDeliverTest is BridgeBaseTest {
    uint64 constant SRC_CID = 99;

    address internal proposer;
    address internal keeper;

    function setUp() public override {
        super.setUp();
        proposer = makeAddr("proposer");
        keeper = makeAddr("keeper");
    }

    // -------------- deliver: happy paths --------------

    function test_deliver_happy_mintBurn() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 5 ether, proposer));

        // No fees configured: full amount to recipient, zero fee legs, keeper = msg.sender.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 5 ether, address(0), 0, keeper, 0);
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        assertEq(token.balanceOf(bob), 5 ether);
        assertEq(token.totalSupply(), 5 ether);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        // Pending cleared.
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 0);
        (bool deliverable,,,) = bridge.previewDeliver(SRC_CID, 1);
        assertFalse(deliverable, "consumed message no longer previewable");
    }

    function test_deliver_happy_lockRelease() public {
        Token token = new Token("LR");
        token.transfer(address(bridge), 100 ether);
        agency.addToken(address(token), IBridge.BridgeMode.LockRelease);

        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 25 ether, proposer));
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        assertEq(token.balanceOf(bob), 25 ether);
        assertEq(token.balanceOf(address(bridge)), 75 ether);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    function test_deliver_isPermissionless() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msg(SRC_CID, 1, address(token), bob, 5 ether));

        address rando = makeAddr("rando");
        vm.prank(rando);
        bridge.deliver(SRC_CID, 1);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    function test_deliver_keeperFeePaidToCaller() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        // Keeper leg only: 1% with wide cap.
        agency.setSpamControl(address(token), _cfg(0, 0, 0, 0, 100, 0, type(uint256).max));
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 100 ether, proposer));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeIn(SRC_CID, 1, address(token), bob, 99 ether, address(0), 0, keeper, 1 ether);
        vm.prank(keeper);
        bridge.deliver(SRC_CID, 1);

        assertEq(token.balanceOf(bob), 99 ether, "recipient gets amount - keeperFee");
        assertEq(token.balanceOf(keeper), 1 ether, "keeper fee goes to msg.sender");
        assertEq(token.balanceOf(proposer), 0, "proposer leg unconfigured");
    }

    // -------------- deliver: revert paths --------------

    function test_deliver_revertsIfNotParked() public {
        vm.expectRevert(IBridge.NoPendingMessage.selector);
        bridge.deliver(SRC_CID, 42);
    }

    function test_deliver_revertsIfAlreadyConsumed() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msg(SRC_CID, 1, address(token), bob, 5 ether));
        bridge.deliver(SRC_CID, 1);

        // Replay-defence: delivering a consumed nonce reverts AlreadyConsumed (checked before
        // the pending-existence check, so post-delivery replays get the precise reason).
        vm.expectRevert(IBridge.AlreadyConsumed.selector);
        bridge.deliver(SRC_CID, 1);
        assertEq(token.balanceOf(bob), 5 ether, "no double mint");
    }

    function test_deliver_disabledToken_revertsAndStaysParked() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msg(SRC_CID, 1, address(token), bob, 5 ether));
        agency.disableToken(address(token));

        vm.expectRevert(bytes("disabled"));
        bridge.deliver(SRC_CID, 1);

        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 5 ether, "stays parked");

        // Re-enable → anyone delivers.
        agency.addToken(address(token), IBridge.BridgeMode.MintBurn);
        bridge.deliver(SRC_CID, 1);
        assertEq(token.balanceOf(bob), 5 ether);
    }

    function test_deliver_bubblesUnderlyingTokenRevert() public {
        RevertingMintToken token = new RevertingMintToken();
        agency.addToken(address(token), IBridge.BridgeMode.MintBurn);
        _parkOne(_msg(SRC_CID, 1, address(token), bob, 5 ether));

        // Single deliver forwards the underlying reason verbatim.
        vm.expectRevert(bytes("mint blocked"));
        bridge.deliver(SRC_CID, 1);
        assertFalse(bridge.inboundConsumed(SRC_CID, 1));
        assertEq(bridge.pendingMessage(SRC_CID, 1).amount, 5 ether, "stays parked");

        // Upstream unblocks → same message delivers.
        token.setBlocked(false);
        bridge.deliver(SRC_CID, 1);
        assertEq(token.balanceOf(bob), 5 ether);
        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
    }

    // -------------- deliverBatch --------------

    function test_deliverBatch_happyMultiple() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](3);
        msgs[0] = _msgWithFee(SRC_CID, 1, address(token), alice, 1 ether, proposer);
        msgs[1] = _msgWithFee(SRC_CID, 2, address(token), alice, 2 ether, proposer);
        msgs[2] = _msgWithFee(SRC_CID, 3, address(token), bob, 3 ether, proposer);
        _park(msgs);

        uint64[] memory nonces = new uint64[](3);
        (nonces[0], nonces[1], nonces[2]) = (1, 2, 3);
        vm.prank(keeper);
        bridge.deliverBatch(SRC_CID, nonces);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 3 ether);
        for (uint64 n = 1; n <= 3; ++n) {
            assertTrue(bridge.inboundConsumed(SRC_CID, n));
        }
    }

    function test_deliverBatch_middleFailureIsIsolated() public {
        (BridgeERC20 a,) = _deployMintBurnToken("A", "A");
        (BridgeERC20 b,) = _deployMintBurnToken("B", "B");
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](3);
        msgs[0] = _msg(SRC_CID, 1, address(a), alice, 1 ether);
        msgs[1] = _msg(SRC_CID, 2, address(b), alice, 2 ether);
        msgs[2] = _msg(SRC_CID, 3, address(a), bob, 3 ether);
        _park(msgs);
        agency.disableToken(address(b)); // middle msg will fail at deliver time

        // Failure surfaces as a visible BridgeMessageFailed carrying the caught reason; messages
        // before AND after it still deliver.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeMessageFailed(SRC_CID, 2, abi.encodeWithSignature("Error(string)", "disabled"));
        uint64[] memory nonces = new uint64[](3);
        (nonces[0], nonces[1], nonces[2]) = (1, 2, 3);
        vm.prank(keeper);
        bridge.deliverBatch(SRC_CID, nonces);

        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertFalse(bridge.inboundConsumed(SRC_CID, 2));
        assertTrue(bridge.inboundConsumed(SRC_CID, 3));
        assertEq(a.balanceOf(alice), 1 ether);
        assertEq(a.balanceOf(bob), 3 ether);
        assertEq(b.balanceOf(alice), 0);
        assertEq(bridge.pendingMessage(SRC_CID, 2).amount, 2 ether, "failed message stays parked");

        // Recovery: re-enable and deliver the parked one.
        agency.addToken(address(b), IBridge.BridgeMode.MintBurn);
        bridge.deliver(SRC_CID, 2);
        assertEq(b.balanceOf(alice), 2 ether);
    }

    function test_deliverBatch_notParkedNonceEmitsFailedAndContinues() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](2);
        msgs[0] = _msg(SRC_CID, 1, address(token), alice, 1 ether);
        msgs[1] = _msg(SRC_CID, 3, address(token), bob, 3 ether);
        _park(msgs);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeMessageFailed(SRC_CID, 2, abi.encodeWithSelector(IBridge.NoPendingMessage.selector));
        uint64[] memory nonces = new uint64[](3);
        (nonces[0], nonces[1], nonces[2]) = (1, 2, 3);
        bridge.deliverBatch(SRC_CID, nonces);

        assertTrue(bridge.inboundConsumed(SRC_CID, 1));
        assertTrue(bridge.inboundConsumed(SRC_CID, 3));
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(bob), 3 ether);
    }

    function test_deliverBatch_duplicateNonceSecondAttemptFails() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msg(SRC_CID, 1, address(token), bob, 5 ether));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.BridgeMessageFailed(SRC_CID, 1, abi.encodeWithSelector(IBridge.AlreadyConsumed.selector));
        uint64[] memory nonces = new uint64[](2);
        (nonces[0], nonces[1]) = (1, 1);
        bridge.deliverBatch(SRC_CID, nonces);

        assertEq(token.balanceOf(bob), 5 ether, "delivered exactly once");
    }

    function test_deliverBatch_keeperFeePaidPerMessageToMsgSender() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        agency.setSpamControl(address(token), _cfg(0, 0, 0, 0, 100, 0, type(uint256).max));
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](2);
        msgs[0] = _msgWithFee(SRC_CID, 1, address(token), alice, 100 ether, proposer);
        msgs[1] = _msgWithFee(SRC_CID, 2, address(token), bob, 200 ether, proposer);
        _park(msgs);

        uint64[] memory nonces = new uint64[](2);
        (nonces[0], nonces[1]) = (1, 2);
        vm.prank(keeper);
        bridge.deliverBatch(SRC_CID, nonces);

        // 1% of 100 + 1% of 200 = 3 — paid to the batch caller even though the inner self-call
        // frame's msg.sender is the bridge itself (keeper rides as an argument).
        assertEq(token.balanceOf(keeper), 3 ether);
        assertEq(token.balanceOf(alice), 99 ether);
        assertEq(token.balanceOf(bob), 198 ether);
    }

    // -------------- reentrancy --------------

    /// @notice Defense-in-depth: an ERC777-style token whose `mint` triggers a recipient hook
    ///         must not be able to re-enter `Bridge.deliver` and double-mint. With nonReentrant,
    ///         the inner deliver call reverts via the reentrancy guard, so the recipient ends up
    ///         with exactly one `amount` even though the hook fires.
    function test_deliver_blocksReentrancyOnHookableToken() public {
        // Deploy a hookable MintBurn token wired so Bridge holds MINTER_ROLE.
        HookableToken hookImpl = new HookableToken();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(hookImpl), owner);
        BeaconProxy proxy = new BeaconProxy(
            address(beacon), abi.encodeCall(HookableToken.initialize, ("Hook", "HOOK", address(bridge)))
        );
        HookableToken hook = HookableToken(address(proxy));
        agency.addToken(address(hook), IBridge.BridgeMode.MintBurn);

        ReentrantAttacker attacker = new ReentrantAttacker(bridge);

        uint64 N = 1;
        uint256 AMT = 5 ether;
        _parkOne(_msg(SRC_CID, N, address(hook), address(attacker), AMT));
        attacker.arm(SRC_CID, N);

        bridge.deliver(SRC_CID, N);

        // Outer deliver succeeded → consumed=true, pending cleared, attacker minted ONCE only.
        assertTrue(bridge.inboundConsumed(SRC_CID, N));
        assertEq(hook.balanceOf(address(attacker)), AMT, "no double mint");
        assertGt(attacker.reentryCount(), 0, "hook fired (so we know reentrancy was attempted)");
        // Inner deliver reverted with ReentrancyGuardReentrantCall.
        bytes4 expectedSelector = ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector;
        bytes memory revertData = attacker.lastReentryRevert();
        assertEq(revertData.length, 4, "expected 4-byte selector revert");
        assertEq(bytes4(revertData), expectedSelector, "expected ReentrancyGuardReentrantCall");
    }

    /// @notice The self-call dispatch point is gated to the bridge itself — a keeper can't use it
    ///         to spoof another keeper address into the fee leg.
    function test_deliverOneInternal_revertsForExternalCallers() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");
        _parkOne(_msg(SRC_CID, 1, address(token), bob, 5 ether));
        vm.expectRevert(IBridge.OnlySelf.selector);
        vm.prank(keeper);
        bridge.deliverOneInternal(SRC_CID, 1, keeper);
    }

    // -------------- previewDeliver basic states --------------

    function test_previewDeliver_states() public {
        (BridgeERC20 token,) = _deployMintBurnToken("X", "X");

        // Not parked → not deliverable.
        (bool deliverable, uint256 toRecipient,,) = bridge.previewDeliver(SRC_CID, 1);
        assertFalse(deliverable);
        assertEq(toRecipient, 0);

        // Parked, no fees → full amount.
        _parkOne(_msgWithFee(SRC_CID, 1, address(token), bob, 5 ether, proposer));
        uint256 proposerFee;
        uint256 keeperFee;
        (deliverable, toRecipient, proposerFee, keeperFee) = bridge.previewDeliver(SRC_CID, 1);
        assertTrue(deliverable);
        assertEq(toRecipient, 5 ether);
        assertEq(proposerFee, 0);
        assertEq(keeperFee, 0);

        // Consumed → not deliverable.
        bridge.deliver(SRC_CID, 1);
        (deliverable,,,) = bridge.previewDeliver(SRC_CID, 1);
        assertFalse(deliverable);
    }
}
