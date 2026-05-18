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

    /// @notice Hard cap on `feeBps` accepted by `setSpamControl`. 10000 = 100%.
    /// @dev Documented in plan §1.5.4 — protects users against a misconfigured agency.
    uint16 public constant MAX_FEE_BPS = 10000;

    /// @notice Per-token bridge configuration. Schema-frozen (only enabled flag + mode).
    struct TokenConfig {
        bool enabled;
        BridgeMode mode;
    }

    /// @notice Per-token anti-spam controls.
    /// @dev Two orthogonal knobs stored together for storage layout convenience:
    ///        - `minCrossOutAmount` is source-side: `lockAndSend` / `burnAndSend` reject inputs below this.
    ///        - `feeBps / feeMin / feeMax` are destination-side: applied inside
    ///          `executeRemoteMessages`, where the inbound `amount` is split between the recipient
    ///          and the EL-injected proposer fee recipient.
    ///      `feeBps` is basis-points (10_000 = 100%) and capped by `MAX_FEE_BPS`.
    ///      Fee is computed as `(amount * feeBps) / 10_000`, then clamped to `[feeMin, feeMax]`.
    struct TokenSpamControl {
        uint256 minCrossOutAmount;
        uint16 feeBps;
        uint256 feeMin;
        uint256 feeMax;
    }

    /// @custom:storage-location erc7201:0g.bridge.Bridge
    struct BridgeStorage {
        address bridgeERC20Beacon;
        address agency;
        mapping(address => TokenConfig) tokens;
        mapping(address => mapping(uint64 => address)) remoteToken;
        mapping(uint64 => uint64) outboundNonce;
        mapping(uint64 => mapping(uint64 => bool)) inboundConsumed;
        mapping(uint64 => mapping(uint64 => InboundMessage)) pendingMessages;
        mapping(uint64 => mapping(uint64 => bool)) hasPending;
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
    /// @dev `localChainID` is no longer stored — it is derived from `block.chainid` at every read,
    ///      which is by definition equal to the EL chainID at runtime and cannot drift.
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
        if (block.chainid > type(uint64).max) revert ChainIDOverflow();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, agency_);

        BridgeStorage storage $ = _getBridgeStorage();
        $.bridgeERC20Beacon = bridgeERC20Beacon_;
        $.agency = agency_;
    }

    /// @dev Returns this chain's chainID as a `uint64`, fetched from `block.chainid` and
    ///      narrowed. Reverts if the chainID exceeds u64 (schema-mandated wire width).
    function _localChainID() internal view returns (uint64) {
        if (block.chainid > type(uint64).max) revert ChainIDOverflow();
        return uint64(block.chainid);
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

        _applyAntiSpam($, token, amount);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint64 nonce = ++$.outboundNonce[dstCID];
        emit BridgeOut(
            _localChainID(), dstCID, nonce, token, $.remoteToken[token][dstCID], recipient, amount, uint8(cfg.mode)
        );
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

        _applyAntiSpam($, token, amount);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IBurnable(token).burn(amount);
        uint64 nonce = ++$.outboundNonce[dstCID];
        emit BridgeOut(
            _localChainID(), dstCID, nonce, token, $.remoteToken[token][dstCID], recipient, amount, uint8(cfg.mode)
        );
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
        bool ok;
        bytes memory reason;
        try this.executeOneInternal(stored) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        if (ok) {
            $.inboundConsumed[srcCID][nonce] = true;
            delete $.pendingMessages[srcCID][nonce];
            $.hasPending[srcCID][nonce] = false;
            (uint256 toRecipient, address feeRecipient, uint256 fee) =
                _splitInboundAmount(stored.localToken, stored.amount, stored.feeRecipient);
            emit BridgeIn(srcCID, nonce, stored.localToken, stored.recipient, toRecipient, feeRecipient, fee);
            emit BridgeMessageRetried(srcCID, nonce, true);
        } else {
            emit BridgeMessageFailed(srcCID, nonce, reason);
            emit BridgeMessageRetried(srcCID, nonce, false);
        }
    }

    /// @inheritdoc IBridge
    /// @dev Externally-callable for try/catch. Reverts unless caller is the bridge itself.
    ///      Splits inbound `amount` into `(amount - fee)` for `m.recipient` and `fee` for
    ///      `m.feeRecipient` (the destination block proposer's withdrawal address, injected by the
    ///      EL). The fee leg is skipped when the destination has no fee configured for `localToken`
    ///      or when `m.feeRecipient` is the zero address.
    function executeOneInternal(
        InboundMessage calldata m
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BridgeStorage storage $ = _getBridgeStorage();
        TokenConfig memory cfg = $.tokens[m.localToken];
        if (!cfg.enabled) {
            // bubble up an ASCII reason that matches the schema's failure-reason convention.
            assembly {
                mstore(0x00, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(0x04, 0x20) // string offset
                mstore(0x24, 0x08) // length 8
                mstore(0x44, "disabled")
                revert(0x00, 0x64)
            }
        }
        TokenSpamControl memory s = $.spamControl[m.localToken];
        uint256 fee = _computeFee(m.amount, s);
        bool payFee = fee > 0 && m.feeRecipient != address(0);
        // When the fee leg is skipped (no spam config OR `feeRecipient == 0x0`), the recipient
        // receives the entire inbound `amount` so no value is "stuck". The split is only applied
        // when both a fee is configured and the EL injected a non-zero fee recipient.
        uint256 toRecipient = payFee ? m.amount - fee : m.amount;

        if (cfg.mode == BridgeMode.MintBurn) {
            IBurnable(m.localToken).mint(m.recipient, toRecipient);
            if (payFee) {
                IBurnable(m.localToken).mint(m.feeRecipient, fee);
            }
        } else {
            IERC20(m.localToken).safeTransfer(m.recipient, toRecipient);
            if (payFee) {
                IERC20(m.localToken).safeTransfer(m.feeRecipient, fee);
            }
        }
    }

    /// @dev Wrap an InboundMessage execution in try/catch and route success/failure to storage.
    function _tryDispatch(
        InboundMessage calldata m
    ) internal {
        BridgeStorage storage $ = _getBridgeStorage();
        bool ok;
        bytes memory reason;
        try this.executeOneInternal(m) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        if (ok) {
            $.inboundConsumed[m.srcChainID][m.nonce] = true;
            // Wipe any stale pending entry (defensive — should be impossible under CL nonce rules).
            if ($.hasPending[m.srcChainID][m.nonce]) {
                delete $.pendingMessages[m.srcChainID][m.nonce];
                $.hasPending[m.srcChainID][m.nonce] = false;
            }
            (uint256 toRecipient, address feeRecipient, uint256 fee) =
                _splitInboundAmount(m.localToken, m.amount, m.feeRecipient);
            emit BridgeIn(m.srcChainID, m.nonce, m.localToken, m.recipient, toRecipient, feeRecipient, fee);
        } else {
            $.pendingMessages[m.srcChainID][m.nonce] = m;
            $.hasPending[m.srcChainID][m.nonce] = true;
            emit BridgeMessageFailed(m.srcChainID, m.nonce, reason);
        }
    }

    /// @dev Recompute the (toRecipient, feeRecipient, fee) split for event emission. Mirrors the
    ///      logic inside `executeOneInternal`. Pure recomputation is preferred over passing the
    ///      values out of the try/catch boundary because the dispatch happens via external
    ///      self-call (which can only return ABI-encoded results, not multi-value tuples
    ///      through the catch path).
    function _splitInboundAmount(
        address localToken,
        uint256 amount,
        address msgFeeRecipient
    ) internal view returns (uint256 toRecipient, address feeRecipient, uint256 fee) {
        TokenSpamControl memory s = _getBridgeStorage().spamControl[localToken];
        fee = _computeFee(amount, s);
        if (fee > 0 && msgFeeRecipient != address(0)) {
            toRecipient = amount - fee;
            feeRecipient = msgFeeRecipient;
        } else {
            toRecipient = amount;
            feeRecipient = address(0);
            fee = 0;
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
        if (localToken == address(0)) revert ZeroAddress();
        BridgeStorage storage $ = _getBridgeStorage();
        $.remoteToken[localToken][dstCID] = remoteToken_;
    }

    /// @inheritdoc IBridge
    function deployBridgeERC20(
        string memory name_,
        string memory symbol_
    ) external onlyRole(ADMIN_ROLE) returns (address localToken) {
        BridgeStorage storage $ = _getBridgeStorage();
        bytes memory init = abi.encodeCall(BridgeERC20.initialize, (name_, symbol_, address(this)));
        localToken = address(new BeaconProxy($.bridgeERC20Beacon, init));
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
    function localChainID() external view returns (uint64) {
        return _localChainID();
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
