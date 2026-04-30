// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title BridgeERC20
 * @notice Templated ERC-20 deployed once per MintBurn-mode token registered with the Bridge.
 * @dev All BridgeERC20 instances share a single `UpgradeableBeacon`, so a single
 *      `beacon.upgradeTo(newImpl)` upgrades every minted-token contract simultaneously.
 *      The Bridge contract is granted `MINTER_ROLE` (and `DEFAULT_ADMIN_ROLE`) on init,
 *      enabling it to mint/burn on behalf of cross-chain messages. The interface — `mint(to, amt)`
 *      + `burn(amt)` self-burn — matches W0G's `burn(uint256)` (selector 0x42966c68) exactly so
 *      Bridge.burnAndSend's two-step `transferFrom + burn` works against either token.
 */
contract BridgeERC20 is Initializable, ERC20Upgradeable, AccessControlUpgradeable {
    /// @dev Role required to mint or burn. Granted to the Bridge proxy on init.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Initializes the token and grants admin + minter roles to the Bridge.
    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param bridge The Bridge proxy address. Receives DEFAULT_ADMIN_ROLE and MINTER_ROLE.
    function initialize(string memory name_, string memory symbol_, address bridge) external initializer {
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, bridge);
        _grantRole(MINTER_ROLE, bridge);
    }

    /// @notice Mints `amount` to `to`. Restricted to the Bridge.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Self-burn: caller (must hold MINTER_ROLE — i.e. the Bridge) burns its own ledger
    ///         entry. Bridge.burnAndSend transfers user tokens → Bridge first via transferFrom,
    ///         then calls burn(amount) to drain Bridge's own balance. No allowance needed because
    ///         the bridge owns the tokens when it burns.
    function burn(
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        _burn(msg.sender, amount);
    }
}
