// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {RewarderFactory} from "../src/RewarderFactory.sol";
import {Rewarder} from "../src/Rewarder.sol";
import {RestakingStates} from "../src/RestakingStates.sol";
import {IRestakingStates} from "../src/interfaces/IRestakingStates.sol";

import {RewarderBaseTest} from "./RewarderBase.t.sol";

contract RewarderStatesTest is RewarderBaseTest {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_update() public {
        _initialRewarderStates();
        assertEq(restakingStates.getDomains(), DOMAIN_CNT);
        for (uint256 ops = 0; ops < 5000; ++ops) {
            uint256 domain = _nextRng() % DOMAIN_CNT;
            address rewarder = rewarders[_nextRng() % rewarders.length];
            address account = accounts[_nextRng() % accounts.length];
            address collateral = collaterals[_nextRng() % collaterals.length];
            if (_nextRng() % 2 == 0 && balances[domain][rewarder][account][collateral] > 0) {
                uint256 amount = _nextRng() % balances[domain][rewarder][account][collateral] + 1;
                restakingStates.withdraw(domain, 0, ops, rewarder, account, collateral, amount);
                balances[domain][rewarder][account][collateral] -= amount;
                supply[domain][rewarder][collateral] -= amount;
            } else {
                // [0, 100) with decimals
                uint256 amount = _nextRng() % 1e20 / (10 ** (18 - decimals[collateral])) + 1;
                restakingStates.deposit(domain, 0, ops, rewarder, account, collateral, amount);
                balances[domain][rewarder][account][collateral] += amount;
                supply[domain][rewarder][collateral] += amount;
            }
        }
        // check balances
        for (uint256 i = 0; i < REWARDER_CNT; ++i) {
            for (uint256 j = 0; j < ACCOUNTS_CNT; ++j) {
                RestakingStates.Balance[] memory ans = restakingStates.getBalances(rewarders[i], accounts[j]);
                for (uint256 k = 0; k < ans.length; ++k) {
                    assertEq(ans[k].amount, balances[ans[k].domain][rewarders[i]][accounts[j]][ans[k].collateral]);
                }
            }
        }
        // check powers
        for (uint256 i = 0; i < REWARDER_CNT; ++i) {
            (uint256 totalPower, RestakingStates.Power[] memory powers) = restakingStates.getPowers(rewarders[i]);
            uint256 total = 0;
            for (uint256 domain = 0; domain < DOMAIN_CNT; ++domain) {
                for (uint256 j = 0; j < COLLATERAL_CNT; ++j) {
                    uint256 power =
                        weights[domain][collaterals[j]] * supply[domain][rewarders[i]][collaterals[j]] / 1e18;
                    total += power;
                }
            }
            assertEq(total, totalPower);
            for (uint256 j = 0; j < powers.length; ++j) {
                uint256 power = weights[powers[j].supply.domain][powers[j].supply.collateral]
                    * supply[powers[j].supply.domain][rewarders[i]][powers[j].supply.collateral] / 1e18;
                assertEq(power, powers[j].power);
                assertEq(
                    supply[powers[j].supply.domain][rewarders[i]][powers[j].supply.collateral], powers[j].supply.amount
                );
            }
        }
    }

    function test_updateRevertDuplicateSubmission() public {
        _initialRewarderStates();
        restakingStates.deposit(0, 0, 0, rewarders[0], accounts[0], collaterals[0], 1);
        vm.expectRevert(IRestakingStates.ErrDuplicateSubmission.selector);
        restakingStates.deposit(0, 0, 0, rewarders[0], accounts[0], collaterals[0], 1);
        vm.expectRevert(IRestakingStates.ErrDuplicateSubmission.selector);
        restakingStates.withdraw(0, 0, 0, rewarders[0], accounts[0], collaterals[0], 1);
    }
}
