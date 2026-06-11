// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridge} from "./IBridge.sol";
import {BridgeERC20} from "./BridgeERC20.sol";

/// @dev Minimal interface for any token that supports MINTER_ROLE-style
/// `mint(to,amount)` and self-burn `burn(amount)`. Both BridgeERC20
/// (templated minted-token) and W0G's `burn(uint256)` (selector 0x42966c68)
/// match this shape.
///
/// burnAndSend deliberately does NOT call burnFrom on the user's behalf.
/// Instead it does a two-step: (1) IERC20.transferFrom user→Bridge,
/// (2) IBurnable.burn from Bridge's own balance. This:
///   - works against any ERC-20 standard burnable (no `burnFrom` requirement),
///   - keeps the precompile minter == msg.sender == Bridge invariant explicit,
///   - matches the user's semantic expectation that the user "transfers tokens
///     to the bridge", not "lets the bridge burn from the user directly".
interface IBurnable {
    function mint(address to, uint256 amount) external;
    function burn(
        uint256 amount
    ) external;
}

/**
 * @title Bridge
 * @notice Cross-chain bridge contract deployed at a fixed address on every 0G chain (primary + satellite).
 * @dev Storage namespace `0g.bridge.Bridge` (ERC-7201). Beacon-upgradeable; no UUPS.
 *      User flow: `lockAndSend` (LockRelease) / `burnAndSend` (MintBurn) emit a `BridgeOut` event.
 *      Destination flow is park-then-deliver:
 *        [park]    CL → EL → SYSTEM_ADDRESS calls `parkRemoteMessages` with decoded `InboundMessage[]`.
 *                  Each message is only written to `pendingMessages` — no token calls, no fee math,
 *                  no events (the EL discards system-call logs). The loop has no revert path, so the
 *                  consensus-critical system call can never halt on a bad message.
 *        [deliver] anyone calls `deliver` / `deliverBatch` in a normal transaction, which computes
 *                  the destination-side fee, moves tokens, flips `inboundConsumed`, and emits a
 *                  `BridgeIn` fully visible to receipts / `eth_getLogs`.
 *      Block finalization therefore guarantees a message is *claimable*, not delivered; keepers
 *      discover work by scanning nonces up to `lastParkedNonce[srcCID]` (no events at park time).
 *      The CL strictly enforces per-(srcCID, dstCID) monotonic nonce, so the contract's
 *      `inboundConsumed` mapping is a defensive replay-shield rather than the primary order check.
 */
