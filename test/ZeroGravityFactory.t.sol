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
            network.createValidator(
                bytes.concat(abi.encode(i), new bytes(16)),
                new bytes(32),
                new bytes(96),
                val,
                address(zgtoken),
                32 * 1e18
            );
            vm.stopPrank();
            operators[i] = middleware.operatorByKey(bytes.concat(abi.encode(i), new bytes(16)));
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
            network.createValidator(
                bytes.concat(abi.encode(i), new bytes(16)), new bytes(32), new bytes(96), val, address(eth), 1 * 1e18
            );
            vm.stopPrank();
            address operator = middleware.operatorByKey(bytes.concat(abi.encode(i), new bytes(16)));
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

    function test_CreateValidatorByAdmin() public {
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        network.createValidator(new bytes(48), new bytes(32), new bytes(96), address(this), address(zgtoken), 0);
    }

    function test_CreateValidatorRevertInvalidCollateral() public {
        address val = makeAddr("validator#0");
        _topUpTokens(val);
        vm.expectRevert(IZeroGravityFactory.InvalidCollateral.selector);
        vm.startPrank(val);
        network.createValidator(new bytes(48), new bytes(32), new bytes(96), address(val), address(zgtoken), 32 * 1e18);
        vm.stopPrank();
    }

    function test_CreateValidatorRevertInsufficientCollateral() public {
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        address val = makeAddr("validator#0");
        _topUpTokens(val);
        vm.expectRevert(IZeroGravityFactory.InsufficientCollateral.selector);
        vm.startPrank(val);
        network.createValidator(new bytes(48), new bytes(32), new bytes(96), address(val), address(zgtoken), 16 * 1e18);
        vm.stopPrank();
    }

    function test_CreateValidatorResubmitSignature() public {
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        address val = makeAddr("validator#0");
        _topUpTokens(val);
        vm.startPrank(val);
        network.createValidator(new bytes(48), new bytes(32), new bytes(96), address(val), address(zgtoken), 32 * 1e18);
        vm.stopPrank();

        val = makeAddr("validator#1");
        _topUpTokens(val);
        vm.startPrank(val);
        network.createValidator(new bytes(48), new bytes(32), new bytes(96), address(val), address(zgtoken), 32 * 1e18);
        vm.stopPrank();
    }

    // ─── Satellite chain admin tests ────────────────────────────────────

    function test_AddSatelliteChain() public {
        // Set up a collateral so we can verify weight snapshot events
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        middleware.setCollateralWeight(address(zgtoken), 1e18);

        uint256 chainId = 12_345;
        IZeroGravityFactory.SatelliteChainParams memory params = IZeroGravityFactory.SatelliteChainParams({
            chainType: IZeroGravityFactory.ChainType.EVM,
            rewarderFactory: address(0xdead),
            rewarderInitCodeHash: bytes32(uint256(1)),
            customMetadata: "test"
        });

        vm.expectEmit(true, false, false, true);
        emit IZeroGravityFactory.SatelliteWeightSnapshot(chainId, address(zgtoken), 1e18);

        network.addSatelliteChain(chainId, params);

        assertTrue(network.isSatelliteChain(chainId));
        assertFalse(network.isSatelliteChain(99_999));

        IZeroGravityFactory.SatelliteChainParams memory stored = network.getSatelliteChainParams(chainId);
        assertEq(uint8(stored.chainType), uint8(IZeroGravityFactory.ChainType.EVM));
        assertEq(stored.rewarderFactory, address(0xdead));
        assertEq(stored.rewarderInitCodeHash, bytes32(uint256(1)));
        assertEq(stored.customMetadata, "test");
    }

    function test_AddSatelliteChainMultiCollateralWeights() public {
        // Set up two collaterals with different weights
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        middleware.setCollateralWeight(address(zgtoken), 1e18);
        network.updateCollateralConfig(address(eth), 1 * 1e18);
        middleware.setCollateralWeight(address(eth), 10 * 1e18);

        uint256 chainId = 42;
        IZeroGravityFactory.SatelliteChainParams memory params = IZeroGravityFactory.SatelliteChainParams({
            chainType: IZeroGravityFactory.ChainType.EVM,
            rewarderFactory: address(0xdead),
            rewarderInitCodeHash: bytes32(uint256(1)),
            customMetadata: ""
        });

        vm.expectEmit(true, false, false, true);
        emit IZeroGravityFactory.SatelliteWeightSnapshot(chainId, address(zgtoken), 1e18);
        vm.expectEmit(true, false, false, true);
        emit IZeroGravityFactory.SatelliteWeightSnapshot(chainId, address(eth), 10 * 1e18);

        network.addSatelliteChain(chainId, params);
    }

    function test_UpdateSatelliteChainParams() public {
        uint256 chainId = 12_345;
        IZeroGravityFactory.SatelliteChainParams memory params = IZeroGravityFactory.SatelliteChainParams({
            chainType: IZeroGravityFactory.ChainType.EVM,
            rewarderFactory: address(0xdead),
            rewarderInitCodeHash: bytes32(uint256(1)),
            customMetadata: "original"
        });
        network.addSatelliteChain(chainId, params);

        IZeroGravityFactory.SatelliteChainParams memory updated = IZeroGravityFactory.SatelliteChainParams({
            chainType: IZeroGravityFactory.ChainType.EVM,
            rewarderFactory: address(0xbeef),
            rewarderInitCodeHash: bytes32(uint256(2)),
            customMetadata: "updated"
        });
        network.updateSatelliteChainParams(chainId, updated);

        IZeroGravityFactory.SatelliteChainParams memory stored = network.getSatelliteChainParams(chainId);
        assertEq(stored.rewarderFactory, address(0xbeef));
        assertEq(stored.rewarderInitCodeHash, bytes32(uint256(2)));
        assertEq(stored.customMetadata, "updated");
    }

    // ─── Satellite validator tests ──────────────────────────────────────

    function _createMainChainValidator(
        bytes memory pubkey
    ) internal {
        network.updateCollateralConfig(address(zgtoken), 32 * 1e18);
        middleware.setCollateralWeight(address(zgtoken), 1e18);
        address val = makeAddr("validator#satellite");
        _topUpTokens(val);
        vm.startPrank(val);
        network.createValidator(pubkey, new bytes(32), new bytes(96), val, address(zgtoken), 32 * 1e18);
        vm.stopPrank();
    }

    function _addSatelliteChain(
        uint256 chainId
    ) internal {
        IZeroGravityFactory.SatelliteChainParams memory params = IZeroGravityFactory.SatelliteChainParams({
            chainType: IZeroGravityFactory.ChainType.EVM,
            rewarderFactory: address(rewarderFactory),
            rewarderInitCodeHash: rewarderFactory.rewarderInitCodeHash(),
            customMetadata: ""
        });
        network.addSatelliteChain(chainId, params);
    }

    function test_CreateSatelliteValidator() public {
        bytes memory pubkey = new bytes(48);
        uint256 chainId = 42;

        _createMainChainValidator(pubkey);
        _addSatelliteChain(chainId);

        // Warp so vaults become active at the capture timestamp
        vm.warp(block.timestamp + 2);

        bytes memory satInfo = abi.encode("satellite-info");
        bytes memory sig = new bytes(96);

        address operator = middleware.operatorByKey(pubkey);
        address vault = reader.activeOperatorVaults(operator)[0];

        vm.expectEmit(true, false, false, true);
        emit IZeroGravityFactory.SatelliteValidatorCreated(
            chainId, pubkey, sig, satInfo, rewarderFactory.previewRewarder(pubkey)
        );
        vm.expectEmit(true, false, false, true);
        emit IZeroGravityFactory.SatelliteBalanceSnapshot(chainId, pubkey, vault, address(zgtoken), 32 * 1e18);

        network.createSatelliteValidator(pubkey, chainId, sig, satInfo);
    }

    function test_CreateSatelliteValidatorMultiCollateral() public {
        bytes memory pubkey = new bytes(48);
        uint256 chainId = 42;

        // Create main chain validator with zgtoken
        _createMainChainValidator(pubkey);

        // Add eth collateral and create a second vault for the same validator
        network.updateCollateralConfig(address(eth), 1 * 1e18);
        middleware.setCollateralWeight(address(eth), 10 * 1e18);
        address val = makeAddr("validator#satellite");
        _topUpTokens(val);
        vm.startPrank(val);
        network.createValidator(pubkey, new bytes(32), new bytes(96), val, address(eth), 1 * 1e18);
        vm.stopPrank();

        _addSatelliteChain(chainId);

        // Warp so vaults become active at the capture timestamp
        vm.warp(block.timestamp + 2);

        address operator = middleware.operatorByKey(pubkey);
        address[] memory vaults = reader.activeOperatorVaults(operator);
        assertEq(vaults.length, 2);

        bytes memory satInfo = abi.encode("multi-collateral");
        bytes memory sig = new bytes(96);

        // Expect snapshot events for both collaterals
        vm.expectEmit(true, false, false, true);
        emit IZeroGravityFactory.SatelliteValidatorCreated(
            chainId, pubkey, sig, satInfo, rewarderFactory.previewRewarder(pubkey)
        );
        vm.expectEmit(true, false, false, true);
        emit IZeroGravityFactory.SatelliteBalanceSnapshot(chainId, pubkey, vaults[0], address(zgtoken), 32 * 1e18);
        vm.expectEmit(true, false, false, true);
        emit IZeroGravityFactory.SatelliteBalanceSnapshot(chainId, pubkey, vaults[1], address(eth), 1 * 1e18);

        network.createSatelliteValidator(pubkey, chainId, sig, satInfo);
    }

    function test_CreateSatelliteValidatorResubmit() public {
        bytes memory pubkey = new bytes(48);
        uint256 chainId = 42;

        _createMainChainValidator(pubkey);
        _addSatelliteChain(chainId);

        bytes memory satInfo1 = abi.encode("info-v1");
        network.createSatelliteValidator(pubkey, chainId, new bytes(96), satInfo1);

        bytes memory satInfo2 = abi.encode("info-v2");
        network.createSatelliteValidator(pubkey, chainId, new bytes(96), satInfo2);
    }

    function test_CreateSatelliteValidatorMultipleChains() public {
        bytes memory pubkey = new bytes(48);
        uint256 chainA = 100;
        uint256 chainB = 200;

        _createMainChainValidator(pubkey);
        _addSatelliteChain(chainA);
        _addSatelliteChain(chainB);

        bytes memory infoA = abi.encode("chain-A");
        bytes memory infoB = abi.encode("chain-B");

        network.createSatelliteValidator(pubkey, chainA, new bytes(96), infoA);
        network.createSatelliteValidator(pubkey, chainB, new bytes(96), infoB);
    }

    function test_CreateSatelliteValidatorRevertInvalidSatelliteChain() public {
        bytes memory pubkey = new bytes(48);
        _createMainChainValidator(pubkey);

        vm.expectRevert(IZeroGravityFactory.InvalidSatelliteChain.selector);
        network.createSatelliteValidator(pubkey, 99_999, new bytes(96), "info");
    }

    function test_CreateSatelliteValidatorRevertMainChainValidatorNotFound() public {
        uint256 chainId = 42;
        _addSatelliteChain(chainId);

        vm.expectRevert(IZeroGravityFactory.MainChainValidatorNotFound.selector);
        network.createSatelliteValidator(new bytes(48), chainId, new bytes(96), "info");
    }

    function test_CreateSatelliteValidatorRevertInvalidPubKeyLength() public {
        vm.expectRevert(IZeroGravityFactory.InvalidPubKeyLength.selector);
        network.createSatelliteValidator(new bytes(32), 42, new bytes(96), "info");
    }

    function test_CreateSatelliteValidatorRevertInvalidSignatureLength() public {
        vm.expectRevert(IZeroGravityFactory.InvalidSignatureLength.selector);
        network.createSatelliteValidator(new bytes(48), 42, new bytes(64), "info");
    }
}
