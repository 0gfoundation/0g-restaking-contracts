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
 *      System flow: CL → EL → SYSTEM_ADDRESS calls `executeRemoteMessages` with decoded
 *      `InboundMessage[]`. Each message is dispatched via try/catch (self external call) so failures
 *      land in `pendingMessages` and don't abort the entire system call. Anyone can later call
 *      `retry` to reattempt a failed message.
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

    /// @notice Hard cap on `feeBps` accepted by `setSpamControl`. 10000 = 100% — fees up to
    ///         (but not equal to) the full inbound amount are allowed. A fee equal to or
    ///         exceeding the inbound amount reverts `FeeExceedsAmount` and lands the message
    ///         in `pendingMessages` for retry once admin rebalances spam config.
    uint16 public constant MAX_FEE_BPS = 10_000;

    /// @notice Per-message gas ceiling for the batched `executeRemoteMessages` system call.
    ///         Each inbound message is dispatched via `executeOneInternal{gas: PER_MESSAGE_GAS_CAP}`
    ///         so one message can never drain the whole 30M system-call budget. This matters because
    ///         a failing token call backed by a stateful precompile (e.g. W0G mint over its cap)
    ///         returns a precompile *error* — which the EVM treats as an exceptional halt that
    ///         consumes ALL gas forwarded to it, not a refunding revert. Without this ceiling, two
    ///         such failures in one block would exhaust the 30M and revert the entire system call,
    ///         leaving every message in the block neither delivered nor parked (the CL nonce
    ///         watermark having already advanced) — i.e. unrecoverable. With the ceiling, each
    ///         failure burns at most this much and lands in `pendingMessages` for retry.
    ///
    ///         Sizing: the most expensive *successful* message measured is a W0G MintBurn with a
    ///         fee (two 100k precompile mints + overhead ≈ 268k); 400k leaves headroom for the
    ///         63/64 call-forwarding haircut and cold-access variance. The block budget
    ///         (MaxBridgeMessagesPerBlock = 48, enforced by the CL builder + EL decoder) is chosen
    ///         so worst case 48 × (400k + ~140k struct-park + overhead) ≈ 26.4M < 30M.
    ///
    ///         NOTE: the cap is applied ONLY on the batched system-call path. `retry` is a
    ///         user-funded single-message tx and forwards all available gas, so a message that
    ///         genuinely needs more than this ceiling still has an uncapped recovery path.
    uint256 public constant PER_MESSAGE_GAS_CAP = 400_000;

    /// @notice Per-token bridge configuration. Schema-frozen (only enabled flag + mode).
    struct TokenConfig {
        /// When false, both user paths and destination-side delivery revert. Disabling preserves
        /// `mode` so a future re-enable doesn't accidentally switch the token's escrow semantics.
        bool enabled;
        /// LockRelease (escrow on source / release from bridge balance on dest) or MintBurn (burn on
        /// source / mint on dest via MINTER_ROLE). Mode may differ per chain for the same asset.
        BridgeMode mode;
    }

    /// @notice Per-token anti-spam controls.
    /// @dev Two orthogonal knobs stored together for storage-layout convenience: `minCrossOutAmount`
    ///      gates the source side, the `fee*` triple gates the destination side. Each chain stores
    ///      both groups because the same token can be source on one route and destination on another.
    struct TokenSpamControl {
        /// Source-side floor on user-path `amount`. `lockAndSend` / `burnAndSend` revert with
        /// `AmountTooSmall` if `amount < minCrossOutAmount`. Zero disables the floor.
        uint256 minCrossOutAmount;
        /// Destination-side fee rate in basis points (10_000 = 100%), capped by `MAX_FEE_BPS`. Raw
        /// fee is `(amount * feeBps) / 10_000`, then clamped to `[feeMin, feeMax]`.
        uint16 feeBps;
        /// Destination-side floor on the clamped fee. Raw bps fee below this is rounded up to `feeMin`.
        uint256 feeMin;
        /// Destination-side ceiling on the clamped fee. Raw bps fee above this is capped at `feeMax`.
        /// Must satisfy `feeMin <= feeMax`.
        uint256 feeMax;
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
        /// srcCID => nonce => message awaiting permissionless retry. Populated when a delivery
        /// reverts inside `executeOneInternal` (e.g. mint-cap insufficiency); cleared on successful
        /// `retry`. `inboundConsumed` stays false for these so retry can re-attempt delivery.
        mapping(uint64 => mapping(uint64 => InboundMessage)) pendingMessages;
        /// srcCID => nonce => exists-flag for `pendingMessages`. Needed because reading a default-zero
        /// `InboundMessage` from the map can't be distinguished from a real all-zero message.
        mapping(uint64 => mapping(uint64 => bool)) hasPending;
        /// localToken => spam-control knobs. Empty entry means no source-side floor and no
        /// destination-side fee (delivers the full inbound `amount` to `recipient`).
        mapping(address => TokenSpamControl) spamControl;
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
    ///      destination-side inside `executeRemoteMessages`, paid out of the inbound `amount` to the
    ///      destination block proposer.
    function lockAndSend(address token, uint64 dstCID, address recipient, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountTooSmall();
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

    /// @dev Compute the destination-side fee for an inbound `amount` against `s`. The bps fee is
    ///      `(amount * feeBps) / 10_000`, then clamped to `[feeMin, feeMax]`. Returns 0 when no fee
    ///      knob is configured (`feeBps == 0 && feeMin == 0`). Reverts with `FeeExceedsAmount` if
    ///      the clamped fee would consume the entire amount — the destination admin can fix the
    ///      misconfiguration and the message can then be retried via `Bridge.retry`.
    function _computeFee(uint256 amount, TokenSpamControl memory s) internal pure returns (uint256 fee) {
        if (s.feeBps == 0 && s.feeMin == 0) return 0;
        fee = (amount * s.feeBps) / 10_000;
        if (fee < s.feeMin) fee = s.feeMin;
        if (fee > s.feeMax) fee = s.feeMax;
        if (fee >= amount) revert FeeExceedsAmount();
    }

    // ============= System path =============

    /// @inheritdoc IBridge
    function executeRemoteMessages(
        InboundMessage[] calldata msgs
    ) external nonReentrant {
        if (msg.sender != SYSTEM_ADDRESS) revert NotSystemCaller();
        BridgeStorage storage $ = _getBridgeStorage();
        uint256 n = msgs.length;
        for (uint256 i = 0; i < n; ++i) {
            InboundMessage calldata m = msgs[i];
            if ($.inboundConsumed[m.srcChainID][m.nonce]) {
                emit BridgeMessageFailed(m.srcChainID, m.nonce, bytes("replay"));
                continue;
            }
            _tryDispatch(m);
        }
    }

    // ============= Permissionless retry =============

    /// @inheritdoc IBridge
    function retry(uint64 srcCID, uint64 nonce) external nonReentrant {
        BridgeStorage storage $ = _getBridgeStorage();
        if (!$.hasPending[srcCID][nonce]) revert NoPendingMessage();
        if ($.inboundConsumed[srcCID][nonce]) revert AlreadyConsumed();

        InboundMessage memory stored = $.pendingMessages[srcCID][nonce];
        try this.executeOneInternal(stored) returns (uint256 toRecipient, address feeRecipient, uint256 fee) {
            $.inboundConsumed[srcCID][nonce] = true;
            delete $.pendingMessages[srcCID][nonce];
            $.hasPending[srcCID][nonce] = false;
            emit BridgeIn(srcCID, nonce, stored.localToken, stored.recipient, toRecipient, feeRecipient, fee);
            emit BridgeMessageRetried(srcCID, nonce, true);
        } catch (bytes memory reason) {
            emit BridgeMessageFailed(srcCID, nonce, reason);
            emit BridgeMessageRetried(srcCID, nonce, false);
        }
    }

    /// @inheritdoc IBridge
    /// @dev Externally-callable for try/catch. Reverts unless caller is the bridge itself.
    ///      Splits inbound `amount` into `toRecipient` (for `m.recipient`) and `fee` (for
    ///      `m.feeRecipient`, the destination block proposer's withdrawal address injected by
    ///      the EL). The fee leg is skipped when the destination has no fee configured for
    ///      `localToken` or when `m.feeRecipient` is the zero address — in those cases the
    ///      recipient gets the entire `amount`, `feeRecipient` returns as `address(0)`, and
    ///      `fee` returns as 0. The returned tuple is consumed by the wrapping `try` block to
    ///      emit `BridgeIn` without recomputing the split.
    function executeOneInternal(
        InboundMessage calldata m
    ) external returns (uint256 toRecipient, address feeRecipient, uint256 fee) {
        if (msg.sender != address(this)) revert OnlySelf();
        BridgeStorage storage $ = _getBridgeStorage();
        TokenConfig memory cfg = $.tokens[m.localToken];
        // Bubble up to the outer try/catch as `Error("disabled")` so BridgeMessageFailed.reason
        // carries the ABI-encoded string downstream consumers (CL/EL, explorer) can decode.
        if (!cfg.enabled) revert("disabled");

        TokenSpamControl memory s = $.spamControl[m.localToken];
        fee = _computeFee(m.amount, s);
        bool payFee = fee > 0 && m.feeRecipient != address(0);
        if (payFee) {
            toRecipient = m.amount - fee;
            feeRecipient = m.feeRecipient;
        } else {
            toRecipient = m.amount;
            feeRecipient = address(0);
            fee = 0;
        }

        if (cfg.mode == BridgeMode.MintBurn) {
            IBurnable(m.localToken).mint(m.recipient, toRecipient);
            if (payFee) {
                IBurnable(m.localToken).mint(feeRecipient, fee);
            }
        } else {
            IERC20(m.localToken).safeTransfer(m.recipient, toRecipient);
            if (payFee) {
                IERC20(m.localToken).safeTransfer(feeRecipient, fee);
            }
        }
    }

    /// @dev Wrap an InboundMessage execution in try/catch and route success/failure to storage.
    function _tryDispatch(
        InboundMessage calldata m
    ) internal {
        BridgeStorage storage $ = _getBridgeStorage();
        try this.executeOneInternal{gas: PER_MESSAGE_GAS_CAP}(m) returns (
            uint256 toRecipient, address feeRecipient, uint256 fee
        ) {
            $.inboundConsumed[m.srcChainID][m.nonce] = true;
            // Wipe any stale pending entry (defensive — should be impossible under CL nonce rules).
            if ($.hasPending[m.srcChainID][m.nonce]) {
                delete $.pendingMessages[m.srcChainID][m.nonce];
                $.hasPending[m.srcChainID][m.nonce] = false;
            }
            emit BridgeIn(m.srcChainID, m.nonce, m.localToken, m.recipient, toRecipient, feeRecipient, fee);
        } catch (bytes memory reason) {
            $.pendingMessages[m.srcChainID][m.nonce] = m;
            $.hasPending[m.srcChainID][m.nonce] = true;
            emit BridgeMessageFailed(m.srcChainID, m.nonce, reason);
        }
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
        if (localToken == address(0) || remoteToken_ == address(0)) revert ZeroAddress();
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
    function setSpamControl(
        address token,
        uint256 minCrossOutAmount,
        uint16 feeBps,
        uint256 feeMin,
        uint256 feeMax
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (feeBps > MAX_FEE_BPS) revert FeeBpsTooHigh();
        if (feeMin > feeMax) revert InvalidFeeBounds();

        BridgeStorage storage $ = _getBridgeStorage();
        $.spamControl[token] =
            TokenSpamControl({minCrossOutAmount: minCrossOutAmount, feeBps: feeBps, feeMin: feeMin, feeMax: feeMax});
        emit SpamControlUpdated(token, minCrossOutAmount, feeBps, feeMin, feeMax);
    }

    // ============= Views =============

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
    ) external view returns (uint256 minCrossOutAmount, uint16 feeBps, uint256 feeMin, uint256 feeMax) {
        TokenSpamControl memory s = _getBridgeStorage().spamControl[token];
        return (s.minCrossOutAmount, s.feeBps, s.feeMin, s.feeMax);
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
