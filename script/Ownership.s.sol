// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {JsonUtils} from "./deploy/Utils.s.sol";

/**
 * @title Governance handover
 * @notice Moves the privileged keys of a deployed restaking stack off the deploying EOA and onto
 *         a multisig: the `UpgradeableBeacon` owners (the upgrade keys for all proxies behind
 *         them) and the `AccessControl` roles the initializers self-granted.
 * @dev NOT covered, and not fixable from here: each Symbiotic VetoSlasher created by
 *      `createValidator` had its resolver set to the deploying EOA, and that resolver can veto
 *      any slash. `VetoSlasher.setResolver` only accepts calls from the registered network -
 *      the factory - and no factory selector calls it, so existing vaults keep that resolver
 *      until the factory is upgraded to expose one. `ZeroGravityFactory.setParams` only changes
 *      the resolver handed to vaults created later. Treat the veto path as still EOA-controlled
 *      after running everything here.
 *
 *      Handover is deliberately split into `grant*` then `revoke*` so the two land in separate
 *      transactions and the grant can be verified on chain before the deployer gives up access.
 *      `revoke*` refuses to run unless the incoming admin already holds `DEFAULT_ADMIN_ROLE`,
 *      because revoking the last admin of an `AccessControl` contract is unrecoverable. That
 *      guard alone does not catch a mistyped multisig - the same wrong address would have been
 *      granted the role one step earlier and would satisfy it - so every address that receives
 *      authority in the batch steps must also have contract code, which a multisig always does.
 *
 *      Addresses come from the chain-scoped deployment records, and every entry point takes the
 *      chain id it is meant for and asserts it. Checking for "not Ethereum" is not enough: the
 *      records exist for several 0G chains (16602 among them) with identical key names, so a
 *      handover aimed at mainnet would otherwise run to completion against a testnet RPC. The
 *      two chains also share contract addresses (same deployer, same nonces) - 0xd5AB...34b6 is
 *      RestakingStates on 0G and ZeroGravityFactory on Ethereum.
 *
 *      Signing key: PRIVATE_KEY on Ethereum mainnet, PRIVATE_KEY_0G everywhere else, matching the
 *      convention of the deployment scripts in this directory. The revoked deployer is derived
 *      from that key rather than passed in, so it cannot name the wrong account.
 */
