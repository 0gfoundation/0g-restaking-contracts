// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AscendRouter} from "../src/ascend/AscendRouter.sol";
import {RestakingStates} from "../src/RestakingStates.sol";
import {Rewarder} from "../src/Rewarder.sol";
import {RewarderFactory} from "../src/RewarderFactory.sol";

import {OwnershipScript} from "../script/Ownership.s.sol";

import {Token} from "./mocks/Token.sol";
import {ZeroGravityBaseTest} from "./ZeroGravityBase.t.sol";

/// @dev Stands in for a multisig: the handover steps require a destination with contract code, so
///      an EOA cannot be used here.
contract MultisigStub {}

/// @dev Shared by both halves: deployment records live in one directory so the two test contracts
///      can set the same DEPLOYMENT_PATH value even when forge runs them on separate threads, and
///      the chain-scoped file names keep their contents apart.
abstract contract OwnershipTestBase is OwnershipScript {
    function _deploymentDir() internal returns (string memory dir) {
        dir = string.concat(vm.projectRoot(), "/out/ownership-test");
        vm.createDir(dir, true);
        vm.setEnv("DEPLOYMENT_PATH", dir);
    }

    function _writeRecord(string memory task, string memory body) internal {
        vm.writeFile(
            string.concat(_deploymentDir(), "/", task, "-", vm.toString(block.chainid), ".json"),
            string.concat("{", body, "}")
        );
    }

    function _entry(string memory key, address value) internal pure returns (string memory) {
        return string.concat('"', key, '":"', vm.toString(value), '"');
    }

    /// @dev BeaconProxy keeps its beacon in the ERC-1967 beacon slot as well as an immutable, which
    ///      is the only way to recover a beacon that the deploying test never stored.
    function _beaconOf(
        address proxy
    ) internal view returns (address) {
        bytes32 slot = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}

// ===========================================================================================
// 0G chain
// ===========================================================================================

contract OwnershipZgTest is Test, OwnershipTestBase {
    uint256 internal constant ZG_CHAIN_ID = 16_661;

    address internal deployer;
    uint256 internal deployerKey;
    address internal safe;
    address internal committer;
    address internal distributor;
    address internal otherAdmin;

    RestakingStates internal restakingStates;
    RewarderFactory internal rewarderFactory;
    AscendRouter internal ascendRouter;
    UpgradeableBeacon internal statesBeacon;
    UpgradeableBeacon internal factoryBeacon;
    UpgradeableBeacon internal rewarderBeacon;
    UpgradeableBeacon internal routerBeacon;

    function setUp() public {
        vm.chainId(ZG_CHAIN_ID);

        (deployer, deployerKey) = makeAddrAndKey("zgDeployer");
        safe = address(new MultisigStub());
        committer = makeAddr("committer");
        distributor = makeAddr("distributor");
        otherAdmin = makeAddr("otherAdmin");
        // Label-derived throwaway key, not a secret: the script reads its signer from the
        // environment, so exercising the real entry points means populating that variable.
        vm.setEnv("PRIVATE_KEY_0G", vm.toString(deployerKey));

        // Deploy exactly as mainnet was deployed: every role self-granted to the deploying EOA
        // through the initializers, and every beacon owned by it.
        vm.startPrank(deployer);

        rewarderBeacon = new UpgradeableBeacon(address(new Rewarder()), deployer);

        statesBeacon = new UpgradeableBeacon(address(new RestakingStates()), deployer);
        restakingStates = RestakingStates(
            address(new BeaconProxy(address(statesBeacon), abi.encodeCall(RestakingStates.initialize, (1))))
        );

        factoryBeacon = new UpgradeableBeacon(address(new RewarderFactory()), deployer);
        rewarderFactory = RewarderFactory(
            address(
                new BeaconProxy(
                    address(factoryBeacon),
                    abi.encodeCall(RewarderFactory.initialize, (address(rewarderBeacon), address(restakingStates)))
                )
            )
        );

        routerBeacon = new UpgradeableBeacon(address(new AscendRouter()), deployer);
        ascendRouter = AscendRouter(
            payable(
                address(
                    new BeaconProxy(
                        address(routerBeacon),
                        abi.encodeCall(
                            AscendRouter.initialize,
                            (
                                address(new Token("W0G")),
                                makeAddr("mellowVault"),
                                makeAddr("foundation"),
                                address(0),
                                0.9e18,
                                0.1e18,
                                0
                            )
                        )
                    )
                )
            )
        );

        // The operational keys that must survive the handover untouched, plus an unrelated admin
        // that proves the revoke step only ever targets the signing key.
        restakingStates.grantRole(UPDATE_ROLE, committer);
        ascendRouter.grantRole(ascendRouter.DISTRIBUTOR_ROLE(), distributor);
        restakingStates.grantRole(DEFAULT_ADMIN_ROLE, otherAdmin);

        vm.stopPrank();

        _writeZgRecords();
    }

    function _writeZgRecords() internal {
        _writeRecord(
            "rewarder",
            string.concat(
                _entry("RestakingStates", address(restakingStates)),
                ",",
                _entry("RestakingStatesBeacon", address(statesBeacon)),
                ",",
                _entry("RewarderFactory", address(rewarderFactory)),
                ",",
                _entry("RewarderFactoryBeacon", address(factoryBeacon)),
                ",",
                _entry("RewarderBeacon", address(rewarderBeacon))
            )
        );
        _writeRecord(
            "ascend",
            string.concat(
                _entry("AscendRouter", address(ascendRouter)), ",", _entry("AscendRouterBeacon", address(routerBeacon))
            )
        );
    }

    // ---- address book ----------------------------------------------------------------------

    function test_zgBeacons_matchesDeploymentRecords() public {
        address[] memory beacons = zgBeacons();
        assertEq(beacons.length, 4);
        assertEq(beacons[0], address(statesBeacon));
        assertEq(beacons[1], address(factoryBeacon));
        assertEq(beacons[2], address(rewarderBeacon));
        assertEq(beacons[3], address(routerBeacon));
    }

    function test_zgAccessControlled_matchesDeploymentRecords() public {
        address[] memory targets = zgAccessControlled();
        assertEq(targets.length, 3);
        assertEq(targets[0], address(restakingStates));
        assertEq(targets[1], address(rewarderFactory));
        assertEq(targets[2], address(ascendRouter));
        assertEq(zgRestakingStates(), address(restakingStates));
    }

    /// @dev The beacons are read straight from the proxies as a cross-check that the deployment
    ///      records name the beacon that actually governs each proxy.
    function test_recordedBeaconsGovernTheRecordedProxies() public view {
        assertEq(_beaconOf(address(restakingStates)), address(statesBeacon));
        assertEq(_beaconOf(address(rewarderFactory)), address(factoryBeacon));
        assertEq(_beaconOf(address(ascendRouter)), address(routerBeacon));
    }

    /// @dev The role identifiers are hard-coded in the script. Without this, a typo in one of them
    ///      would make the revoke step silently skip the role it was meant to drop, while the
    ///      tests kept passing because they would use the same wrong constant on both sides.
    function test_roleConstantsMatchTheDeployedContracts() public view {
        assertEq(UPDATE_ROLE, restakingStates.UPDATE_ROLE());
        assertEq(DEFAULT_ADMIN_ROLE, restakingStates.DEFAULT_ADMIN_ROLE());
    }

    // ---- beacon ownership ------------------------------------------------------------------

    function test_transferZgBeacons_movesEveryUpgradeKey() public {
        transferZgBeacons(ZG_CHAIN_ID, safe);

        assertEq(statesBeacon.owner(), safe);
        assertEq(factoryBeacon.owner(), safe);
        assertEq(rewarderBeacon.owner(), safe);
        assertEq(routerBeacon.owner(), safe);
    }

    function test_transferZgBeacons_canBeRerunAfterPartialProgress() public {
        vm.prank(deployer);
        statesBeacon.transferOwnership(safe);

        // A re-run must skip the beacon that already moved instead of reverting on it.
        transferZgBeacons(ZG_CHAIN_ID, safe);

        assertEq(statesBeacon.owner(), safe);
        assertEq(routerBeacon.owner(), safe);
    }

    function test_transferZgBeacons_rejectsZeroOwner() public {
        vm.expectRevert(ZeroAddress.selector);
        this.transferZgBeacons(ZG_CHAIN_ID, address(0));
    }

    /// @dev The guard that catches a mistyped multisig: a non-zero address with no code passes
    ///      every other check, and an upgrade key sent there is gone for good.
    function test_transferZgBeacons_rejectsAnOwnerWithNoCode() public {
        address typo = makeAddr("typoNotAContract");
        assertEq(typo.code.length, 0);

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, typo));
        this.transferZgBeacons(ZG_CHAIN_ID, typo);

        assertEq(statesBeacon.owner(), deployer);
    }

    function test_transferZgBeacons_rejectsAChainIdMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, ZG_CHAIN_ID, 16_602));
        this.transferZgBeacons(16_602, safe);
    }

    function test_transferZgBeacons_rejectsEthereumAsTheExpectedChain() public {
        vm.chainId(1);
        vm.expectRevert(EthereumNotAllowed.selector);
        this.transferZgBeacons(1, safe);
    }

    function test_transferBeacon_movesASingleBeacon() public {
        transferBeacon(ZG_CHAIN_ID, address(routerBeacon), safe);

        assertEq(routerBeacon.owner(), safe);
        assertEq(statesBeacon.owner(), deployer);
    }

    function test_transferBeacon_rejectsAChainIdMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, ZG_CHAIN_ID, 1));
        this.transferBeacon(1, address(routerBeacon), safe);
    }

    // ---- roles -----------------------------------------------------------------------------

    function test_grantZgAdmins_grantsAdminEverywhereAndNothingElse() public {
        grantZgAdmins(ZG_CHAIN_ID, safe);

        assertTrue(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, safe));
        assertTrue(rewarderFactory.hasRole(DEFAULT_ADMIN_ROLE, safe));
        assertTrue(ascendRouter.hasRole(DEFAULT_ADMIN_ROLE, safe));

        // The operational roles are not a multisig's job and must stay where they are.
        assertFalse(restakingStates.hasRole(UPDATE_ROLE, safe));
        assertFalse(ascendRouter.hasRole(ascendRouter.DISTRIBUTOR_ROLE(), safe));
        // The deployer keeps everything until the revoke step runs.
        assertTrue(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, deployer));
    }

    function test_grantZgAdmins_isIdempotent() public {
        grantZgAdmins(ZG_CHAIN_ID, safe);
        grantZgAdmins(ZG_CHAIN_ID, safe);

        assertTrue(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, safe));
    }

    function test_grantZgAdmins_rejectsAnAdminWithNoCode() public {
        address typo = makeAddr("typoNotAContract");

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, typo));
        this.grantZgAdmins(ZG_CHAIN_ID, typo);

        assertFalse(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, typo));
    }

    function test_revokeZgDeployer_stripsAdminAndTheStaleUpdateRole() public {
        assertTrue(restakingStates.hasRole(UPDATE_ROLE, deployer));

        grantZgAdmins(ZG_CHAIN_ID, safe);
        revokeZgDeployer(ZG_CHAIN_ID, safe, committer);

        assertFalse(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(rewarderFactory.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(ascendRouter.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(restakingStates.hasRole(UPDATE_ROLE, deployer));

        // The multisig has the admin, and both operational keys are untouched.
        assertTrue(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, safe));
        assertTrue(restakingStates.hasRole(UPDATE_ROLE, committer));
        assertTrue(ascendRouter.hasRole(ascendRouter.DISTRIBUTOR_ROLE(), distributor));
    }

    /// @dev The revoked account is derived from the signing key, never passed in, so the step
    ///      cannot be pointed at the wrong holder - including another admin.
    function test_revokeZgDeployer_onlyTouchesTheSigningKey() public {
        grantZgAdmins(ZG_CHAIN_ID, safe);
        revokeZgDeployer(ZG_CHAIN_ID, safe, committer);

        assertTrue(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, otherAdmin));
        assertFalse(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, deployer));
    }

    /// @dev Guards the one unrecoverable mistake in the whole handover: revoking the deployer's
    ///      admin role before the multisig has one leaves the contract with no admin at all.
    function test_revokeZgDeployer_revertsWhenMultisigIsNotAdminYet() public {
        vm.expectRevert(abi.encodeWithSelector(AdminNotHandedOver.selector, address(restakingStates), safe));
        this.revokeZgDeployer(ZG_CHAIN_ID, safe, committer);

        assertTrue(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertTrue(restakingStates.hasRole(UPDATE_ROLE, deployer));
    }

    /// @dev `RestakingStates` is not enumerable, so naming the live committer is the only on-chain
    ///      proof that dropping the deployer's `UPDATE_ROLE` does not strand submissions.
    function test_revokeZgDeployer_revertsWhenTheNamedCommitterHasNoUpdateRole() public {
        address notTheCommitter = makeAddr("notTheCommitter");
        grantZgAdmins(ZG_CHAIN_ID, safe);

        vm.expectRevert(
            abi.encodeWithSelector(CommitterRoleMissing.selector, address(restakingStates), notTheCommitter)
        );
        this.revokeZgDeployer(ZG_CHAIN_ID, safe, notTheCommitter);

        assertTrue(restakingStates.hasRole(UPDATE_ROLE, deployer));
        assertTrue(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, deployer));
    }

    function test_revokeZgDeployer_revertsWhenTheCommitterIsTheDeployer() public {
        grantZgAdmins(ZG_CHAIN_ID, safe);

        vm.expectRevert(abi.encodeWithSelector(SameAccount.selector, deployer));
        this.revokeZgDeployer(ZG_CHAIN_ID, safe, deployer);
    }

    function test_revokeZgDeployer_isIdempotent() public {
        grantZgAdmins(ZG_CHAIN_ID, safe);
        revokeZgDeployer(ZG_CHAIN_ID, safe, committer);
        // Re-running must not revert on roles that are already gone.
        revokeZgDeployer(ZG_CHAIN_ID, safe, committer);

        assertFalse(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, deployer));
    }

    function test_grantRoleTo_andRevokeRoleFrom_rotateTheCommitterKey() public {
        address newCommitter = makeAddr("newCommitter");

        // Deliberately an EOA: the operational roles belong to hot keys, so the single-target
        // entry points must not demand contract code the way the batch steps do.
        grantRoleTo(ZG_CHAIN_ID, address(restakingStates), UPDATE_ROLE, newCommitter);
        assertTrue(restakingStates.hasRole(UPDATE_ROLE, newCommitter));

        revokeRoleFrom(ZG_CHAIN_ID, address(restakingStates), UPDATE_ROLE, committer, deployer);
        assertFalse(restakingStates.hasRole(UPDATE_ROLE, committer));
    }

    /// @dev The corrective entry points are the way around the batch-step guard, so the admin role
    ///      carries the same contract-code rule there.
    function test_grantRoleTo_rejectsACodelessAdmin() public {
        address typo = makeAddr("typoNotAContract");

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, typo));
        this.grantRoleTo(ZG_CHAIN_ID, address(restakingStates), DEFAULT_ADMIN_ROLE, typo);

        // An operational role still goes to a hot key, which is the point of this entry point.
        grantRoleTo(ZG_CHAIN_ID, address(restakingStates), UPDATE_ROLE, typo);
        assertTrue(restakingStates.hasRole(UPDATE_ROLE, typo));
    }

    /// @dev Without this, nothing covers the guard that stops an admin revoking itself through the
    ///      corrective path and leaving the contract with no admin.
    function test_revokeRoleFrom_rejectsRevokingTheNamedAdminsOwnRole() public {
        grantZgAdmins(ZG_CHAIN_ID, safe);

        vm.expectRevert(abi.encodeWithSelector(SameAccount.selector, safe));
        this.revokeRoleFrom(ZG_CHAIN_ID, address(restakingStates), DEFAULT_ADMIN_ROLE, safe, safe);

        assertTrue(restakingStates.hasRole(DEFAULT_ADMIN_ROLE, safe));
    }

    function test_grantRoleTo_rejectsZeroAccount() public {
        vm.expectRevert(ZeroAddress.selector);
        this.grantRoleTo(ZG_CHAIN_ID, address(restakingStates), UPDATE_ROLE, address(0));
    }

    function test_grantRoleTo_rejectsAChainIdMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, ZG_CHAIN_ID, 1));
        this.grantRoleTo(1, address(restakingStates), UPDATE_ROLE, committer);
    }

    function test_revokeRoleFrom_rejectsAChainIdMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, ZG_CHAIN_ID, 1));
        this.revokeRoleFrom(1, address(restakingStates), UPDATE_ROLE, committer, deployer);
    }
}

