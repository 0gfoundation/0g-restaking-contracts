// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {OracleUpdater} from "../src/ascend/OracleUpdater.sol";

import {AscendRouterScript} from "../script/deploy/Ascend.s.sol";

import {MockMellowSourceCore} from "./mocks/MockMellowSourceCore.sol";
import {Token} from "./mocks/Token.sol";

contract AdminMultisigStub {}

contract OracleUpdaterScriptTest is Test, AscendRouterScript {
    // A chain id of its own keeps this record apart from the ascend record Ownership.t.sol writes
    // into the same directory.
    uint256 internal constant CHAIN_ID = 99_661;

    string internal path;
    address internal deployer;
    address internal safe;
    address internal operator;
    MockMellowSourceCore internal core;

    function setUp() public {
        vm.chainId(CHAIN_ID);

        // The directory and the label-derived key are the values Ownership.t.sol sets: both are
        // process-wide environment variables, and the suites may run concurrently.
        string memory dir = string.concat(vm.projectRoot(), "/out/ownership-test");
        vm.createDir(dir, true);
        vm.setEnv("DEPLOYMENT_PATH", dir);
        uint256 deployerKey;
        (deployer, deployerKey) = makeAddrAndKey("zgDeployer");
        vm.setEnv("PRIVATE_KEY_0G", vm.toString(deployerKey));

        safe = address(new AdminMultisigStub());
        operator = makeAddr("operator");
        Token w0g = new Token("W0G");
        core = new MockMellowSourceCore(w0g, makeAddr("adapter"), makeAddr("queue"), safe);
        w0g.approve(address(core), 1 ether);
        core.deposit(1 ether);

        path = string.concat(dir, "/ascend-", vm.toString(CHAIN_ID), ".json");
        vm.writeFile(
            path,
            string.concat(
                '{"AscendRouter":"0x4af366C80Eb17F24923fE956Cc21A11A6864B33a",',
                '"MellowVaultPercentage":900000000000000000,',
                '"MellowVault":"',
                vm.toString(address(core)),
                '","OracleUpdaterAdmin":"',
                vm.toString(safe),
                '","OracleUpdaterOperator":"',
                vm.toString(operator),
                '"}'
            )
        );
    }

    function test_DeployOracleUpdater() public {
        deployOracleUpdater();

        string memory json = vm.readFile(path);
        OracleUpdater updater = OracleUpdater(vm.parseJsonAddress(json, ".OracleUpdater"));
        UpgradeableBeacon beacon = UpgradeableBeacon(vm.parseJsonAddress(json, ".OracleUpdaterBeacon"));

        assertEq(beacon.implementation(), vm.parseJsonAddress(json, ".OracleUpdaterImpl"));
        assertEq(beacon.owner(), safe);
        assertEq(address(updater.sourceCore()), address(core));
        assertTrue(updater.hasRole(updater.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(updater.hasRole(updater.UPDATER_ROLE(), operator));
        assertFalse(updater.hasRole(updater.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(updater.hasRole(updater.UPDATER_ROLE(), deployer));

        // Existing entries survive the rewrite, numbers included.
        assertEq(vm.parseJsonAddress(json, ".AscendRouter"), 0x4af366C80Eb17F24923fE956Cc21A11A6864B33a);
        assertEq(vm.parseJsonUint(json, ".MellowVaultPercentage"), 900_000_000_000_000_000);
        assertEq(vm.parseJsonAddress(json, ".OracleUpdaterOperator"), operator);
    }

    function test_DeployRejectsEoaAdmin() public {
        string memory json = vm.readFile(path);
        vm.writeFile(path, vm.replace(json, vm.toString(safe), vm.toString(makeAddr("eoaAdmin"))));
        vm.expectRevert("OracleUpdaterAdmin must be a multisig contract");
        this.deployOracleUpdater();
    }
}
