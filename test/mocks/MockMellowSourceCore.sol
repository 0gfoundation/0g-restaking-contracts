// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AccessControl, IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Same behaviour as mellow-interop's `Oracle`: roles are checked against the core's access
///      control, and `getValue()` reverts once `lastUpdated + maxAge` has passed.
contract MockMellowOracle {
    bytes32 public constant SET_VALUE_ROLE = keccak256("ORACLE:SET_VALUE_ROLE");

    address public immutable core;
    uint256 public value;
    uint256 public lastUpdated;
    uint256 public maxAge;

    constructor(address core_, uint256 initialValue_, uint256 initialMaxAge_) {
        core = core_;
        value = initialValue_;
        lastUpdated = block.timestamp;
        maxAge = initialMaxAge_;
    }

    function getValue() public view returns (uint256) {
        if (lastUpdated + maxAge < block.timestamp) {
            revert("Oracle: stale value");
        }
        return value;
    }

    function setValue(
        uint256 value_
    ) external {
        if (!IAccessControl(core).hasRole(SET_VALUE_ROLE, msg.sender)) {
            revert("Oracle: forbidden");
        }
        value = value_;
        lastUpdated = block.timestamp;
    }
}

/// @dev The SourceCore accounting OracleUpdater depends on: shares priced at the oracle value, a
///      withdrawal queue that holds requested shares until `handleEpoch` burns them against assets,
///      and a lockbox adapter that `pushToTarget` moves assets into.
contract MockMellowSourceCore is ERC20, AccessControl {
    MockMellowOracle public immutable oracle;
    IERC20 public immutable asset;
    address public immutable oftAdapter;
    address public immutable withdrawalQueue;

    constructor(IERC20 asset_, address oftAdapter_, address withdrawalQueue_, address admin) ERC20("aOG", "aOG") {
        asset = asset_;
        oftAdapter = oftAdapter_;
        withdrawalQueue = withdrawalQueue_;
        oracle = new MockMellowOracle(address(this), 1 ether, 21 days);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function deposit(
        uint256 assets
    ) external returns (uint256 shares) {
        shares = Math.mulDiv(assets, 1 ether, oracle.getValue());
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(msg.sender, shares);
    }

    function requestWithdrawal(
        uint256 shares
    ) external {
        _transfer(msg.sender, withdrawalQueue, shares);
    }

    /// @dev `WithdrawalQueue.handleEpoch` -> `SourceCore.pull`: burns the queued shares and moves
    ///      their assets, priced at the oracle value, to the queue in one step.
    function handleEpoch(
        uint256 shares
    ) external returns (uint256 assets) {
        assets = Math.mulDiv(shares, oracle.getValue(), 1 ether);
        _burn(withdrawalQueue, shares);
        asset.transfer(withdrawalQueue, assets);
    }

    function pushToTarget(
        uint256 assets
    ) external {
        asset.transfer(oftAdapter, assets);
    }
}