// ===========================================================================================
// Ethereum
// ===========================================================================================

/// @dev Runs against the real ZeroGravityFactory / ZeroGravityMiddleware so the role constants in
///      the script are checked against the contracts they will be used on, not against a mock.
contract OwnershipEthTest is ZeroGravityBaseTest, OwnershipTestBase {
    address internal deployer;
    uint256 internal deployerKey;
    address internal safe;

    UpgradeableBeacon internal factoryBeacon;
    UpgradeableBeacon internal middlewareBeacon;

    function setUp() public override {
        // The Symbiotic fixture is built on the base's own chain id; switching afterwards keeps
        // its vault timing identical to the other tests in this suite.
        super.setUp();
        vm.chainId(1);

        (deployer, deployerKey) = makeAddrAndKey("ethDeployer");
        safe = address(new MultisigStub());
        vm.setEnv("PRIVATE_KEY", vm.toString(deployerKey));

        factoryBeacon = UpgradeableBeacon(_beaconOf(address(network)));
        middlewareBeacon = UpgradeableBeacon(_beaconOf(address(middleware)));

        // The fixture deploys as address(this); mirror mainnet by putting every privileged key on
        // the deployer EOA the script signs with. address(this) keeps its own admin role, which
        // the handover must leave alone.
        factoryBeacon.transferOwnership(deployer);
        middlewareBeacon.transferOwnership(deployer);
        operatorBeacon.transferOwnership(deployer);

        network.grantRole(DEFAULT_ADMIN_ROLE, deployer);
        network.grantRole(UPDATE_COLLATERAL_ROLE, deployer);
        network.grantRole(PAUSER_ROLE, deployer);
        middleware.grantRole(DEFAULT_ADMIN_ROLE, deployer);
        middleware.grantRole(SLASHER_ROLE, deployer);
        middleware.grantRole(WEIGHT_SET_ROLE, deployer);

        _writeRecord(
            "zerogravity",
            string.concat(
                _entry("ZeroGravityFactory", address(network)),
                ",",
                _entry("ZeroGravityFactoryBeacon", address(factoryBeacon)),
                ",",
                _entry("ZeroGravityMiddleware", address(middleware)),
                ",",
                _entry("ZeroGravityMiddlewareBeacon", address(middlewareBeacon)),
                ",",
                _entry("OperatorBeacon", address(operatorBeacon))
            )
        );
    }

    // ---- address book ----------------------------------------------------------------------

    function test_ethBeacons_matchesDeploymentRecords() public {
        address[] memory beacons = ethBeacons();
        assertEq(beacons.length, 3);
        assertEq(beacons[0], address(factoryBeacon));
        assertEq(beacons[1], address(middlewareBeacon));
        assertEq(beacons[2], address(operatorBeacon));
    }

    function test_ethAccessControlled_matchesDeploymentRecords() public {
        (address factory, address mw) = ethAccessControlled();
        assertEq(factory, address(network));
        assertEq(mw, address(middleware));
    }

    /// @dev The role constants are hard-coded in the script; these assertions fail loudly if a
    ///      contract ever renames one.
    function test_roleConstantsMatchTheDeployedContracts() public view {
        assertEq(UPDATE_COLLATERAL_ROLE, network.UPDATE_COLLATERAL_ROLE());
        assertEq(SLASHER_ROLE, middleware.SLASHER_ROLE());
        assertEq(WEIGHT_SET_ROLE, middleware.WEIGHT_SET_ROLE());
        assertEq(PAUSER_ROLE, keccak256("PAUSER_ROLE"));
    }

    // ---- handover --------------------------------------------------------------------------

    function test_transferEthBeacons_movesEveryUpgradeKey() public {
        transferEthBeacons(safe);

        assertEq(factoryBeacon.owner(), safe);
        assertEq(middlewareBeacon.owner(), safe);
        assertEq(operatorBeacon.owner(), safe);
    }

    function test_transferEthBeacons_rejectsNonEthereumChain() public {
        vm.chainId(16_661);
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, 16_661, 1));
        this.transferEthBeacons(safe);
    }

    function test_transferEthBeacons_rejectsAnOwnerWithNoCode() public {
        address typo = makeAddr("typoNotAContract");

        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, typo));
        this.transferEthBeacons(typo);

        assertEq(factoryBeacon.owner(), deployer);
    }

    function test_grantEthAdmins_grantsAllSixRoles() public {
        grantEthAdmins(safe);

        assertTrue(network.hasRole(DEFAULT_ADMIN_ROLE, safe));
        assertTrue(network.hasRole(UPDATE_COLLATERAL_ROLE, safe));
        assertTrue(network.hasRole(PAUSER_ROLE, safe));
        assertTrue(middleware.hasRole(DEFAULT_ADMIN_ROLE, safe));
        assertTrue(middleware.hasRole(SLASHER_ROLE, safe));
        assertTrue(middleware.hasRole(WEIGHT_SET_ROLE, safe));
    }

    function test_revokeEthDeployer_stripsEveryDeployerRole() public {
        grantEthAdmins(safe);
        revokeEthDeployer(safe);

        assertFalse(network.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(network.hasRole(UPDATE_COLLATERAL_ROLE, deployer));
        assertFalse(network.hasRole(PAUSER_ROLE, deployer));
        assertFalse(middleware.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(middleware.hasRole(SLASHER_ROLE, deployer));
        assertFalse(middleware.hasRole(WEIGHT_SET_ROLE, deployer));

        assertTrue(network.hasRole(DEFAULT_ADMIN_ROLE, safe));
        assertTrue(middleware.hasRole(SLASHER_ROLE, safe));
    }

    /// @dev The revoked account comes from the signing key, so an unrelated admin - here the
    ///      fixture itself - keeps its roles.
    function test_revokeEthDeployer_onlyTouchesTheSigningKey() public {
        grantEthAdmins(safe);
        revokeEthDeployer(safe);

        assertTrue(network.hasRole(DEFAULT_ADMIN_ROLE, address(this)));
        assertFalse(network.hasRole(DEFAULT_ADMIN_ROLE, deployer));
    }

    /// @dev The factory holds this role on the middleware so it can register operators; a handover
    ///      that touched it would break validator registration.
    function test_handoverLeavesTheFactorysRegisterOperatorRoleAlone() public {
        bytes32 registerOperatorRole = middleware.REGISTER_OPERATOR_ROLE();
        assertTrue(middleware.hasRole(registerOperatorRole, address(network)));

        grantEthAdmins(safe);
        revokeEthDeployer(safe);

        assertTrue(middleware.hasRole(registerOperatorRole, address(network)));
        assertFalse(middleware.hasRole(registerOperatorRole, safe));
    }

    function test_revokeEthDeployer_revertsWhenMultisigIsNotAdminYet() public {
        vm.expectRevert(abi.encodeWithSelector(AdminNotHandedOver.selector, address(network), safe));
        this.revokeEthDeployer(safe);

        assertTrue(network.hasRole(PAUSER_ROLE, deployer));
    }

    /// @dev Proves the multisig can actually use what it was handed: pausing the factory is the
    ///      one privileged action that has to work under time pressure.
    function test_multisigCanExerciseTheRolesAfterHandover() public {
        grantEthAdmins(safe);
        revokeEthDeployer(safe);

        vm.prank(safe);
        network.pause();
        assertTrue(network.paused());

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, PAUSER_ROLE)
        );
        network.unpause();

        vm.prank(safe);
        network.unpause();
        assertFalse(network.paused());
    }

    /// @dev Same question for the upgrade key: after the transfer the multisig owns the beacon and
    ///      the deployer cannot upgrade anything.
    function test_multisigOwnsTheUpgradeKeyAfterHandover() public {
        transferEthBeacons(safe);
        address newImpl = address(new MultisigStub());

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        operatorBeacon.upgradeTo(newImpl);

        vm.prank(safe);
        operatorBeacon.upgradeTo(newImpl);
        assertEq(operatorBeacon.implementation(), newImpl);
    }
}