contract OwnershipScript is Script, JsonUtils {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant UPDATE_ROLE = keccak256("UPDATE_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPDATE_COLLATERAL_ROLE = keccak256("UPDATE_COLLATERAL_ROLE");
    bytes32 internal constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 internal constant WEIGHT_SET_ROLE = keccak256("WEIGHT_SET_ROLE");

    uint256 internal constant ETHEREUM_CHAIN_ID = 1;

    error WrongChain(uint256 actual, uint256 expected);
    error EthereumNotAllowed();
    error ZeroAddress();
    error NotAContract(address account);
    error AdminNotHandedOver(address target, address newAdmin);
    error SameAccount(address account);
    error CommitterRoleMissing(address target, address expectedCommitter);

    // ---------------------------------------------------------------------------------------
    // 0G chain: address book
    // ---------------------------------------------------------------------------------------

    /// @notice Beacons whose owner is the upgrade key of the 0G-chain restaking proxies.
    /// @dev RewarderBeacon governs every per-validator Rewarder proxy, not a single instance.
    function zgBeacons() public returns (address[] memory beacons) {
        (string memory rewarderJson,) = loadOrInitJson("rewarder");
        (string memory ascendJson,) = loadOrInitJson("ascend");

        beacons = new address[](4);
        beacons[0] = vm.parseJsonAddress(rewarderJson, ".RestakingStatesBeacon");
        beacons[1] = vm.parseJsonAddress(rewarderJson, ".RewarderFactoryBeacon");
        beacons[2] = vm.parseJsonAddress(rewarderJson, ".RewarderBeacon");
        beacons[3] = vm.parseJsonAddress(ascendJson, ".AscendRouterBeacon");
    }

    /// @notice 0G-chain contracts that gate functions behind `AccessControl` roles.
    function zgAccessControlled() public returns (address[] memory targets) {
        (string memory rewarderJson,) = loadOrInitJson("rewarder");
        (string memory ascendJson,) = loadOrInitJson("ascend");

        targets = new address[](3);
        targets[0] = vm.parseJsonAddress(rewarderJson, ".RestakingStates");
        targets[1] = vm.parseJsonAddress(rewarderJson, ".RewarderFactory");
        targets[2] = vm.parseJsonAddress(ascendJson, ".AscendRouter");
    }

    /// @notice The only 0G-chain contract carrying a non-admin role held by the deployer.
    function zgRestakingStates() public returns (address) {
        (string memory rewarderJson,) = loadOrInitJson("rewarder");
        return vm.parseJsonAddress(rewarderJson, ".RestakingStates");
    }

    // ---------------------------------------------------------------------------------------
    // 0G chain: handover steps
    // ---------------------------------------------------------------------------------------

    /// @notice Step 1 (0G): move the four beacon owners to `newOwner`.
    function transferZgBeacons(uint256 expectedChainId, address newOwner) public {
        _requireZgChain(expectedChainId);
        address[] memory beacons = zgBeacons();

        vm.startBroadcast(_signingKey());
        _transferBeacons(beacons, newOwner);
        vm.stopBroadcast();
    }

    /// @notice Step 2 (0G): grant `DEFAULT_ADMIN_ROLE` on every role-gated contract to `newAdmin`.
    /// @dev Only the admin role is granted. `UPDATE_ROLE` stays with the committer hot key and
    ///      `DISTRIBUTOR_ROLE` with the distributor bot; a multisig cannot serve those.
    function grantZgAdmins(uint256 expectedChainId, address newAdmin) public {
        _requireZgChain(expectedChainId);
        _requireContract(newAdmin);
        address[] memory targets = zgAccessControlled();

        vm.startBroadcast(_signingKey());
        for (uint256 i = 0; i < targets.length; ++i) {
            _grantRole(targets[i], DEFAULT_ADMIN_ROLE, newAdmin);
        }
        vm.stopBroadcast();
    }

    /// @notice Step 3 (0G): strip every role the deployer still holds, after `newAdmin` took over.
    /// @dev Also drops the `UPDATE_ROLE` the deployer self-granted in `RestakingStates.initialize`
    ///      and never used for submissions; leaving it behind keeps a spare write key alive.
    ///      `expectedCommitter` must already hold `UPDATE_ROLE`, so that dropping the deployer's
    ///      copy cannot leave the role with no holder at all. It forces the operator to name the
    ///      key they believe is submitting; it does not prove that key is actually in use, which
    ///      only the sender of recent `RestakingStates` updates shows.
    function revokeZgDeployer(uint256 expectedChainId, address newAdmin, address expectedCommitter) public {
        _requireZgChain(expectedChainId);
        _requireContract(newAdmin);

        address deployer = _deployer();
        console2.log("revoking from deployer:", deployer);
        address[] memory targets = zgAccessControlled();
        address restakingStates = zgRestakingStates();

        if (expectedCommitter == deployer || expectedCommitter == address(0)) {
            revert SameAccount(expectedCommitter);
        }
        if (!IAccessControl(restakingStates).hasRole(UPDATE_ROLE, expectedCommitter)) {
            revert CommitterRoleMissing(restakingStates, expectedCommitter);
        }

        vm.startBroadcast(_signingKey());
        // RestakingStates: non-admin role first, so an abort cannot leave the deployer with a
        // write key it no longer has the admin rights to remove.
        _revokeRole(restakingStates, UPDATE_ROLE, deployer, newAdmin);
        for (uint256 i = 0; i < targets.length; ++i) {
            _revokeRole(targets[i], DEFAULT_ADMIN_ROLE, deployer, newAdmin);
        }
        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------------------------------
    // Ethereum: address book
    // ---------------------------------------------------------------------------------------

    /// @notice Beacons whose owner is the upgrade key of the Ethereum restaking proxies.
    function ethBeacons() public returns (address[] memory beacons) {
        (string memory json,) = loadOrInitJson("zerogravity");

        beacons = new address[](3);
        beacons[0] = vm.parseJsonAddress(json, ".ZeroGravityFactoryBeacon");
        beacons[1] = vm.parseJsonAddress(json, ".ZeroGravityMiddlewareBeacon");
        beacons[2] = vm.parseJsonAddress(json, ".OperatorBeacon");
    }

    /// @notice Ethereum contracts that gate functions behind `AccessControl` roles.
    function ethAccessControlled() public returns (address factory, address middleware) {
        (string memory json,) = loadOrInitJson("zerogravity");

        factory = vm.parseJsonAddress(json, ".ZeroGravityFactory");
        middleware = vm.parseJsonAddress(json, ".ZeroGravityMiddleware");
    }

    // ---------------------------------------------------------------------------------------
    // Ethereum: handover steps
    // ---------------------------------------------------------------------------------------

    /// @notice Step 1 (Ethereum): move the three beacon owners to `newOwner`.
    function transferEthBeacons(
        address newOwner
    ) public {
        _requireChain(ETHEREUM_CHAIN_ID);
        address[] memory beacons = ethBeacons();

        vm.startBroadcast(_signingKey());
        _transferBeacons(beacons, newOwner);
        vm.stopBroadcast();
    }

    /// @notice Step 2 (Ethereum): grant every deployer-held role to `newAdmin`.
    /// @dev `REGISTER_OPERATOR_ROLE` on the middleware is held by the factory contract itself and
    ///      is deliberately left alone.
    function grantEthAdmins(
        address newAdmin
    ) public {
        _requireChain(ETHEREUM_CHAIN_ID);
        _requireContract(newAdmin);
        (address factory, address middleware) = ethAccessControlled();

        vm.startBroadcast(_signingKey());
        _grantRole(factory, DEFAULT_ADMIN_ROLE, newAdmin);
        _grantRole(factory, UPDATE_COLLATERAL_ROLE, newAdmin);
        _grantRole(factory, PAUSER_ROLE, newAdmin);
        _grantRole(middleware, DEFAULT_ADMIN_ROLE, newAdmin);
        _grantRole(middleware, SLASHER_ROLE, newAdmin);
        _grantRole(middleware, WEIGHT_SET_ROLE, newAdmin);
        vm.stopBroadcast();
    }

    /// @notice Step 3 (Ethereum): strip every role the deployer still holds.
    /// @dev Revokes `PAUSER_ROLE` too. To keep a fast-reacting hot pauser alongside the multisig,
    ///      grant it to that key first (`grantRoleTo`) and confirm before running this.
    function revokeEthDeployer(
        address newAdmin
    ) public {
        _requireChain(ETHEREUM_CHAIN_ID);
        _requireContract(newAdmin);

        address deployer = _deployer();
        console2.log("revoking from deployer:", deployer);
        (address factory, address middleware) = ethAccessControlled();

        vm.startBroadcast(_signingKey());
        _revokeRole(factory, UPDATE_COLLATERAL_ROLE, deployer, newAdmin);
        _revokeRole(factory, PAUSER_ROLE, deployer, newAdmin);
        _revokeRole(factory, DEFAULT_ADMIN_ROLE, deployer, newAdmin);
        _revokeRole(middleware, SLASHER_ROLE, deployer, newAdmin);
        _revokeRole(middleware, WEIGHT_SET_ROLE, deployer, newAdmin);
        _revokeRole(middleware, DEFAULT_ADMIN_ROLE, deployer, newAdmin);
        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------------------------------
    // Single-target entry points
    // ---------------------------------------------------------------------------------------

    /// @notice Transfer one beacon owner, for a partial or corrective run.
    function transferBeacon(uint256 expectedChainId, address beacon, address newOwner) public {
        _requireChain(expectedChainId);
        address[] memory beacons = new address[](1);
        beacons[0] = beacon;

        vm.startBroadcast(_signingKey());
        _transferBeacons(beacons, newOwner);
        vm.stopBroadcast();
    }

    /// @notice Grant one role on one contract, e.g. handing `UPDATE_ROLE` to a new committer key.
    /// @dev Accepts an account without contract code, because the operational roles belong to hot
    ///      keys - except for `DEFAULT_ADMIN_ROLE`, where the batch steps' rule applies: granting
    ///      it here and then revoking the deployer would otherwise route around that guard.
    function grantRoleTo(uint256 expectedChainId, address target, bytes32 role, address account) public {
        _requireChain(expectedChainId);
        if (role == DEFAULT_ADMIN_ROLE) {
            _requireContract(account);
        }

        vm.startBroadcast(_signingKey());
        _grantRole(target, role, account);
        vm.stopBroadcast();
    }

    /// @notice Revoke one role on one contract. `newAdmin` is the address that must already hold
    ///         `DEFAULT_ADMIN_ROLE`, so that no revocation can leave the contract admin-less.
    function revokeRoleFrom(
        uint256 expectedChainId,
        address target,
        bytes32 role,
        address account,
        address newAdmin
    ) public {
        _requireChain(expectedChainId);

        vm.startBroadcast(_signingKey());
        _revokeRole(target, role, account, newAdmin);
        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    /// @dev Skips a beacon already owned by `newOwner` so an interrupted run can be repeated.
    ///      A beacon owned by a third party is left to revert inside `transferOwnership`.
    function _transferBeacons(address[] memory beacons, address newOwner) internal {
        // An upgrade key is only ever meant to reach a multisig, and the transfer has no
        // acceptance step to undo a typo, so a destination without code is rejected outright.
        _requireContract(newOwner);
        for (uint256 i = 0; i < beacons.length; ++i) {
            address current = UpgradeableBeacon(beacons[i]).owner();
            if (current == newOwner) {
                console2.log("beacon already transferred, skipping:", beacons[i]);
                continue;
            }
            UpgradeableBeacon(beacons[i]).transferOwnership(newOwner);
            console2.log("beacon owner transferred:", beacons[i]);
            console2.log("  from / to:", current, newOwner);
        }
    }

    function _grantRole(address target, bytes32 role, address account) internal {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        if (IAccessControl(target).hasRole(role, account)) {
            console2.log("role already granted, skipping:", target);
            console2.logBytes32(role);
            return;
        }
        IAccessControl(target).grantRole(role, account);
        console2.log("role granted on:", target);
        console2.logBytes32(role);
        console2.log("  to:", account);
    }

    /// @dev `newAdmin` must already be an admin of `target`: an `AccessControl` contract whose last
    ///      `DEFAULT_ADMIN_ROLE` holder is revoked can never grant a role again, and none of these
    ///      contracts is upgradeable independently of a beacon owner that would also be gone.
    function _revokeRole(address target, bytes32 role, address account, address newAdmin) internal {
        if (account == newAdmin) {
            revert SameAccount(account);
        }
        if (!IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, newAdmin)) {
            revert AdminNotHandedOver(target, newAdmin);
        }
        if (!IAccessControl(target).hasRole(role, account)) {
            console2.log("role not held, skipping:", target);
            console2.logBytes32(role);
            return;
        }
        IAccessControl(target).revokeRole(role, account);
        console2.log("role revoked on:", target);
        console2.logBytes32(role);
        console2.log("  from:", account);
    }

    function _signingKey() internal view returns (uint256) {
        return block.chainid == ETHEREUM_CHAIN_ID ? vm.envUint("PRIVATE_KEY") : vm.envUint("PRIVATE_KEY_0G");
    }

    /// @dev The account losing its roles is whoever signs, by definition of this handover.
    function _deployer() internal view returns (address) {
        return vm.addr(_signingKey());
    }

    function _requireContract(
        address account
    ) internal view {
        if (account == address(0)) {
            revert ZeroAddress();
        }
        if (account.code.length == 0) {
            revert NotAContract(account);
        }
    }

    function _requireChain(
        uint256 expected
    ) internal view {
        if (block.chainid != expected) {
            revert WrongChain(block.chainid, expected);
        }
    }

    /// @dev Guards the 0G address book against being used on Ethereum, where the same addresses
    ///      belong to different contracts, on top of the exact chain-id check.
    function _requireZgChain(
        uint256 expected
    ) internal view {
        if (expected == ETHEREUM_CHAIN_ID) {
            revert EthereumNotAllowed();
        }
        _requireChain(expected);
    }
}
