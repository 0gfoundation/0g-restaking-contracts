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
    /// @custom:storage-location erc7201:0g.bridge.BridgeAgency
    struct AgencyStorage {
        address bridge;
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
    /// @return localToken Address of the newly deployed BridgeERC20.
    function deployAndAddBridgeToken(
        string memory name,
        string memory symbol
    ) external onlyOwner returns (address localToken) {
        AgencyStorage storage $ = _getAgencyStorage();
        localToken = IBridge($.bridge).deployBridgeERC20(name, symbol);
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
    function disableToken(
        address localToken
    ) external onlyOwner {
        AgencyStorage storage $ = _getAgencyStorage();
        (, IBridge.BridgeMode mode) = IBridge($.bridge).tokenConfig(localToken);
        IBridge($.bridge).configureToken(localToken, false, mode);
    }

    /// @notice Configure per-token anti-spam controls (minimum amount + per-tx fee).
    /// @dev Routes to `Bridge.setSpamControl`. Bridge enforces `feeBps <= MAX_FEE_BPS` (2000) and
    ///      `feeMin <= feeMax`; setting all fields to zero disables the controls for `token`.
    function setSpamControl(
        address token,
        uint256 minCrossOutAmount,
        uint16 feeBps,
        uint256 feeMin,
        uint256 feeMax,
        address feeRecipient
    ) external onlyOwner {
        AgencyStorage storage $ = _getAgencyStorage();
        IBridge($.bridge).setSpamControl(token, minCrossOutAmount, feeBps, feeMin, feeMax, feeRecipient);
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
