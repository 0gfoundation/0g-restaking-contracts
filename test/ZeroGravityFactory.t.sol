// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console2} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IZeroGravityFactory} from "../src/interfaces/IZeroGravityFactory.sol";

import {ZeroGravityBaseTest} from "./ZeroGravityBase.t.sol";

contract ZeroGravityFactoryTest is ZeroGravityBaseTest {
    using Strings for uint256;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_CreateValidators() public {
        uint256 valCnt = 10;
        // update collateral config
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        middleware.setCollateralWeight(address(zgtoken), 1e18);
        // create validators
        assertEq(middleware.getCaptureTimestamp(), block.timestamp - 1);
        address[] memory vals = new address[](valCnt);
        address[] memory operators = new address[](valCnt);
        for (uint256 i = 0; i < valCnt; ++i) {
            address val = makeAddr(string.concat("validator#", i.toString()));
            vals[i] = val;
            _topUpTokens(val);
            vm.startPrank(val);
            network.createValidator(abi.encode(i), "", "", val, address(zgtoken), 32 * 1e18);
            vm.stopPrank();
            operators[i] = middleware.operatorByKey(abi.encode(i));
            assertTrue(
                reader.isOperatorRegistered(operators[i]), string.concat("operator not registered: #", i.toString())
            );
            assertEq(reader.operatorVaultsLength(operators[i]), 1);
        }
        vm.warp(block.timestamp + 2);
        assertEq(middleware.getCaptureTimestamp(), block.timestamp - 1);
        // check states
        assertEq(reader.SLASHING_WINDOW(), _middlewareInitParams().slashingWindow);
        assertEq(reader.VAULT_REGISTRY(), _middlewareInitParams().vaultRegistry);
        assertEq(reader.OPERATOR_REGISTRY(), _middlewareInitParams().operatorRegistry);
        assertEq(reader.OPERATOR_NET_OPTIN(), _middlewareInitParams().operatorNetOptin);
        assertEq(reader.operatorsLength(), valCnt);
        assertEq(reader.activeOperators(), operators); // activeOperators() will use captureTimestamp(), which is block.timestamp - 1
        assertEq(reader.activeOperatorsAt(uint48(block.timestamp - 2)), new address[](0));
        assertEq(reader.subnetworksLength(), 1);
        assertEq(reader.activeSubnetworks()[0], 0);
        assertEq(reader.sharedVaultsLength(), 0);
        assertEq(reader.activeVaults().length, valCnt);
        for (uint256 i = 0; i < valCnt; ++i) {
            address vault = reader.activeOperatorVaults(operators[i])[0];
            assertEq(zgtoken.balanceOf(vals[i]), 0);
            assertEq(zgtoken.balanceOf(vault), 32 * 1e18);
            assertEq(reader.getOperatorPower(operators[i]), 32 * 1e18);
        }
        assertEq(zgtoken.balanceOf(address(network)), 0);
        assertEq(zgtoken.balanceOf(address(middleware)), 0);
        // update collateral config for eth
        network.updateCollateralConfig(address(eth), 1 * 1e18);
        middleware.setCollateralWeight(address(eth), 10 * 1e18);
        assertEq(middleware.getCaptureTimestamp(), block.timestamp - 1);
        for (uint256 i = 0; i < valCnt; ++i) {
            address val = vals[i];
            vm.startPrank(val);
            network.createValidator(abi.encode(i), "", "", val, address(eth), 1 * 1e18);
            vm.stopPrank();
            address operator = middleware.operatorByKey(abi.encode(i));
            assertEq(operators[i], operator);
            assertTrue(
                reader.isOperatorRegistered(operators[i]), string.concat("operator not registered: #", i.toString())
            );
            assertEq(reader.operatorVaultsLength(operators[i]), 2);
        }
        vm.warp(block.timestamp + 2);
        assertEq(middleware.getCaptureTimestamp(), block.timestamp - 1);
        // check states
        assertEq(reader.operatorsLength(), valCnt);
        assertEq(reader.activeOperators(), operators); // activeOperators() will use captureTimestamp(), which is block.timestamp - 1
        assertEq(reader.subnetworksLength(), 1);
        assertEq(reader.activeSubnetworks()[0], 0);
        assertEq(reader.sharedVaultsLength(), 0);
        assertEq(reader.activeVaults().length, valCnt * 2);
        for (uint256 i = 0; i < valCnt; ++i) {
            address vault = reader.activeOperatorVaults(operators[i])[1];
            assertEq(eth.balanceOf(vault), 1 * 1e18);
            assertEq(reader.getOperatorPower(operators[i]), 32 * 1e18 + 10 * 1e18);
        }
        assertEq(eth.balanceOf(address(network)), 0);
        assertEq(eth.balanceOf(address(middleware)), 0);
    }

    function test_CreateValidatorRevertInvalidCollateral() public {
        address val = makeAddr("validator#0");
        _topUpTokens(val);
        vm.expectRevert(IZeroGravityFactory.InvalidCollateral.selector);
        vm.startPrank(val);
        network.createValidator(abi.encode(0), "", "", address(val), address(zgtoken), 32 * 1e18);
        vm.stopPrank();
    }

    function test_CreateValidatorRevertInsufficientCollateral() public {
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        address val = makeAddr("validator#0");
        _topUpTokens(val);
        vm.expectRevert(IZeroGravityFactory.InsufficientCollateral.selector);
        vm.startPrank(val);
        network.createValidator(abi.encode(0), "", "", address(val), address(zgtoken), 16 * 1e18);
        vm.stopPrank();
    }

    function test_CreateValidatorRevertVaultCreated() public {
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        address val = makeAddr("validator#0");
        _topUpTokens(val);
        vm.startPrank(val);
        network.createValidator(abi.encode(0), "", "", address(val), address(zgtoken), 32 * 1e18);
        vm.stopPrank();

        val = makeAddr("validator#1");
        _topUpTokens(val);
        vm.expectRevert(IZeroGravityFactory.VaultCreated.selector);
        vm.startPrank(val);
        network.createValidator(abi.encode(0), "", "", address(val), address(zgtoken), 32 * 1e18);
        vm.stopPrank();
    }
}
