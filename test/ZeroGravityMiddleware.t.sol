// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console2} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";

import {IZeroGravityFactory} from "../src/interfaces/IZeroGravityFactory.sol";

import {ZeroGravityBaseTest} from "./ZeroGravityBase.t.sol";

contract ZeroGravityMiddlewareTest is ZeroGravityBaseTest {
    using Strings for uint256;

    function setUp() public override {
        super.setUp();
    }

    function testSlash() public {
        // setup, create validator for alice & bob
        network.updateCollateralConfig(address(collateral), 16 * 1e18);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _topUpCollateral(alice);
        _topUpCollateral(bob);
        // alice deposit 16
        vm.startPrank(alice);
        network.createValidator("alice", "", address(collateral), 16 * 1e18);
        vm.stopPrank();
        // activate operators
        vm.warp(block.timestamp + 2);
        IVault aliceVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey("alice"))[0]);
        assertEq(aliceVault.currentEpoch(), 0);
        // move to 10 seconds later, bob deposit 32
        vm.warp(block.timestamp + 10);
        vm.startPrank(bob);
        collateral.approve(address(aliceVault), 32 * 1e18);
        aliceVault.deposit(bob, 32 * 1e18);
        vm.stopPrank();
        assertEq(aliceVault.activeBalanceOf(alice), 16 * 1e18);
        assertEq(aliceVault.activeBalanceOf(bob), 32 * 1e18);
        assertEq(aliceVault.activeBalanceOfAt(bob, uint48(block.timestamp - 5), ""), 0);
        assertEq(aliceVault.totalStake(), 48 * 1e18);
        assertEq(aliceVault.activeSharesOf(alice), 16 * 1e18);
        assertEq(aliceVault.activeSharesOf(bob), 32 * 1e18);
        assertEq(aliceVault.activeShares(), 48 * 1e18);
        // request and execute slash, with slash timestamp 5 seconds ago
        bytes[][] memory stakeHints = new bytes[][](1);
        stakeHints[0] = new bytes[](1);
        bytes[] memory slashHints = new bytes[](1);
        middleware.slash(uint48(block.timestamp - 5), "alice", 9 * 1e18, stakeHints, slashHints);
        vm.warp(block.timestamp + VETO_DURATION + 1);
        middleware.executeSlash(address(aliceVault), 0, "");
        assertEq(aliceVault.activeBalanceOf(alice), 13 * 1e18);
        assertEq(aliceVault.activeBalanceOf(bob), 26 * 1e18);
        assertEq(aliceVault.totalStake(), 39 * 1e18);
        assertEq(aliceVault.activeSharesOf(alice), 16 * 1e18);
        assertEq(aliceVault.activeSharesOf(bob), 32 * 1e18);
        assertEq(aliceVault.activeShares(), 48 * 1e18);
    }
}
