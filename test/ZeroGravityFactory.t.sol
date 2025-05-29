// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {console2} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IZeroGravityFactory} from "../src/interfaces/IZeroGravityFactory.sol";

import {ZeroGravityBaseTest} from "./ZeroGravityBase.t.sol";

contract ZeroGravityFactoryTest is ZeroGravityBaseTest {
    using Strings for uint256;

    function setUp() public override {
        super.setUp();
    }

    function _topUpCollateral(
        address val
    ) internal {
        collateral.transfer(val, 32 * 1e18);
        vm.deal(val, 1 ether);
        vm.startPrank(val);
        collateral.approve(address(network), type(uint256).max);
        vm.stopPrank();
    }

    function test_CreateValidators() public {
        uint256 valCnt = 10;
        // update collateral config
        network.updateCollateralConfig(address(collateral), 32 * 1e18);
        // create validators
        assertEq(middleware.getCaptureTimestamp(), middleware.getEpochStart(0));
        address[] memory vals = new address[](valCnt);
        address[] memory operators = new address[](valCnt);
        for (uint256 i = 0; i < valCnt; ++i) {
            address val = makeAddr(string.concat("validator#", i.toString()));
            vals[i] = val;
            _topUpCollateral(val);
            vm.startPrank(val);
            network.createValidator(abi.encode(i), "", address(collateral), 32 * 1e18);
            vm.stopPrank();
            operators[i] = middleware.operatorByKey(abi.encode(i));
            assertTrue(reader.isOperatorRegistered(operators[i]), string.concat("operator not registered: #", i.toString()));
            assertEq(reader.operatorVaultsLength(operators[i]), 1);
        }
        vm.warp(block.timestamp + MIDDLEWARE_EPOCH_DURATION);
        assertEq(middleware.getCaptureTimestamp(), middleware.getEpochStart(1));
        // check states
        assertEq(reader.SLASHING_WINDOW(), _middlewareInitParams().slashingWindow);
        assertEq(reader.VAULT_REGISTRY(), _middlewareInitParams().vaultRegistry);
        assertEq(reader.OPERATOR_REGISTRY(), _middlewareInitParams().operatorRegistry);
        assertEq(reader.OPERATOR_NET_OPTIN(), _middlewareInitParams().operatorNetOptin);
        assertEq(reader.operatorsLength(), valCnt);
        assertEq(reader.activeOperators(), operators);
        assertEq(reader.activeOperatorsAt(uint48(block.timestamp - MIDDLEWARE_EPOCH_DURATION)), new address[](0));
        assertEq(reader.subnetworksLength(), 1);
        assertEq(reader.activeSubnetworks()[0], 0);
        assertEq(reader.sharedVaultsLength(), 0);
        assertEq(reader.activeVaults().length, valCnt);
        for (uint256 i = 0; i < valCnt; ++i) {
            address vault = reader.activeOperatorVaults(operators[i])[0];
            assertEq(collateral.balanceOf(vals[i]), 0);
            assertEq(collateral.balanceOf(vault), 32 * 1e18);
            assertEq(reader.getOperatorPower(operators[i]), 32 * 1e18);
        }
        assertEq(collateral.balanceOf(address(network)), 0);
        assertEq(collateral.balanceOf(address(middleware)), 0);
    }

    function test_CreateValidatorRevertInvalidCollateral() public {
        address val = makeAddr("validator#0");
        _topUpCollateral(val);
        vm.expectRevert(IZeroGravityFactory.InvalidCollateral.selector);
        vm.startPrank(val);
        network.createValidator(abi.encode(0), "", address(collateral), 32 * 1e18);
        vm.stopPrank();
    }

    function test_CreateValidatorRevertInsufficientCollateral() public {
        network.updateCollateralConfig(address(collateral), 32 * 1e18);
        address val = makeAddr("validator#0");
        _topUpCollateral(val);
        vm.expectRevert(IZeroGravityFactory.InsufficientCollateral.selector);
        vm.startPrank(val);
        network.createValidator(abi.encode(0), "", address(collateral), 16 * 1e18);
        vm.stopPrank();
    }
    
    function test_CreateValidatorRevertOperatorCreated() public {
        network.updateCollateralConfig(address(collateral), 32 * 1e18);
        address val = makeAddr("validator#0");
        _topUpCollateral(val);
        vm.startPrank(val);
        network.createValidator(abi.encode(0), "", address(collateral), 32 * 1e18);
        vm.stopPrank();

        val = makeAddr("validator#1");
        _topUpCollateral(val);
        vm.expectRevert(IZeroGravityFactory.OperatorCreated.selector);
        vm.startPrank(val);
        network.createValidator(abi.encode(0), "", address(collateral), 32 * 1e18);
        vm.stopPrank();
    }
}
