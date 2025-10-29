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

    function testSetSlashingWindow() public {
        assertEq(reader.SLASHING_WINDOW(), SLASHING_WINDOW());
        middleware.setSlashingWindow(100);
        assertEq(reader.SLASHING_WINDOW(), 100);
    }

    function testSlash() public {
        // setup, create validator for alice & bob
        network.updateCollateralConfig(address(zgtoken), 16 * 1e18);
        middleware.setCollateralWeight(address(zgtoken), 1e18);
        network.updateCollateralConfig(address(eth), 1 * 1e18);
        middleware.setCollateralWeight(address(eth), 10 * 1e18);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _topUpTokens(alice);
        _topUpTokens(bob);
        // alice deposit 16
        vm.startPrank(alice);
        bytes memory aliceKey = new bytes(48);
        network.createValidator(aliceKey, new bytes(32), new bytes(96), alice, address(zgtoken), 16 * 1e18);
        network.createValidator(aliceKey, new bytes(32), new bytes(96), alice, address(eth), 16 * 1e17);
        vm.stopPrank();
        // activate operators
        vm.warp(block.timestamp + 2);
        IVault zgVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey(aliceKey))[0]);
        IVault ethVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey(aliceKey))[1]);
        assertEq(zgVault.currentEpoch(), 0);
        // move to 10 seconds later, bob deposit 32
        vm.warp(block.timestamp + 10);
        vm.startPrank(bob);
        zgtoken.approve(address(zgVault), 32 * 1e18);
        zgVault.deposit(bob, 32 * 1e18);
        eth.approve(address(ethVault), 32 * 1e18);
        ethVault.deposit(bob, 32 * 1e17);
        vm.stopPrank();
        assertEq(zgVault.activeBalanceOf(alice), 16 * 1e18);
        assertEq(zgVault.activeBalanceOf(bob), 32 * 1e18);
        assertEq(zgVault.activeBalanceOfAt(bob, uint48(block.timestamp - 5), ""), 0);
        assertEq(zgVault.totalStake(), 48 * 1e18);
        assertEq(zgVault.activeSharesOf(alice), 16 * 1e18);
        assertEq(zgVault.activeSharesOf(bob), 32 * 1e18);
        assertEq(zgVault.activeShares(), 48 * 1e18);
        assertEq(ethVault.activeBalanceOf(alice), 16 * 1e17);
        assertEq(ethVault.activeBalanceOf(bob), 32 * 1e17);
        assertEq(ethVault.activeBalanceOfAt(bob, uint48(block.timestamp - 5), ""), 0);
        assertEq(ethVault.totalStake(), 48 * 1e17);
        assertEq(ethVault.activeSharesOf(alice), 16 * 1e17);
        assertEq(ethVault.activeSharesOf(bob), 32 * 1e17);
        assertEq(ethVault.activeShares(), 48 * 1e17);
        // request and execute slash, with slash timestamp 5 seconds ago
        bytes[][] memory stakeHints = _stakeHints(aliceKey, uint48(block.timestamp));
        bytes[] memory slashHints = new bytes[](2);
        bytes[] memory weightHints = new bytes[](2);
        middleware.slash(uint48(block.timestamp - 5), aliceKey, 18 * 1e18, stakeHints, slashHints, weightHints);
        vm.warp(block.timestamp + VETO_DURATION() + 1);
        // slash
        uint256[] memory indexes = new uint256[](2);
        bytes[] memory hints = new bytes[](2);
        middleware.executeSlashs(reader.activeVaults(), indexes, hints);
        assertEq(zgVault.activeBalanceOf(alice), 13 * 1e18);
        assertEq(zgVault.activeBalanceOf(bob), 26 * 1e18);
        assertEq(zgVault.totalStake(), 39 * 1e18);
        assertEq(zgVault.activeSharesOf(alice), 16 * 1e18);
        assertEq(zgVault.activeSharesOf(bob), 32 * 1e18);
        assertEq(zgVault.activeShares(), 48 * 1e18);
        assertEq(ethVault.activeBalanceOf(alice), 13 * 1e17);
        assertEq(ethVault.activeBalanceOf(bob), 26 * 1e17);
        assertEq(ethVault.totalStake(), 39 * 1e17);
        assertEq(ethVault.activeSharesOf(alice), 16 * 1e17);
        assertEq(ethVault.activeSharesOf(bob), 32 * 1e17);
        assertEq(ethVault.activeShares(), 48 * 1e17);
    }
}
