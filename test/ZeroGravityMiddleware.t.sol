// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console2} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";

import {IZeroGravityFactory} from "../src/interfaces/IZeroGravityFactory.sol";
import {ZeroGravityBaseTest} from "./ZeroGravityBase.t.sol";

import {IDefaultStakerRewards} from "rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";

contract ZeroGravityMiddlewareTest is ZeroGravityBaseTest {
    using Strings for uint256;

    function setUp() public override {
        super.setUp();
    }

    function _distributeRewards(bytes memory pubkey, address token, uint256 amount, uint48 timestamp) internal {
        bytes[][] memory stakeHints = new bytes[][](1);
        stakeHints[0] = new bytes[](1);
        middleware.distributeRewards(pubkey, timestamp, token, amount, stakeHints);
    }

    function _claimable(IDefaultStakerRewards rewards, address user) internal view returns (uint256) {
        return rewards.claimable(address(zgtoken), user, abi.encode(address(network), type(uint256).max));
    }

    function _getRewardContract(
        bytes memory pubkey
    ) internal view returns (IDefaultStakerRewards) {
        address operator = middleware.operatorByKey(pubkey);
        address[] memory vaults = middleware.activeOperatorVaults(uint48(block.timestamp), operator);
        address rewarder = network.getRewarder(vaults[0]);
        return IDefaultStakerRewards(rewarder);
    }

    function testSlash() public {
        // setup, create validator for alice & bob
        network.updateCollateralConfig(address(zgtoken), 16 * 1e18);
        middleware.setCollateralWeight(address(zgtoken), 1e18);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _topUpTokens(alice);
        _topUpTokens(bob);
        // alice deposit 16
        vm.startPrank(alice);
        network.createValidator("alice", "", alice, address(zgtoken), 16 * 1e18);
        vm.stopPrank();
        // activate operators
        vm.warp(block.timestamp + 2);
        IVault aliceVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey("alice"))[0]);
        assertEq(aliceVault.currentEpoch(), 0);
        // move to 10 seconds later, bob deposit 32
        vm.warp(block.timestamp + 10);
        vm.startPrank(bob);
        zgtoken.approve(address(aliceVault), 32 * 1e18);
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

    function testDistributeRewards() public {
        // setup, create validator for alice & bob
        network.updateCollateralConfig(address(zgtoken), 16 * 1e18);
        middleware.setCollateralWeight(address(zgtoken), 1e18);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _topUpTokens(alice);
        _topUpTokens(bob);
        // alice deposit 16
        vm.startPrank(alice);
        network.createValidator("alice", "", address(alice), address(zgtoken), 16 * 1e18);
        vm.stopPrank();
        // activate operators
        vm.warp(block.timestamp + 2);
        IVault aliceVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey("alice"))[0]);
        assertEq(aliceVault.currentEpoch(), 0);
        // move to 10 seconds later, bob deposit 32
        vm.warp(block.timestamp + 10);
        vm.startPrank(bob);
        zgtoken.approve(address(aliceVault), 32 * 1e18);
        aliceVault.deposit(bob, 32 * 1e18);
        vm.stopPrank();
        assertEq(aliceVault.activeBalanceOf(alice), 16 * 1e18);
        assertEq(aliceVault.activeBalanceOf(bob), 32 * 1e18);
        assertEq(aliceVault.activeBalanceOfAt(bob, uint48(block.timestamp - 5), ""), 0);
        assertEq(aliceVault.totalStake(), 48 * 1e18);
        assertEq(aliceVault.activeSharesOf(alice), 16 * 1e18);
        assertEq(aliceVault.activeSharesOf(bob), 32 * 1e18);
        assertEq(aliceVault.activeShares(), 48 * 1e18);
        // distribute reward with timestamp 5 seconds ago
        IDefaultStakerRewards rewards = _getRewardContract("alice");
        zgtoken.approve(address(middleware), type(uint256).max);
        _distributeRewards("alice", address(zgtoken), 10 * 1e18, uint48(block.timestamp - 5));
        assertEq(_claimable(rewards, alice), 10 * 1e18);
        assertEq(_claimable(rewards, bob), 0);
        vm.warp(block.timestamp + 5);
        _distributeRewards("alice", address(zgtoken), 9 * 1e18, uint48(block.timestamp - 1));
        assertEq(_claimable(rewards, alice), 13 * 1e18);
        assertEq(_claimable(rewards, bob), 6 * 1e18);
    }
}
