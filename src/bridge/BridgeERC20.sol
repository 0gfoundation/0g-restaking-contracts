// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IBridge} from "./IBridge.sol";

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

    /// Decimals this token reports, set once at init and returned by `decimals()`. The bridge
    /// normalizes every cross-chain amount to an 18-decimals wire representation and converts it
    /// back to the local token's decimals on delivery (see Bridge `_convertDecimals`), so this
    /// need NOT match the token's decimals on other chains — but it MUST be the decimals this
    /// token actually reports, because the bridge reads `decimals()` to size those conversions.
    uint8 private _decimals;

    /// @dev Locks the implementation contract so only beacon proxies are usable — the bare
    ///      implementation at its deterministic raw-tx address cannot be initialized by anyone.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the token and grants admin + minter roles to the Bridge.
    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param decimals_ ERC-20 decimals for this bridged token. Chosen by the deployer for the
    ///        local representation; the bridge normalizes amounts through an 18-decimals wire, so
    ///        it may differ from the source token's decimals (see Bridge `_convertDecimals`).
    /// @param bridge The Bridge proxy address. Receives DEFAULT_ADMIN_ROLE and MINTER_ROLE.
    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address bridge
    ) external initializer {
        if (bridge == address(0)) revert IBridge.ZeroAddress();
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        _decimals = decimals_;
        _grantRole(DEFAULT_ADMIN_ROLE, bridge);
        _grantRole(MINTER_ROLE, bridge);
    }

    /// @notice ERC-20 decimals, fixed at init to match the mirrored source token (see `_decimals`).
    function decimals() public view override returns (uint8) {
        return _decimals;
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
