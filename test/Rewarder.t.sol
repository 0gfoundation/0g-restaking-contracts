// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";

import {RewarderFactory} from "../src/RewarderFactory.sol";
import {Rewarder} from "../src/Rewarder.sol";
import {RestakingStates} from "../src/RestakingStates.sol";
import {IRestakingStates} from "../src/interfaces/IRestakingStates.sol";

import {RewarderBaseTest} from "./RewarderBase.t.sol";

contract RewarderTest is RewarderBaseTest {
    function setUp() public virtual override {
        DOMAIN_CNT = 2;
        COLLATERAL_CNT = 3;
        REWARDER_CNT = 3;
        ACCOUNTS_CNT = 10;
        super.setUp();
    }

    mapping(address => uint256) unclaimed;
    mapping(address => mapping(address => uint256)) rewards;

    function _update(
        address rewarder
    ) internal {
        uint256 pendingReward = rewarder.balance - unclaimed[rewarder];
        uint256 total = 0;
        for (uint256 domain = 0; domain < DOMAIN_CNT; ++domain) {
            for (uint256 j = 0; j < COLLATERAL_CNT; ++j) {
                uint256 power = weights[domain][collaterals[j]] * supply[domain][rewarder][collaterals[j]] / 1e18;
                total += power;
            }
        }
        if (total > 0) {
            for (uint256 i = 0; i < accounts.length; ++i) {
                uint256 power = 0;
                for (uint256 domain = 0; domain < DOMAIN_CNT; ++domain) {
                    for (uint256 j = 0; j < COLLATERAL_CNT; ++j) {
                        power += weights[domain][collaterals[j]]
                            * balances[domain][rewarder][accounts[i]][collaterals[j]] / 1e18;
                    }
                }
                if (power > 0 && pendingReward > 0) {
                    rewards[rewarder][accounts[i]] += pendingReward * power / total;
                }
            }
        }
        unclaimed[rewarder] += pendingReward;
    }

    function test_update() public {
        _initialRewarderStates();
        for (uint256 ops = 0; ops < 50_000;) {
            // distribute reward to one rewarder
            {
                address x = rewarders[_nextRng() % REWARDER_CNT];
                uint256 amount = x.balance + _nextRng() % (10 ** 18) * 1_000_000;
                vm.deal(x, amount);
            }

            // trigger ops
            uint256 domain = _nextRng() % DOMAIN_CNT;
            address rewarder = rewarders[_nextRng() % rewarders.length];
            address account = accounts[_nextRng() % accounts.length];
            uint256 cidx = _nextRng() % collaterals.length;
            address collateral = collaterals[cidx];
            uint256 op = _nextRng() % 4;
            if (op == 0 && balances[domain][rewarder][account][collateral] > 0) {
                // withdraw
                uint256 amount = _nextRng() % balances[domain][rewarder][account][collateral] + 1;

                restakingStates.withdraw(domain, bytes32(0), ops, rewarder, account, collateral, amount);
                _update(rewarder);

                balances[domain][rewarder][account][collateral] -= amount;
                supply[domain][rewarder][collateral] -= amount;

                ++ops;
            } else if (op == 1) {
                // deposit
                // [0, 100) with decimals
                uint256 amount = _nextRng() % 1e20 / (10 ** (18 - decimals[collateral])) + 1;

                restakingStates.deposit(domain, bytes32(0), ops, rewarder, account, collateral, amount);
                _update(rewarder);

                balances[domain][rewarder][account][collateral] += amount;
                supply[domain][rewarder][collateral] += amount;

                ++ops;
            } else if (op == 2) {
                // update weight
                weights[domain][collateral] = _alignedWeight(decimals[collateral], (_nextRng() % 10 + 1) * 1e9);
                restakingStates.updateWeight(domain, collateral, weights[domain][collateral]);

                ++ops;
            } else if (op == 3) {
                uint256 br = rewarder.balance;
                uint256 ba = account.balance;

                _update(rewarder);
                // claim, appoximate eq
                uint256 claimed = Rewarder(payable(rewarder)).claim(account);
                assertApproxEqRel(claimed, rewards[rewarder][account], 0.0001e18);
                rewards[rewarder][account] = claimed;

                rewards[rewarder][account] -= claimed;
                unclaimed[rewarder] -= claimed;

                assertEq(br, rewarder.balance + claimed);
                assertEq(ba, account.balance - claimed);

                ++ops;
            }
        }
        // claim all
        for (uint256 i = 0; i < rewarders.length; ++i) {
            address rewarder = rewarders[i];
            for (uint256 j = 0; j < accounts.length; ++j) {
                _update(rewarder);

                address account = accounts[j];

                uint256 br = rewarder.balance;
                uint256 ba = account.balance;
                // claim
                uint256 claimed = Rewarder(payable(rewarder)).claim(account);
                assertApproxEqRel(claimed, rewards[rewarder][account], 0.0001e18);
                rewards[rewarder][account] = claimed;

                rewards[rewarder][account] -= claimed;
                unclaimed[rewarder] -= claimed;

                assertEq(br, rewarder.balance + claimed);
                assertEq(ba, account.balance - claimed);
            }
        }
    }
}
