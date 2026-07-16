// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {IBridge} from "../src/bridge/IBridge.sol";

/// @notice Cross-language calldata fixture: pins the exact ABI encoding of a one-element
///         `parkRemoteMessages(InboundMessage[])` call so the reth-side bridge encoder and this
///         Solidity ABI agree byte-for-byte. The hardcoded values here MUST match the reth-side
///         encoding test verbatim. The point is to lock the struct's field ORDER and TYPES:
///         a (uint64,uint64,address,address,uint256,address) tuple where srcChainID/nonce are the
///         two uint64s and localToken/recipient/feeRecipient are the three addresses. Swapping any
///         same-width pair (uint64↔uint64 or address↔address) would not change the function
///         selector, so only a full decode-and-assert catches it.
contract BridgeCalldataFixtureTest is Test {
    /// @dev Fixed cross-language test vector (shared with the reth `0g-bridge` encoder test).
    uint64 internal constant SRC_CHAIN_ID = 16_601;
    uint64 internal constant NONCE = 42;
    address internal constant LOCAL_TOKEN = 0x1111111111111111111111111111111111111111;
    address internal constant RECIPIENT = 0x2222222222222222222222222222222222222222;
    uint256 internal constant AMOUNT = 1_000_000_000_000_000_000; // 1e18
    address internal constant FEE_RECIPIENT = 0x3333333333333333333333333333333333333333;

    /// @dev `parkRemoteMessages((uint64,uint64,address,address,uint256,address)[])` selector.
    bytes4 internal constant PARK_SELECTOR = 0x7c31c30f;

    /// @dev Canonical calldata for a single-element array carrying the fixed vector above. Produced
    ///      by `cast calldata "parkRemoteMessages((uint64,uint64,address,address,uint256,address)[])"
    ///      "[(16601,42,0x1111…,0x2222…,1000000000000000000,0x3333…)]"`. Layout:
    ///        [0x00] selector 0x7c31c30f
    ///        [0x04] head: offset to the array              = 0x20
    ///        [0x24] array length                           = 1
    ///        [0x44] srcChainID                             = 16601 (0x40d9)
    ///        [0x64] nonce                                  = 42 (0x2a)
    ///        [0x84] localToken                             = 0x1111…1111
    ///        [0xa4] recipient                              = 0x2222…2222
    ///        [0xc4] amount                                 = 1e18 (0x0de0b6b3a7640000)
    ///        [0xe4] feeRecipient                           = 0x3333…3333
    bytes internal constant FIXTURE_CALLDATA = hex"7c31c30f"
        hex"0000000000000000000000000000000000000000000000000000000000000020"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"00000000000000000000000000000000000000000000000000000000000040d9"
        hex"000000000000000000000000000000000000000000000000000000000000002a"
        hex"0000000000000000000000001111111111111111111111111111111111111111"
        hex"0000000000000000000000002222222222222222222222222222222222222222"
        hex"0000000000000000000000000000000000000000000000000de0b6b3a7640000"
        hex"0000000000000000000000003333333333333333333333333333333333333333";

    /// @notice The hardcoded fixture equals what `abi.encodeWithSelector` produces from the struct,
    ///         so the constant can't silently drift from the live ABI.
    function test_fixture_matchesLiveEncoding() public pure {
        IBridge.InboundMessage[] memory msgs = new IBridge.InboundMessage[](1);
        msgs[0] = IBridge.InboundMessage({
            srcChainID: SRC_CHAIN_ID,
            nonce: NONCE,
            localToken: LOCAL_TOKEN,
            recipient: RECIPIENT,
            amount: AMOUNT,
            feeRecipient: FEE_RECIPIENT
        });
        bytes memory encoded = abi.encodeWithSelector(IBridge.parkRemoteMessages.selector, msgs);
        assertEq(IBridge.parkRemoteMessages.selector, PARK_SELECTOR, "selector pinned");
        assertEq(keccak256(encoded), keccak256(FIXTURE_CALLDATA), "live encoding must match fixture bytes");
    }

    /// @notice Decoding the fixture (after stripping the 4-byte selector) recovers every field with
    ///         the exact value and in the exact slot. This is the check that distinguishes the
    ///         field order/types from any same-width permutation.
    function test_fixture_decodesToExpectedFields() public pure {
        // First word of calldata is the selector; assert it, then strip and decode the tail.
        assertEq(bytes4(FIXTURE_CALLDATA), PARK_SELECTOR, "selector must be parkRemoteMessages");

        bytes memory body = new bytes(FIXTURE_CALLDATA.length - 4);
        for (uint256 i = 0; i < body.length; ++i) {
            body[i] = FIXTURE_CALLDATA[i + 4];
        }

        IBridge.InboundMessage[] memory decoded = abi.decode(body, (IBridge.InboundMessage[]));
        assertEq(decoded.length, 1, "single-element array");

        IBridge.InboundMessage memory m = decoded[0];
        assertEq(m.srcChainID, SRC_CHAIN_ID, "srcChainID");
        assertEq(m.nonce, NONCE, "nonce");
        assertEq(m.localToken, LOCAL_TOKEN, "localToken");
        assertEq(m.recipient, RECIPIENT, "recipient");
        assertEq(m.amount, AMOUNT, "amount");
        assertEq(m.feeRecipient, FEE_RECIPIENT, "feeRecipient");
    }
}
