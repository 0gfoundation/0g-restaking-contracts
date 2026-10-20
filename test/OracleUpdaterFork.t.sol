// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {OracleUpdater} from "../src/ascend/OracleUpdater.sol";
import {IMellowOracle, IMellowSourceCore} from "../src/interfaces/IMellowSourceCore.sol";
import {IOracleUpdater} from "../src/interfaces/IOracleUpdater.sol";

import {AscendRouterScript} from "../script/deploy/Ascend.s.sol";

/// @dev Rehearses the mainnet handover against a fork of 0G mainnet: deploy, multisig grant, writes
///      through the updater, multisig revoke of the operator's direct role. Runs only when
///      ZG_FORK_RPC is set.
contract OracleUpdaterForkTest is Test, AscendRouterScript {
    bytes32 internal constant SET_VALUE_ROLE = keccak256("ORACLE:SET_VALUE_ROLE");

    address internal constant SOURCE_CORE = 0x4B3c2f55fa67679b382c979A082Df1B32079B4cB;
    address internal constant VAULT_ADMIN = 0xfc7350b0d7a358Db58875148faF3bDEAaFC82911;
    address internal constant OPERATOR = 0xc0412361882961570d79CE535cB26Fc71bf363A7;

    IAccessControlEnumerable internal core = IAccessControlEnumerable(SOURCE_CORE);
    IMellowOracle internal oracle;
    OracleUpdater internal updater;

    function setUp() public {
        string memory rpc = vm.envOr("ZG_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        oracle = IMellowSourceCore(SOURCE_CORE).oracle();

        (, address beacon, address proxy) = deployOracleUpdaterContracts(SOURCE_CORE, VAULT_ADMIN, OPERATOR);
        checkOracleUpdater(proxy, beacon, SOURCE_CORE, VAULT_ADMIN, OPERATOR, address(this));
        updater = OracleUpdater(proxy);
    }

    function test_Handover() public {
        uint256 current = oracle.value();
        uint256 nav = updater.maxValue();
        assertGe(nav, current);

        // Before the grant the updater cannot write.
        vm.prank(OPERATOR);
        vm.expectRevert("Oracle: forbidden");
        updater.setValue(current);

        // Multisig transaction 1.
        vm.prank(VAULT_ADMIN);
        core.grantRole(SET_VALUE_ROLE, address(updater));

        vm.warp(block.timestamp + 8 hours);
        vm.prank(OPERATOR);
        updater.setValue(current);
        assertEq(oracle.value(), current);
        assertEq(oracle.lastUpdated(), block.timestamp);

        vm.prank(OPERATOR);
        updater.setValue(nav);
        assertEq(oracle.value(), nav);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueDecrease.selector, nav, nav - 1));
        updater.setValue(nav - 1);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueAboveNav.selector, nav, nav + 1));
        updater.setValue(nav + 1);

        // Multisig transaction 2.
        vm.prank(VAULT_ADMIN);
        core.revokeRole(SET_VALUE_ROLE, OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert("Oracle: forbidden");
        oracle.setValue(nav);

        vm.prank(OPERATOR);
        updater.setValue(nav);

        assertEq(core.getRoleMemberCount(SET_VALUE_ROLE), 2);
        assertTrue(core.hasRole(SET_VALUE_ROLE, VAULT_ADMIN));
        assertTrue(core.hasRole(SET_VALUE_ROLE, address(updater)));

        // The multisig keeps the only path down.
        vm.prank(VAULT_ADMIN);
        oracle.setValue(nav - 1);
        assertEq(oracle.value(), nav - 1);
    }
}
