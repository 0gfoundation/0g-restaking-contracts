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
        bytes[][] memory stakeHints = _stakeHints(pubkey, timestamp);
        middleware.distributeRewards(pubkey, timestamp, token, amount, stakeHints);
    }

    function _claimable(IDefaultStakerRewards rewards, address user) internal view returns (uint256) {
        return rewards.claimable(address(zgtoken), user, abi.encode(address(network), type(uint256).max));
    }

    function _getRewardContracts(
        bytes memory pubkey
    ) internal view returns (IDefaultStakerRewards[] memory) {
        address operator = middleware.operatorByKey(pubkey);
        address[] memory vaults = reader.activeOperatorVaultsAt(uint48(block.timestamp), operator);
        IDefaultStakerRewards[] memory rewarders = new IDefaultStakerRewards[](vaults.length);
        for (uint256 i = 0; i < vaults.length; ++i) {
            rewarders[i] = IDefaultStakerRewards(network.getRewarder(vaults[i]));
        }
        return rewarders;
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
        network.createValidator("alice", "", alice, address(zgtoken), 16 * 1e18);
        network.createValidator("alice", "", alice, address(eth), 16 * 1e17);
        vm.stopPrank();
        // activate operators
        vm.warp(block.timestamp + 2);
        IVault zgVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey("alice"))[0]);
        IVault ethVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey("alice"))[1]);
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
        bytes[][] memory stakeHints = _stakeHints("alice", uint48(block.timestamp));
        bytes[] memory slashHints = new bytes[](2);
        middleware.slash(uint48(block.timestamp - 5), "alice", 18 * 1e18, stakeHints, slashHints);
        vm.warp(block.timestamp + VETO_DURATION + 1);
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

    function testDistributeRewards() public {
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
        network.createValidator("alice", "", alice, address(zgtoken), 16 * 1e18);
        network.createValidator("alice", "", alice, address(eth), 16 * 1e17);
        vm.stopPrank();
        // activate operators
        vm.warp(block.timestamp + 2);
        IVault zgVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey("alice"))[0]);
        IVault ethVault = IVault(reader.activeOperatorVaults(middleware.operatorByKey("alice"))[1]);
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

        // distribute reward with timestamp 5 seconds ago
        IDefaultStakerRewards[] memory rewards = _getRewardContracts("alice");
        zgtoken.approve(address(middleware), type(uint256).max);
        _distributeRewards("alice", address(zgtoken), 10 * 1e18, uint48(block.timestamp - 5));
        assertEq(_claimable(rewards[0], alice), 5 * 1e18);
        assertEq(_claimable(rewards[0], bob), 0);
        assertEq(_claimable(rewards[1], alice), 5 * 1e18);
        assertEq(_claimable(rewards[1], bob), 0);
        vm.warp(block.timestamp + 5);
        _distributeRewards("alice", address(zgtoken), 18 * 1e18, uint48(block.timestamp - 1));
        assertEq(_claimable(rewards[0], alice), 8 * 1e18);
        assertEq(_claimable(rewards[0], bob), 6 * 1e18);
        assertEq(_claimable(rewards[0], alice), 8 * 1e18);
        assertEq(_claimable(rewards[0], bob), 6 * 1e18);
    }
}
