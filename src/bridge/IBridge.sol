// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IBridge
 * @notice Interface for the 0G cross-chain bridge contract deployed at a fixed address on every 0G chain.
 * @dev Schema is frozen — fields and binary layout must not change without cross-stream review (CL + EL + contracts).
 */
interface IBridge {
    /// @notice Bridging mode for a registered token.
    /// @dev LockRelease (0): tokens are escrowed on the source chain via transferFrom and released
    ///      from the bridge's pool on the destination chain. MintBurn (1): tokens are burned on the
    ///      source chain and minted on the destination chain. Values are wire-pinned (0/1).
    enum BridgeMode {
        LockRelease,
        MintBurn
    }

    /// @notice Inbound message ABI struct, decoded from CL `BridgeMessage` SSZ on the destination side.
    /// @dev Field order is wire-pinned and MUST mirror the EL-side encoder in the bridge crate of 0g-reth.
    struct InboundMessage {
        uint64 srcChainID;
        uint64 nonce;
        address localToken;
        address recipient;
        uint256 amount;
    }

    // ============= Errors =============

    /// @dev `executeRemoteMessages` was invoked by an account other than `SYSTEM_ADDRESS` (0xfff…fe).
    error NotSystemCaller();

    /// @dev User path called against a token whose `tokens[token].enabled` flag is false.
    error TokenDisabled();

    /// @dev User path called with a mode that does not match `tokens[token].mode`.
    error WrongMode();

    /// @dev `retry` called for a `(srcCID, nonce)` that has no pending message.
    error NoPendingMessage();

    /// @dev `retry` called for a `(srcCID, nonce)` whose `inboundConsumed` is already true.
    error AlreadyConsumed();

    /// @dev `executeOneInternal` called by an account other than the bridge itself.
    error OnlySelf();

    /// @dev Configuration setter received the zero address.
    error ZeroAddress();

    /// @dev User-path call's `amount` is below the configured `minCrossOutAmount` for the token.
    error AmountTooSmall();

    /// @dev `setSpamControl` called with `feeBps` exceeding `MAX_FEE_BPS` (20%).
    error FeeBpsTooHigh();

    /// @dev Computed (and clamped) fee is greater than or equal to the user's `amount`, leaving
    ///      nothing to bridge after the fee deduction.
    error FeeExceedsAmount();

    /// @dev `setSpamControl` called with `feeMin > feeMax`.
    error InvalidFeeBounds();

    /// @dev `setSpamControl` called with `mode == LockRelease`, `feeRecipient == address(0)`, and
    ///      a non-zero fee. Such a configuration would lock fee tokens in the bridge with no
    ///      admin sweep path. Use a non-zero `feeRecipient` or set both `feeBps` and `feeMin` to
    ///      zero to disable the fee.
    error InvalidLockReleaseFeeConfig();

    /// @dev `block.chainid` exceeds `type(uint64).max`. The schema pins `srcChainID` / `dstChainID`
    ///      to u64 on the wire; this guards the narrowing cast in user paths.
    error ChainIDOverflow();

    // ============= Events =============

    /// @notice Emitted on the source chain when a user initiates a bridge transfer.
    /// @param srcChainID Source chain's `chainId` (this chain).
    /// @param dstChainID Destination chain's `chainId`.
    /// @param nonce Source-chain monotonic nonce, scoped to `dstChainID`.
    /// @param localToken Token address on the source chain.
    /// @param remoteToken Token address on the destination chain (looked up at emit time).
    /// @param recipient Receiver address on the destination chain.
    /// @param amount Transferred amount (uint256).
    /// @param mode Bridging mode of the source-chain token (uint8 cast of `BridgeMode`).
    event BridgeOut(
        uint64 indexed srcChainID,
        uint64 indexed dstChainID,
        uint64 nonce,
        address localToken,
        address remoteToken,
        address recipient,
        uint256 amount,
        uint8 mode
    );

    /// @notice Emitted on the destination chain when a remote message is successfully executed.
    event BridgeIn(uint64 indexed srcChainID, uint64 nonce, address localToken, address recipient, uint256 amount);

    /// @notice Emitted on the destination chain when a remote message fails or is a replay.
    /// @param reason ASCII reason like "replay", "disabled", or the upstream revert bytes.
    event BridgeMessageFailed(uint64 indexed srcChainID, uint64 nonce, bytes reason);

    /// @notice Emitted on the destination chain after `retry` is attempted.
    event BridgeMessageRetried(uint64 indexed srcChainID, uint64 nonce, bool success);

