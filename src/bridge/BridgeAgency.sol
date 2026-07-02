// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IBridge} from "./IBridge.sol";

/**
 * @title BridgeAgency
 * @notice Governance front-door for the Bridge. Holds `ADMIN_ROLE` on the Bridge contract and
 *         exposes ergonomic, single-tx setters for token registration, deployment of new
 *         BridgeERC20 instances, and remote-token mappings.
 * @dev `Ownable` initial owner is typically a multisig / timelock. Storage is namespaced under
 *      ERC-7201 `0g.bridge.BridgeAgency` so future impl changes don't collide with the
 *      `OwnableUpgradeable` slot.
 *      This is a separate concept from the W0G `WrappedA0GIBaseAgency` — the two control
 *      orthogonal governance surfaces (W0G mint cap vs. Bridge token registry).
 */
contract BridgeAgency is Initializable, OwnableUpgradeable {
    /// @dev `disableToken` called against a token that is not currently enabled. Guards against
    ///      operator typos that would otherwise write a disabled default-mode entry into Bridge
    ///      storage for an unknown token.
    error TokenNotEnabled();

    /// @custom:storage-location erc7201:0g.bridge.BridgeAgency
    struct AgencyStorage {
        /// Bridge proxy this agency administers. Set once at init; all admin setters route through it.
        address bridge;
        /// Shared `UpgradeableBeacon` used by `deployAndAddBridgeToken` to deploy new
        /// BridgeERC20 BeaconProxy instances. Matches `Bridge.bridgeERC20Beacon`.
        address bridgeERC20Beacon;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.bridge.BridgeAgency")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AgencyStorageLocation = 0x3785587e0420fcf97aeb00bbb141987a024d7fb0ac9d19108bee3d7d45e98800;

    function _getAgencyStorage() internal pure returns (AgencyStorage storage $) {
        assembly {
            $.slot := AgencyStorageLocation
        }
    }

    /// @notice Initialize the agency.
    /// @param bridge_ Address of the Bridge proxy.
    /// @param bridgeERC20Beacon_ Address of the shared BridgeERC20 UpgradeableBeacon.
    /// @param initialOwner Address granted `Ownable` ownership (typically multisig).
    function initialize(address bridge_, address bridgeERC20Beacon_, address initialOwner) external initializer {
        if (bridge_ == address(0) || bridgeERC20Beacon_ == address(0)) {
            revert IBridge.ZeroAddress();
        }
        __Ownable_init(initialOwner);
        AgencyStorage storage $ = _getAgencyStorage();
        $.bridge = bridge_;
        $.bridgeERC20Beacon = bridgeERC20Beacon_;
    }

    /// @notice Register an existing token in the Bridge with a chosen mode.
    /// @dev Used for tokens that aren't deployed via the BridgeERC20 template — e.g. W0G
    ///      (MintBurn, with cap registered on the precompile separately) or USDT on the
    ///      primary chain (LockRelease).
    function addToken(address localToken, IBridge.BridgeMode mode) external onlyOwner {
        AgencyStorage storage $ = _getAgencyStorage();
        IBridge($.bridge).configureToken(localToken, true, mode);
    }

    /// @notice Deploy a new BridgeERC20 BeaconProxy and register it as MintBurn in one tx.
    /// @dev Uses CREATE2 via `Bridge.deployBridgeERC20`. Operators on multiple chains who want
    ///      the same bridged token to land at the same address must pass identical `(name,
    ///      symbol, decimals_, salt)` and operate on chains where Bridge + BridgeERC20Beacon
    ///      already share addresses (the case under the Nick-method genesis deployment).
    ///
    ///      DECIMALS: the bridge does NOT require matching decimals across chains. It normalizes
    ///      every cross-chain amount to an 18-decimals wire representation on the source and
    ///      converts back to the local token's decimals on delivery (Bridge `_convertDecimals`),
    ///      so a 6-decimals USDT on one chain and its BridgeERC20 twin here can use different
    ///      decimals. `decimals_` is simply the decimals this twin should report; pick what suits
    ///      the local representation (commonly the source token's, for display parity). Bridging
    ///      to a lower-decimals token truncates sub-precision dust, which is inherent to the
    ///      precision gap.
    /// @param decimals_ Decimals the deployed BridgeERC20 reports (need not match the source token).
    /// @return localToken Address of the newly deployed BridgeERC20.
    function deployAndAddBridgeToken(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        bytes32 salt
    ) external onlyOwner returns (address localToken) {
        AgencyStorage storage $ = _getAgencyStorage();
        localToken = IBridge($.bridge).deployBridgeERC20(name, symbol, decimals_, salt);
        IBridge($.bridge).configureToken(localToken, true, IBridge.BridgeMode.MintBurn);
    }

    /// @notice Set the destination-chain token address that `localToken` corresponds to.
    function mapRemote(address localToken, uint64 dstCID, address remoteToken_) external onlyOwner {
        AgencyStorage storage $ = _getAgencyStorage();
        IBridge($.bridge).mapRemoteToken(localToken, dstCID, remoteToken_);
    }

    /// @notice Disable a previously-registered token, preserving its mode for future re-enable.
    /// @dev Asymmetric pair to `addToken`: `addToken(token, mode)` is the only path that can
    ///      *enable* a token and forces the caller to specify the mode explicitly. `disableToken`
    ///      reads the current mode from the Bridge and pass-throughs `configureToken(t, false, mode)`,
    ///      so toggling never accidentally re-registers an unknown token as a non-default mode.
    ///      To re-enable, call `addToken(token, mode)` again with the same mode.
    ///      Reverts `TokenNotEnabled` if the token is not currently enabled — operator typo on
    ///      `disableToken(<wrong address>)` would otherwise silently write a disabled default-mode
    ///      entry into Bridge storage instead of failing loud.
    function disableToken(
        address localToken
    ) external onlyOwner {
        AgencyStorage storage $ = _getAgencyStorage();
        (bool enabled, IBridge.BridgeMode mode) = IBridge($.bridge).tokenConfig(localToken);
        if (!enabled) revert TokenNotEnabled();
        IBridge($.bridge).configureToken(localToken, false, mode);
    }

    /// @notice Configure per-token anti-spam controls.
    /// @dev Routes to `Bridge.setSpamControl`. `cfg.minCrossOutAmount` is the source-side floor
    ///      enforced by `lockAndSend` / `burnAndSend`; the `proposerFee*` / `keeperFee*` triples
    ///      configure the destination-side fee legs charged at deliver time — proposer leg to the
    ///      parked message's `feeRecipient`, keeper leg to the `deliver` / `deliverBatch` caller.
    ///      Bridge enforces `proposerFeeBps + keeperFeeBps <= MAX_FEE_BPS` (10000) and per-leg
    ///      `feeMin <= feeMax`; setting all fields to zero disables the controls for `token`.
    ///      Each leg's `feeMax` is a hard cap on that leg's computed fee: with `feeMax == 0` the
    ///      leg always charges 0 even if its `bps` / `feeMin` are nonzero, so charging a fee
    ///      requires a nonzero `feeMax` on that leg.
    function setSpamControl(address token, IBridge.TokenSpamControl calldata cfg) external onlyOwner {
        AgencyStorage storage $ = _getAgencyStorage();
        IBridge($.bridge).setSpamControl(token, cfg);
    }

    // ============= Views =============

    /// @notice Returns the Bridge proxy address governed by this agency.
    function bridge() external view returns (address) {
        return _getAgencyStorage().bridge;
    }

    /// @notice Returns the shared BridgeERC20 beacon.
    function bridgeERC20Beacon() external view returns (address) {
        return _getAgencyStorage().bridgeERC20Beacon;
    }
}