contract Bridge is IBridge, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice EIP-4788 / EIP-7002 / EIP-7685 system caller.
    address public constant SYSTEM_ADDRESS = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    /// @dev Role granted to BridgeAgency on init; gates day-to-day token configuration.
    ///      Distinct from `DEFAULT_ADMIN_ROLE` which is held by a separate governance multisig
    ///      and grants meta-authority over role assignments.
    bytes32 public constant ADMIN_ROLE = keccak256("BRIDGE_ADMIN_ROLE");

    /// @notice Hard cap on `proposerFeeBps + keeperFeeBps` accepted by `setSpamControl`.
    ///         10000 = 100% — fees up to (but not equal to) the full inbound amount are allowed.
    ///         Combined fees equal to or exceeding the inbound amount make delivery revert
    ///         `FeeExceedsAmount`; the message stays parked until admin rebalances spam config.
    uint16 public constant MAX_FEE_BPS = 10_000;

    /// @notice Per-token bridge configuration. Schema-frozen (only enabled flag + mode).
    struct TokenConfig {
        /// When false, both user paths and destination-side delivery revert. Disabling preserves
        /// `mode` so a future re-enable doesn't accidentally switch the token's escrow semantics.
        bool enabled;
        /// LockRelease (escrow on source / release from bridge balance on dest) or MintBurn (burn on
        /// source / mint on dest via MINTER_ROLE). Mode may differ per chain for the same asset.
        BridgeMode mode;
    }

    /// @custom:storage-location erc7201:0g.bridge.Bridge
    struct BridgeStorage {
        /// Shared `UpgradeableBeacon` used by every BridgeERC20 BeaconProxy deployed via
        /// `BridgeAgency.deployAndAddBridgeToken`. Set once at init; not user-mutable.
        address bridgeERC20Beacon;
        /// BridgeAgency proxy holding `ADMIN_ROLE`. Stored so `deployBridgeERC20` can verify the
        /// caller and so off-chain tooling can resolve the agency from the bridge address alone.
        address agency;
        /// localToken => `(enabled, mode)`. The destination-side delivery path consults this
        /// (not the source-declared mode in the SSZ message) to decide release-vs-mint.
        mapping(address => TokenConfig) tokens;
        /// localToken => dstCID => remote token address on the destination chain. Emitted in
        /// `BridgeOut` for off-chain consumers; the CL poller resolves it before injecting into SSZ.
        mapping(address => mapping(uint64 => address)) remoteToken;
        /// dstCID => last issued outbound nonce. `lockAndSend` / `burnAndSend` pre-increment this so
        /// the first emitted nonce per destination is 1 (the CL store treats 0 as "no nonce seen").
        mapping(uint64 => uint64) outboundNonce;
        /// srcCID => nonce => already-delivered flag. Defensive replay shield; the CL state-transition
        /// also enforces per-(srcCID, dstCID) monotonicity, so this guards against bugs upstream.
        mapping(uint64 => mapping(uint64 => bool)) inboundConsumed;
        /// srcCID => nonce => parked message awaiting permissionless delivery. Written by
        /// `parkRemoteMessages` (the system call); cleared on successful `deliver` / `deliverBatch`.
        mapping(uint64 => mapping(uint64 => InboundMessage)) pendingMessages;
        /// srcCID => nonce => exists-flag for `pendingMessages`. Needed because reading a default-zero
        /// `InboundMessage` from the map can't be distinguished from a real all-zero message.
        mapping(uint64 => mapping(uint64 => bool)) hasPending;
        /// localToken => spam-control knobs. Empty entry means no source-side floor and no
        /// destination-side fee (delivers the full inbound `amount` to `recipient`).
        mapping(address => TokenSpamControl) spamControl;
        /// srcCID => highest nonce ever parked (monotonic max). Keeper-discovery anchor — park
        /// emits no events, so keepers scan `(own delivered watermark, lastParkedNonce]` per lane.
        mapping(uint64 => uint64) lastParkedNonce;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.bridge.Bridge")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BridgeStorageLocation = 0x1324c42040668e5a4f3621d919fc96f623467372a61a391f09286004a0ed7e00;

    function _getBridgeStorage() internal pure returns (BridgeStorage storage $) {
        assembly {
            $.slot := BridgeStorageLocation
        }
    }

    /// @notice Initialize the Bridge.
    /// @param bridgeERC20Beacon_ Address of the shared `UpgradeableBeacon` for BridgeERC20 instances.
    /// @param agency_ Address granted ADMIN_ROLE; typically the BridgeAgency proxy. Handles
    ///        day-to-day token registration / spam-control configuration.
    /// @param admin_ Address granted DEFAULT_ADMIN_ROLE; typically a governance multisig. Holds
    ///        meta-authority over role assignments (least-privilege split from `agency_`).
    function initialize(address bridgeERC20Beacon_, address agency_, address admin_) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        if (bridgeERC20Beacon_ == address(0) || agency_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, agency_);

        BridgeStorage storage $ = _getBridgeStorage();
        $.bridgeERC20Beacon = bridgeERC20Beacon_;
        $.agency = agency_;
    }

    // ============= User paths =============

    /// @inheritdoc IBridge
    /// @dev Source-side anti-spam: rejects inputs below `spamControl[token].minCrossOutAmount`. The
    ///      full `amount` is escrowed and emitted in the `BridgeOut` event. Fee math is performed
    ///      destination-side at deliver time, paid out of the inbound `amount`.
    function lockAndSend(address token, uint64 dstCID, address recipient, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountTooSmall();
        // A zero recipient parks fine on the destination but can never be delivered (release/mint to
        // address(0) always reverts), so the source funds would be locked with no recovery short of
        // a contract upgrade. Reject at the source, same rationale as RemoteTokenNotMapped.
        if (recipient == address(0)) revert ZeroAddress();
        BridgeStorage storage $ = _getBridgeStorage();
        TokenConfig memory cfg = $.tokens[token];
        if (!cfg.enabled) revert TokenDisabled();
        if (cfg.mode != BridgeMode.LockRelease) revert WrongMode();
        address remote = $.remoteToken[token][dstCID];
        if (remote == address(0)) revert RemoteTokenNotMapped();

        _applyAntiSpam($, token, amount);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint64 nonce = ++$.outboundNonce[dstCID];
        emit BridgeOut(uint64(block.chainid), dstCID, nonce, token, remote, recipient, amount, uint8(cfg.mode));
    }

    /// @inheritdoc IBridge
    /// @dev Two-step: (1) transferFrom user → Bridge, (2) Bridge self-burns. Token must implement
    ///      standard IERC20 + a `burn(uint256)` method that, internally, decrements the precompile's
    ///      MinterSupply[Bridge] (W0G does this via `_burnFrom` calling
    ///      `precompile.burn(msg.sender, ..)`, where msg.sender == Bridge). BridgeERC20 template
    ///      matches the same interface.
    ///
    ///      Source-side anti-spam: rejects inputs below `spamControl[token].minCrossOutAmount`. The
    ///      full `amount` is burned and emitted in the `BridgeOut` event. Fee math is destination-side.
    function burnAndSend(address token, uint64 dstCID, address recipient, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountTooSmall();
        // A zero recipient parks fine on the destination but can never be delivered (release/mint to
        // address(0) always reverts), so the source funds would be burned with no recovery short of
        // a contract upgrade. Reject at the source, same rationale as RemoteTokenNotMapped.
        if (recipient == address(0)) revert ZeroAddress();
        BridgeStorage storage $ = _getBridgeStorage();
        TokenConfig memory cfg = $.tokens[token];
        if (!cfg.enabled) revert TokenDisabled();
        if (cfg.mode != BridgeMode.MintBurn) revert WrongMode();
        address remote = $.remoteToken[token][dstCID];
        if (remote == address(0)) revert RemoteTokenNotMapped();

        _applyAntiSpam($, token, amount);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IBurnable(token).burn(amount);
        uint64 nonce = ++$.outboundNonce[dstCID];
        emit BridgeOut(uint64(block.chainid), dstCID, nonce, token, remote, recipient, amount, uint8(cfg.mode));
    }

    /// @dev Source-side anti-spam: reject inputs below the configured per-token minimum.
    function _applyAntiSpam(BridgeStorage storage $, address token, uint256 amount) internal view {
        TokenSpamControl memory s = $.spamControl[token];
        if (amount < s.minCrossOutAmount) revert AmountTooSmall();
    }

    /// @dev Compute ONE destination-side fee leg for an inbound `amount`. The bps fee is
    ///      `(amount * bps) / 10_000`, then clamped to `[feeMin, feeMax]`. Returns 0 when the leg
    ///      is unconfigured (`bps == 0 && feeMin == 0`); `feeMax == 0` also clamps the leg to 0.
    ///      Whether the combined legs fit inside `amount` is checked by the caller
    ///      (`FeeExceedsAmount`), not per leg.
    function _computeFee(
        uint256 amount,
        uint16 bps,
        uint256 feeMin,
        uint256 feeMax
    ) internal pure returns (uint256 fee) {
        if (bps == 0 && feeMin == 0) return 0;
        fee = (amount * bps) / 10_000;
        if (fee < feeMin) fee = feeMin;
        if (fee > feeMax) fee = feeMax;
    }

    // ============= System path (park) =============

    /// @inheritdoc IBridge
    function parkRemoteMessages(
        InboundMessage[] calldata msgs
    ) external {
        if (msg.sender != SYSTEM_ADDRESS) revert NotSystemCaller();
        BridgeStorage storage $ = _getBridgeStorage();
        uint256 n = msgs.length;
        for (uint256 i = 0; i < n; ++i) {
            InboundMessage calldata m = msgs[i];
            // Defensive idempotency: the CL nonce watermark prevents duplicates from reaching the
            // contract; skipping (rather than reverting) keeps the system call halt-free anyway.
            if ($.inboundConsumed[m.srcChainID][m.nonce] || $.hasPending[m.srcChainID][m.nonce]) {
                continue;
            }
            $.pendingMessages[m.srcChainID][m.nonce] = m;
            $.hasPending[m.srcChainID][m.nonce] = true;
            if (m.nonce > $.lastParkedNonce[m.srcChainID]) {
                $.lastParkedNonce[m.srcChainID] = m.nonce;
            }
        }
    }

    // ============= Permissionless delivery =============

    /// @inheritdoc IBridge
    function deliver(uint64 srcCID, uint64 nonce) external nonReentrant {
        // Direct internal dispatch (no try/catch): a failure reverts the whole tx with the
        // underlying reason, and the message stays parked.
        _deliverOne(srcCID, nonce, msg.sender);
    }

    /// @inheritdoc IBridge
    function deliverBatch(uint64 srcCID, uint64[] calldata nonces) external nonReentrant {
        uint256 n = nonces.length;
        for (uint256 i = 0; i < n; ++i) {
            // External self-call so each message's failure is isolated by try/catch. Inside the
            // self-call frame `msg.sender` is the Bridge itself, so the keeper (this frame's
            // msg.sender) must travel as an argument. All remaining gas is forwarded (no
            // per-message cap) — the caller pays and bears halt-burn risk.
            try this.deliverOneInternal(srcCID, nonces[i], msg.sender) {}
            catch (bytes memory reason) {
                emit BridgeMessageFailed(srcCID, nonces[i], reason);
            }
        }
    }

    /// @notice Self-call dispatch point for `deliverBatch`'s per-message try/catch isolation.
    /// @dev Reverts unless `msg.sender == address(this)`. Not part of `IBridge` — external only
    ///      because Solidity try/catch requires an external call.
    /// @param keeper The original `deliverBatch` caller, paid the keeper fee leg.
    function deliverOneInternal(uint64 srcCID, uint64 nonce, address keeper) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _deliverOne(srcCID, nonce, keeper);
    }

    /// @dev Deliver one parked message: checks, dual fee legs, state flip (consumed + pending
    ///      cleared) BEFORE the token interactions, then the visible `BridgeIn`. Reverts (bubbling
    ///      the underlying reason) on any failure, leaving the message parked.
    ///      Split: `toRecipient = amount - proposerFee - keeperFee`; `proposerFee` goes to the
    ///      parked message's `feeRecipient` (skipped when zero address — no value stuck);
    ///      `keeperFee` goes to `keeper` (the delivery tx sender). For LockRelease all three legs
    ///      release from the same bridge escrow, so escrow must cover the full inbound amount.
    function _deliverOne(uint64 srcCID, uint64 nonce, address keeper) internal {
        BridgeStorage storage $ = _getBridgeStorage();
        if ($.inboundConsumed[srcCID][nonce]) revert AlreadyConsumed();
        if (!$.hasPending[srcCID][nonce]) revert NoPendingMessage();

        InboundMessage memory m = $.pendingMessages[srcCID][nonce];
        TokenConfig memory cfg = $.tokens[m.localToken];
        // ASCII Error(string) so BridgeMessageFailed.reason carries bytes downstream consumers
        // (explorer, keeper bots) can decode without this contract's ABI.
        if (!cfg.enabled) revert("disabled");

        TokenSpamControl memory s = $.spamControl[m.localToken];
        uint256 proposerFee = _computeFee(m.amount, s.proposerFeeBps, s.proposerFeeMin, s.proposerFeeMax);
        uint256 keeperFee = _computeFee(m.amount, s.keeperFeeBps, s.keeperFeeMin, s.keeperFeeMax);
        if (m.feeRecipient == address(0)) proposerFee = 0;
        if (proposerFee + keeperFee >= m.amount) revert FeeExceedsAmount();
        uint256 toRecipient = m.amount - proposerFee - keeperFee;

        // Effects before interactions: consumed + cleared before any token call.
        $.inboundConsumed[srcCID][nonce] = true;
        delete $.pendingMessages[srcCID][nonce];
        $.hasPending[srcCID][nonce] = false;

        if (cfg.mode == BridgeMode.MintBurn) {
            IBurnable(m.localToken).mint(m.recipient, toRecipient);
            if (proposerFee > 0) IBurnable(m.localToken).mint(m.feeRecipient, proposerFee);
            if (keeperFee > 0) IBurnable(m.localToken).mint(keeper, keeperFee);
        } else {
            IERC20(m.localToken).safeTransfer(m.recipient, toRecipient);
            if (proposerFee > 0) IERC20(m.localToken).safeTransfer(m.feeRecipient, proposerFee);
            if (keeperFee > 0) IERC20(m.localToken).safeTransfer(keeper, keeperFee);
        }

        emit BridgeIn(
            srcCID,
            nonce,
            m.localToken,
            m.recipient,
            toRecipient,
            proposerFee > 0 ? m.feeRecipient : address(0),
            proposerFee,
            keeper,
            keeperFee
        );
    }

    // ============= Admin (ADMIN_ROLE) =============

    /// @inheritdoc IBridge
    function configureToken(address localToken, bool enabled, BridgeMode mode) external onlyRole(ADMIN_ROLE) {
        if (localToken == address(0)) revert ZeroAddress();
        BridgeStorage storage $ = _getBridgeStorage();
        $.tokens[localToken] = TokenConfig({enabled: enabled, mode: mode});
    }

    /// @inheritdoc IBridge
    function mapRemoteToken(address localToken, uint64 dstCID, address remoteToken_) external onlyRole(ADMIN_ROLE) {
        // remoteToken_ == address(0) is an explicit unmap: it deprecates this single (token, dstCID)
        // route (lockAndSend/burnAndSend then revert RemoteTokenNotMapped for dstCID) without
        // touching the token's routes to other chains or its enabled flag.
        if (localToken == address(0)) revert ZeroAddress();
        BridgeStorage storage $ = _getBridgeStorage();
        $.remoteToken[localToken][dstCID] = remoteToken_;
    }

    /// @inheritdoc IBridge
    function deployBridgeERC20(
        string memory name_,
        string memory symbol_,
        bytes32 salt
    ) external onlyRole(ADMIN_ROLE) returns (address localToken) {
        BridgeStorage storage $ = _getBridgeStorage();
        bytes memory init = abi.encodeCall(BridgeERC20.initialize, (name_, symbol_, address(this)));
        localToken = address(new BeaconProxy{salt: salt}($.bridgeERC20Beacon, init));
    }

    /// @inheritdoc IBridge
    function setSpamControl(address token, TokenSpamControl calldata cfg) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        // Combined cap: bps alone must not be able to exceed the inbound amount.
        if (uint256(cfg.proposerFeeBps) + uint256(cfg.keeperFeeBps) > MAX_FEE_BPS) revert FeeBpsTooHigh();
        if (cfg.proposerFeeMin > cfg.proposerFeeMax) revert InvalidFeeBounds();
        if (cfg.keeperFeeMin > cfg.keeperFeeMax) revert InvalidFeeBounds();

        BridgeStorage storage $ = _getBridgeStorage();
        $.spamControl[token] = cfg;
        emit SpamControlUpdated(token, cfg);
    }

    // ============= Views =============

    /// @inheritdoc IBridge
    function localChainID() external view returns (uint64) {
        return uint64(block.chainid);
    }

    /// @inheritdoc IBridge
    function lastParkedNonce(
        uint64 srcCID
    ) external view returns (uint64) {
        return _getBridgeStorage().lastParkedNonce[srcCID];
    }

    /// @inheritdoc IBridge
    function previewDeliver(
        uint64 srcCID,
        uint64 nonce
    ) external view returns (bool deliverable, uint256 toRecipient, uint256 proposerFee, uint256 keeperFee) {
        BridgeStorage storage $ = _getBridgeStorage();
        if ($.inboundConsumed[srcCID][nonce] || !$.hasPending[srcCID][nonce]) {
            return (false, 0, 0, 0);
        }
        InboundMessage memory m = $.pendingMessages[srcCID][nonce];
        TokenSpamControl memory s = $.spamControl[m.localToken];
        proposerFee = _computeFee(m.amount, s.proposerFeeBps, s.proposerFeeMin, s.proposerFeeMax);
        keeperFee = _computeFee(m.amount, s.keeperFeeBps, s.keeperFeeMin, s.keeperFeeMax);
        if (m.feeRecipient == address(0)) proposerFee = 0;
        if (proposerFee + keeperFee >= m.amount) {
            return (false, 0, 0, 0);
        }
        return (true, m.amount - proposerFee - keeperFee, proposerFee, keeperFee);
    }

    /// @inheritdoc IBridge
    function tokenConfig(
        address localToken
    ) external view returns (bool enabled, BridgeMode mode) {
        TokenConfig memory cfg = _getBridgeStorage().tokens[localToken];
        return (cfg.enabled, cfg.mode);
    }

    /// @inheritdoc IBridge
    function remoteToken(address localToken, uint64 dstCID) external view returns (address) {
        return _getBridgeStorage().remoteToken[localToken][dstCID];
    }

    /// @inheritdoc IBridge
    function outboundNonce(
        uint64 dstCID
    ) external view returns (uint64) {
        return _getBridgeStorage().outboundNonce[dstCID];
    }

    /// @inheritdoc IBridge
    function inboundConsumed(uint64 srcCID, uint64 nonce) external view returns (bool) {
        return _getBridgeStorage().inboundConsumed[srcCID][nonce];
    }

    /// @inheritdoc IBridge
    function pendingMessage(uint64 srcCID, uint64 nonce) external view returns (InboundMessage memory) {
        return _getBridgeStorage().pendingMessages[srcCID][nonce];
    }

    /// @inheritdoc IBridge
    function spamControl(
        address token
    ) external view returns (TokenSpamControl memory) {
        return _getBridgeStorage().spamControl[token];
    }

    /// @notice Returns the BridgeERC20 beacon address (read helper, not in IBridge interface).
    function bridgeERC20Beacon() external view returns (address) {
        return _getBridgeStorage().bridgeERC20Beacon;
    }

    /// @notice Returns the agency address granted ADMIN_ROLE.
    function agency() external view returns (address) {
        return _getBridgeStorage().agency;
    }
}