    /// @notice Emitted when an admin updates a token's anti-spam controls.
    /// @param token Token whose controls were updated.
    /// @param minCrossOutAmount New minimum cross-out amount.
    /// @param feeBps New basis-points fee.
    /// @param feeMin New floor on the deducted fee.
    /// @param feeMax New cap on the deducted fee.
    /// @param feeRecipient New fee receiver (zero leaves fees in the bridge / burns them).
    event SpamControlUpdated(
        address indexed token,
        uint256 minCrossOutAmount,
        uint16 feeBps,
        uint256 feeMin,
        uint256 feeMax,
        address feeRecipient
    );

    // ============= User paths =============

    /// @notice Lock `amount` of `token` and emit a BridgeOut targeting `dstCID`.
    /// @dev Requires `tokens[token].enabled` and `mode == LockRelease`. Pulls via transferFrom.
    function lockAndSend(address token, uint64 dstCID, address recipient, uint256 amount) external;

    /// @notice Burn `amount` of `token` from `msg.sender` and emit a BridgeOut.
    /// @dev Requires `tokens[token].enabled` and `mode == MintBurn`.
    function burnAndSend(address token, uint64 dstCID, address recipient, uint256 amount) external;

    // ============= System path =============

    /// @notice Execute a batch of inbound messages.
    /// @dev Caller must be `SYSTEM_ADDRESS = 0xfff…ffe`. Per-message try/catch isolates failures
    ///      into `pendingMessages` for permissionless retry.
    function executeRemoteMessages(
        InboundMessage[] calldata msgs
    ) external;

    // ============= Permissionless retry =============

    /// @notice Retry a previously-failed inbound message.
    /// @dev Anyone may call. No-op revert if there is no pending message or it's already consumed.
    function retry(uint64 srcCID, uint64 nonce) external;

    // ============= Self-call helper =============

    /// @notice Internal try/catch dispatch point, exposed externally for try/catch.
    /// @dev Reverts unless `msg.sender == address(this)`.
    function executeOneInternal(
        InboundMessage calldata m
    ) external;

    // ============= Admin (ADMIN_ROLE held by BridgeAgency) =============

    /// @notice Configure a token's enabled flag and bridging mode.
    function configureToken(address localToken, bool enabled, BridgeMode mode) external;

    /// @notice Map `localToken` to its address on `dstCID`.
    function mapRemoteToken(address localToken, uint64 dstCID, address remoteToken_) external;

    /// @notice Deploy a new `BridgeERC20` BeaconProxy off the shared `BridgeERC20Beacon`.
    /// @return localToken Address of the newly deployed BridgeERC20.
    function deployBridgeERC20(string memory name, string memory symbol) external returns (address localToken);

    /// @notice Configure per-token anti-spam controls (minimum amount + per-tx fee).
    /// @dev Only callable by `ADMIN_ROLE` (BridgeAgency). All values are stored verbatim and applied
    ///      to subsequent `lockAndSend` / `burnAndSend` calls. Setting all fields to zero disables
    ///      the controls for the token.
    /// @param token Token to configure (any registered local token, regardless of mode).
    /// @param minCrossOutAmount Reject `lockAndSend` / `burnAndSend` whose `amount` is strictly less.
    /// @param feeBps Basis-points fee on `amount`. Capped at `MAX_FEE_BPS` (2000 = 20%).
    /// @param feeMin Floor on the computed fee (acts as a flat minimum). Must be `<= feeMax`.
    /// @param feeMax Cap on the computed fee. Must be `>= feeMin`.
    /// @param feeRecipient Where collected fees go. If `address(0)`, fees stay in the bridge for
    ///        LockRelease tokens, or are burned alongside the cross-out amount for MintBurn tokens.
    function setSpamControl(
        address token,
        uint256 minCrossOutAmount,
        uint16 feeBps,
        uint256 feeMin,
        uint256 feeMax,
        address feeRecipient
    ) external;

    // ============= Views =============

    function localChainID() external view returns (uint64);
    function tokenConfig(
        address localToken
    ) external view returns (bool enabled, BridgeMode mode);
    function remoteToken(address localToken, uint64 dstCID) external view returns (address);
    function outboundNonce(
        uint64 dstCID
    ) external view returns (uint64);
    function inboundConsumed(uint64 srcCID, uint64 nonce) external view returns (bool);
    function pendingMessage(uint64 srcCID, uint64 nonce) external view returns (InboundMessage memory);

    /// @notice Read the configured anti-spam controls for `token`.
    /// @return minCrossOutAmount Minimum acceptable amount.
    /// @return feeBps Basis-points fee.
    /// @return feeMin Lower clamp on the computed fee.
    /// @return feeMax Upper clamp on the computed fee.
    /// @return feeRecipient Fee destination (zero = stay-in-bridge / burn).
    function spamControl(
        address token
    )
        external
        view
        returns (uint256 minCrossOutAmount, uint16 feeBps, uint256 feeMin, uint256 feeMax, address feeRecipient);
}
