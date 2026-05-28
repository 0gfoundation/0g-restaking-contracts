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
    ///      `feeRecipient` is NOT part of the SSZ wire format — it is injected by the EL system-call
    ///      dispatcher per block, equal to `block.coinbase` (proposer withdrawal address). The
    ///      destination-side fee logic in `executeRemoteMessages` splits `amount` between `recipient`
    ///      and `feeRecipient` according to the destination chain's `spamControl[localToken]` config.
    struct InboundMessage {
        /// Source chain's `chainId` (the chain that emitted the originating `BridgeOut`).
        uint64 srcChainID;
        /// Per-(srcCID, dstCID) outbound nonce assigned on the source chain. Monotonic; the CL
        /// state-transition enforces sequential consumption (`nonce == lastNonce + 1`).
        uint64 nonce;
        /// Token address on THIS (destination) chain. The CL poller resolves source-emitted
        /// `remoteToken` to the local mapping before injecting into the SSZ message.
        address localToken;
        /// Beneficiary on this chain. Receives `amount - fee` after the destination-side fee split.
        address recipient;
        /// Full inbound amount before the destination-side fee split (i.e. what the source escrowed
        /// or burned). The dest splits this into `(recipient: amount-fee, feeRecipient: fee)`.
        uint256 amount;
        /// Destination block proposer's withdrawal address, EL-injected per block (equal to
        /// `block.coinbase` post-MinerReward fork). All messages in a block share the same value.
        /// `address(0)` means "skip fee distribution"; the full `amount` goes to `recipient`.
        address feeRecipient;
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

    /// @dev `setSpamControl` called with `feeBps` exceeding `MAX_FEE_BPS` (100%).
    error FeeBpsTooHigh();

    /// @dev Destination-side computed (and clamped) fee is greater than or equal to the inbound
    ///      `amount`. Reverting blocks delivery so the destination admin can fix `spamControl`
    ///      (e.g. lower `feeMin`) and the message can be retried via `Bridge.retry`.
    error FeeExceedsAmount();

    /// @dev `setSpamControl` called with `feeMin > feeMax`.
    error InvalidFeeBounds();

    /// @dev User path called against a `(token, dstCID)` pair with no remote-token mapping
    ///      configured. Without the mapping, the emitted `BridgeOut.remoteToken` would be
    ///      `address(0)`, the CL/EL would resolve the destination `localToken` to `address(0)`,
    ///      and the destination message would be permanently non-deliverable (token 0 is always
    ///      disabled and the stored pending entry can't be repaired by later configuring the
    ///      source mapping). Reject upfront on the source side.
    error RemoteTokenNotMapped();

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
    /// @param srcChainID Source chain that produced the message.
    /// @param nonce Per-(srcCID, dstCID) monotonic nonce.
    /// @param localToken Token address on this destination chain.
    /// @param recipient Final receiver on this chain.
    /// @param amount Amount delivered to `recipient` (i.e. inbound `amount` minus the destination-side fee).
    /// @param feeRecipient Address that received the fee portion (block proposer's withdrawal address,
    ///        injected by the EL). `address(0)` if no fee was paid out.
    /// @param fee Fee paid to `feeRecipient` (zero if `spamControl` is unconfigured or `feeRecipient` is zero).
    event BridgeIn(
        uint64 indexed srcChainID,
        uint64 nonce,
        address localToken,
        address recipient,
        uint256 amount,
        address feeRecipient,
        uint256 fee
    );

    /// @notice Emitted on the destination chain when a remote message fails or is a replay.
    /// @param reason Failure reason. Three possible encodings depending on origin:
    ///        - Replay (duplicate nonce already consumed): raw ASCII bytes `"replay"`, NO selector.
    ///          This path emits directly without going through try/catch.
    ///        - Disabled-token revert inside `executeOneInternal`: ABI-encoded `Error(string)` from
    ///          `revert("disabled")` — selector `0x08c379a0` + offset + length + ASCII bytes.
    ///        - Any other revert surfaced through try/catch: arbitrary revert bytes forwarded
    ///          verbatim. Includes this contract's own custom errors such as
    ///          `FeeExceedsAmount()` (4-byte selector with no args), as well as upstream
    ///          token / precompile reverts which may be `Error(string)`, a custom-error
    ///          4-byte selector + args, empty bytes, or anything else the failing callee emits.
    event BridgeMessageFailed(uint64 indexed srcChainID, uint64 nonce, bytes reason);

    /// @notice Emitted on the destination chain after `retry` is attempted.
    event BridgeMessageRetried(uint64 indexed srcChainID, uint64 nonce, bool success);

    /// @notice Emitted when an admin updates a token's anti-spam controls.
    /// @param token Token whose controls were updated.
    /// @param minCrossOutAmount New minimum cross-out amount (source-side anti-spam).
    /// @param feeBps New basis-points fee (destination-side fee charged on inbound `amount`).
    /// @param feeMin New floor on the destination-side fee.
    /// @param feeMax New cap on the destination-side fee.
    event SpamControlUpdated(
        address indexed token, uint256 minCrossOutAmount, uint16 feeBps, uint256 feeMin, uint256 feeMax
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
    /// @dev Reverts unless `msg.sender == address(this)`. Returns the destination-side split
    ///      `(toRecipient, feeRecipient, fee)` so callers wrapping this in `try ... returns (...)`
    ///      can emit `BridgeIn` without recomputing the split. When no fee leg is paid (no spam
    ///      config or `m.feeRecipient == 0x0`), `feeRecipient` is `address(0)` and `fee` is 0.
    function executeOneInternal(
        InboundMessage calldata m
    ) external returns (uint256 toRecipient, address feeRecipient, uint256 fee);

    // ============= Admin (ADMIN_ROLE held by BridgeAgency) =============

    /// @notice Configure a token's enabled flag and bridging mode.
    function configureToken(address localToken, bool enabled, BridgeMode mode) external;

    /// @notice Map `localToken` to its address on `dstCID`.
    function mapRemoteToken(address localToken, uint64 dstCID, address remoteToken_) external;

    /// @notice Deploy a new `BridgeERC20` BeaconProxy off the shared `BridgeERC20Beacon`.
    /// @dev Uses CREATE2 with the caller-supplied `salt`. Two chains that share the same
    ///      Bridge contract address (Nick-method genesis deployment) and BridgeERC20Beacon
    ///      address will land the resulting BridgeERC20 at the same address when given the
    ///      same `(name, symbol, salt)` — useful for keeping a bridged token at the same
    ///      address everywhere it's deployed. Reverts if a contract already exists at the
    ///      target address (same `(name, symbol, salt)` used twice on the same chain).
    /// @return localToken Address of the newly deployed BridgeERC20.
    function deployBridgeERC20(
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external returns (address localToken);

    /// @notice Configure per-token anti-spam controls.
    /// @dev Only callable by `ADMIN_ROLE` (BridgeAgency). The four fields are stored verbatim and
    ///      applied independently:
    ///        - `minCrossOutAmount` is enforced source-side by `lockAndSend` / `burnAndSend`.
    ///        - `feeBps / feeMin / feeMax` are applied destination-side inside
    ///          `executeRemoteMessages`, splitting the inbound `amount` between the recipient and
    ///          the EL-injected `feeRecipient` (the block proposer's withdrawal address).
    ///      Setting all fields to zero disables the controls for the token.
    /// @param token Token to configure (any registered local token, regardless of mode).
    /// @param minCrossOutAmount Reject `lockAndSend` / `burnAndSend` whose `amount` is strictly less.
    /// @param feeBps Basis-points fee on inbound `amount`. Capped at `MAX_FEE_BPS` (10000 = 100%).
    /// @param feeMin Floor on the computed fee (acts as a flat minimum). Must be `<= feeMax`.
    /// @param feeMax Cap on the computed fee. Must be `>= feeMin`.
    function setSpamControl(
        address token,
        uint256 minCrossOutAmount,
        uint16 feeBps,
        uint256 feeMin,
        uint256 feeMax
    ) external;

    // ============= Views =============

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
    /// @return minCrossOutAmount Source-side minimum acceptable amount.
    /// @return feeBps Destination-side basis-points fee.
    /// @return feeMin Destination-side floor on the computed fee.
    /// @return feeMax Destination-side cap on the computed fee.
    function spamControl(
        address token
    ) external view returns (uint256 minCrossOutAmount, uint16 feeBps, uint256 feeMin, uint256 feeMax);
}
