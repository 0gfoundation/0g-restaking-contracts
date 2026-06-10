// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IBridge
 * @notice Interface for the 0G cross-chain bridge contract deployed at a fixed address on every 0G chain.
 * @dev Schema is frozen — fields and binary layout must not change without cross-stream review (CL + EL + contracts).
 *      Destination-side flow is park-then-deliver: the consensus-driven system call only *parks* inbound
 *      messages (`parkRemoteMessages`, no token movement, no events), and anyone can later *deliver* them
 *      via normal transactions (`deliver` / `deliverBatch`) whose token transfers and `BridgeIn` events are
 *      fully visible to receipts / `eth_getLogs`.
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
    ///      dispatcher per block, equal to `block.coinbase` (proposer withdrawal address). It is stored
    ///      inside the parked message and paid the destination-side fee at deliver time.
    struct InboundMessage {
        /// Source chain's `chainId` (the chain that emitted the originating `BridgeOut`).
        uint64 srcChainID;
        /// Per-(srcCID, dstCID) outbound nonce assigned on the source chain. Monotonic; the CL
        /// state-transition enforces sequential consumption (`nonce == lastNonce + 1`).
        uint64 nonce;
        /// Token address on THIS (destination) chain. The CL poller resolves source-emitted
        /// `remoteToken` to the local mapping before injecting into the SSZ message.
        address localToken;
        /// Beneficiary on this chain. Receives `amount` minus the destination-side fee, paid at
        /// deliver time.
        address recipient;
        /// Full inbound amount before the destination-side fee split (i.e. what the source escrowed
        /// or burned). The split happens at deliver time, against the spam-control config in effect
        /// then — not at park time.
        uint256 amount;
        /// Destination block proposer's withdrawal address, EL-injected per block (equal to
        /// `block.coinbase` post-MinerReward fork). All messages parked in a block share the same
        /// value. `address(0)` means "skip the proposer fee leg"; no value is stuck.
        address feeRecipient;
    }

    // ============= Errors =============

    /// @dev `parkRemoteMessages` was invoked by an account other than `SYSTEM_ADDRESS` (0xfff…fe).
    error NotSystemCaller();

    /// @dev User path called against a token whose `tokens[token].enabled` flag is false.
    error TokenDisabled();

    /// @dev User path called with a mode that does not match `tokens[token].mode`.
    error WrongMode();

    /// @dev `deliver` called for a `(srcCID, nonce)` that has no parked message.
    error NoPendingMessage();

    /// @dev `deliver` called for a `(srcCID, nonce)` whose `inboundConsumed` is already true.
    error AlreadyConsumed();

    /// @dev Self-call dispatch helper invoked by an account other than the bridge itself.
    error OnlySelf();

    /// @dev Configuration setter received the zero address.
    error ZeroAddress();

    /// @dev User-path call's `amount` is below the configured `minCrossOutAmount` for the token.
    error AmountTooSmall();

    /// @dev `setSpamControl` called with a bps total exceeding `MAX_FEE_BPS` (100%).
    error FeeBpsTooHigh();

    /// @dev Destination-side computed (and clamped) fee is greater than or equal to the inbound
    ///      `amount`. Delivery reverts and the message stays parked so the destination admin can
    ///      fix `spamControl` (e.g. lower `feeMin`); then anyone can deliver it.
    error FeeExceedsAmount();

    /// @dev `setSpamControl` called with `feeMin > feeMax`.
    error InvalidFeeBounds();

    /// @dev User path called against a `(token, dstCID)` pair with no remote-token mapping
    ///      configured. Without the mapping, the emitted `BridgeOut.remoteToken` would be
    ///      `address(0)`, the CL/EL would resolve the destination `localToken` to `address(0)`,
    ///      and the destination message would be permanently non-deliverable (token 0 is always
    ///      disabled and the parked entry can't be repaired by later configuring the
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

    /// @notice Emitted on the destination chain when a parked message is delivered. Emitted by the
    ///         delivery transaction (`deliver` / `deliverBatch`), so it is fully visible to
    ///         receipts / `eth_getLogs` — unlike system-call logs, which the EL discards.
    /// @param srcChainID Source chain that produced the message.
    /// @param nonce Per-(srcCID, dstCID) monotonic nonce.
    /// @param localToken Token address on this destination chain.
    /// @param recipient Final receiver on this chain.
    /// @param amount Net amount delivered to `recipient` (inbound amount minus the fee).
    /// @param feeRecipient Address paid the destination-side fee (block proposer's withdrawal
    ///        address, EL-injected at park time). `address(0)` if no fee was paid out.
    /// @param fee Fee paid to `feeRecipient` (zero if `spamControl` is unconfigured or
    ///        `feeRecipient` is zero).
    event BridgeIn(
        uint64 indexed srcChainID,
        uint64 nonce,
        address localToken,
        address recipient,
        uint256 amount,
        address feeRecipient,
        uint256 fee
    );

    /// @notice Emitted by `deliverBatch` for each message whose delivery attempt failed. The
    ///         message stays parked; later messages in the batch still attempt.
    /// @param reason Failure reason: raw revert bytes forwarded verbatim from the failed delivery.
    ///        May be ABI-encoded `Error(string)` (e.g. `revert("disabled")` for a disabled token),
    ///        a 4-byte custom-error selector + args (e.g. this contract's `FeeExceedsAmount()` /
    ///        `NoPendingMessage()` / `AlreadyConsumed()`), upstream token / precompile revert
    ///        bytes, or empty bytes.
    event BridgeMessageFailed(uint64 indexed srcChainID, uint64 nonce, bytes reason);

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

    /// @notice Park a batch of inbound messages for later permissionless delivery.
    /// @dev Caller must be `SYSTEM_ADDRESS = 0xfff…ffe`; that gate is the ONLY revert path — the
    ///      loop body cannot revert, so a full batch always commits within the system-call budget.
    ///      Per message: skip if already consumed or already parked (defensive idempotency — the
    ///      CL nonce watermark prevents duplicates reaching the contract); otherwise store it in
    ///      `pendingMessages` and advance `lastParkedNonce[srcCID]` (monotonic max). NO token
    ///      calls, NO fee math, NO events (system-call logs are discarded by the EL).
    function parkRemoteMessages(
        InboundMessage[] calldata msgs
    ) external;

    // ============= Permissionless delivery =============

    /// @notice Deliver a single parked message: compute the destination-side fee, move tokens,
    ///         mark consumed, emit `BridgeIn`.
    /// @dev Anyone may call; forwards all gas; reverts with the underlying reason on failure
    ///      (the message stays parked).
    function deliver(uint64 srcCID, uint64 nonce) external;

    /// @notice Deliver a batch of parked messages with per-message try/catch isolation: a failed
    ///         message emits `BridgeMessageFailed` and stays parked while later ones still attempt.
    /// @dev Anyone may call. There is deliberately NO per-message gas cap — the caller pays for
    ///      the whole batch and bears the gas-burn risk of an exceptionally-halting message (e.g.
    ///      a stateful-precompile failure burns all gas forwarded to the token call). Use
    ///      `previewDeliver` to pre-filter, and size batches accordingly.
    function deliverBatch(uint64 srcCID, uint64[] calldata nonces) external;

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
    ///        - `feeBps / feeMin / feeMax` are applied destination-side at deliver time, splitting
    ///          the inbound `amount` between the recipient and the parked message's `feeRecipient`
    ///          (the block proposer's withdrawal address, EL-injected at park time).
    ///      Setting all fields to zero disables the controls for the token. Note that `feeMax`
    ///      is a hard cap on the computed fee: with `feeMax == 0` the fee is always 0 even if
    ///      `feeBps` / `feeMin` are nonzero, so charging any fee requires a nonzero `feeMax`.
    /// @param token Token to configure (any registered local token, regardless of mode).
    /// @param minCrossOutAmount Reject `lockAndSend` / `burnAndSend` whose `amount` is strictly less.
    /// @param feeBps Basis-points fee on inbound `amount`. Capped at `MAX_FEE_BPS` (10000 = 100%).
    /// @param feeMin Floor on the computed fee (acts as a flat minimum). Must be `<= feeMax`.
    /// @param feeMax Hard cap on the computed fee. Must be `>= feeMin`. `feeMax == 0` forces the
    ///        fee to 0 regardless of `feeBps` / `feeMin` — set it nonzero to actually charge fees.
    function setSpamControl(
        address token,
        uint256 minCrossOutAmount,
        uint16 feeBps,
        uint256 feeMin,
        uint256 feeMax
    ) external;

    // ============= Views =============

    /// @notice This chain's chainID as carried in bridge messages (`uint64(block.chainid)`).
    function localChainID() external view returns (uint64);

    /// @notice Highest nonce ever parked for `srcCID`. Monotonic. Keeper discovery anchor: park
    ///         emits no events, but per-lane nonces are dense, so a keeper tracks its own
    ///         delivered watermark and scans `(watermark, lastParkedNonce[srcCID]]`.
    function lastParkedNonce(
        uint64 srcCID
    ) external view returns (uint64);

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
