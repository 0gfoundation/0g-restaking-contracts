// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OracleUpdater} from "../src/ascend/OracleUpdater.sol";
import {IOracleUpdater} from "../src/interfaces/IOracleUpdater.sol";

import {MockMellowOracle, MockMellowSourceCore} from "./mocks/MockMellowSourceCore.sol";
import {Token} from "./mocks/Token.sol";

contract OracleUpdaterV2 is OracleUpdater {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract OracleUpdaterTest is Test {
    bytes32 internal constant SET_VALUE_ROLE = keccak256("ORACLE:SET_VALUE_ROLE");

    address internal safe = makeAddr("safe");
    address internal operator = makeAddr("operator");
    address internal adapter = makeAddr("adapter");
    address internal queue = makeAddr("queue");
    address internal user = makeAddr("user");

    Token internal w0g;
    MockMellowSourceCore internal core;
    MockMellowOracle internal oracle;
    UpgradeableBeacon internal beacon;
    OracleUpdater internal updater;

    function setUp() public {
        w0g = new Token("W0G");
        core = new MockMellowSourceCore(w0g, adapter, queue, safe);
        oracle = core.oracle();

        OracleUpdater impl = new OracleUpdater();
        beacon = new UpgradeableBeacon(address(impl), safe);
        updater = OracleUpdater(
            address(
                new BeaconProxy(
                    address(beacon), abi.encodeCall(OracleUpdater.initialize, (address(core), safe, operator))
                )
            )
        );

        // As on mainnet, the multisig keeps the oracle role alongside the updater.
        vm.startPrank(safe);
        core.grantRole(SET_VALUE_ROLE, safe);
        core.grantRole(SET_VALUE_ROLE, address(updater));
        vm.stopPrank();

        // 100 aOG at 1.0, 90 of the backing bridged out.
        _deposit(user, 100 ether);
        core.pushToTarget(90 ether);
    }

    function _deposit(address account, uint256 assets) internal {
        w0g.transfer(account, assets);
        vm.startPrank(account);
        w0g.approve(address(core), assets);
        core.deposit(assets);
        vm.stopPrank();
    }

    /// @dev Rewards arriving the way AscendRouter delivers them: W0G sent straight to the core.
    function _distribute(
        uint256 assets
    ) internal {
        w0g.transfer(address(core), assets);
    }

    function _set(
        uint256 value
    ) internal {
        vm.prank(operator);
        updater.setValue(value);
    }

    // ------------------------------------------------------------------ initialization

    function test_Initialize() public view {
        assertEq(address(updater.sourceCore()), address(core));
        assertTrue(updater.hasRole(updater.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(updater.hasRole(updater.UPDATER_ROLE(), operator));
        assertFalse(updater.hasRole(updater.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(updater.hasRole(updater.UPDATER_ROLE(), address(this)));
        assertEq(beacon.owner(), safe);
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        updater.initialize(address(core), address(this), address(this));
    }

    function test_ImplementationCannotBeInitialized() public {
        OracleUpdater impl = new OracleUpdater();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(core), safe, operator);
    }

    function test_InitializeRejectsZeroAddresses() public {
        OracleUpdater impl = new OracleUpdater();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), safe);
        address[3][3] memory cases =
            [[address(0), safe, operator], [address(core), address(0), operator], [address(core), safe, address(0)]];
        for (uint256 i = 0; i < cases.length; ++i) {
            vm.expectRevert(IOracleUpdater.OracleUpdaterZeroAddress.selector);
            new BeaconProxy(
                address(b), abi.encodeCall(OracleUpdater.initialize, (cases[i][0], cases[i][1], cases[i][2]))
            );
        }
    }

    function test_InitializeRejectsCodelessCore() public {
        OracleUpdater impl = new OracleUpdater();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl), safe);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(IOracleUpdater.OracleUpdaterNotAContract.selector, eoa));
        new BeaconProxy(address(b), abi.encodeCall(OracleUpdater.initialize, (eoa, safe, operator)));
    }

    // ------------------------------------------------------------------ access control

    function test_OnlyUpdaterCanSet() public {
        bytes32 role = updater.UPDATER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        updater.setValue(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, safe, role));
        vm.prank(safe);
        updater.setValue(1 ether);
    }

    function test_AdminManagesUpdaters() public {
        bytes32 role = updater.UPDATER_ROLE();
        address next = makeAddr("next");
        vm.startPrank(safe);
        updater.grantRole(role, next);
        updater.revokeRole(role, operator);
        vm.stopPrank();

        vm.prank(next);
        updater.setValue(1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, role)
        );
        vm.prank(operator);
        updater.setValue(1 ether);
    }

    function test_WithoutOracleRoleTheWriteReverts() public {
        vm.prank(safe);
        core.revokeRole(SET_VALUE_ROLE, address(updater));
        vm.expectRevert("Oracle: forbidden");
        _set(1 ether);
    }

    // ------------------------------------------------------------------ bounds

    function test_EqualValueRefreshes() public {
        vm.warp(block.timestamp + 8 hours);
        _set(1 ether);
        assertEq(oracle.value(), 1 ether);
        assertEq(oracle.lastUpdated(), block.timestamp);
    }

    function test_DecreaseReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueDecrease.selector, 1 ether, 1 ether - 1)
        );
        _set(1 ether - 1);
    }

    function test_DecreaseRevertsEvenWhenBackedByNav() public {
        _distribute(10 ether);
        _set(1.05 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueDecrease.selector, 1.05 ether, 1.04 ether)
        );
        _set(1.04 ether);
    }

    function test_IncreaseUpToNav() public {
        _distribute(10 ether);
        assertEq(updater.maxValue(), 1.1 ether);
        _set(1.1 ether);
        assertEq(oracle.value(), 1.1 ether);
    }

    function test_AboveNavReverts() public {
        _distribute(10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueAboveNav.selector, 1.1 ether, 1.1 ether + 1)
        );
        _set(1.1 ether + 1);
    }

    function test_AboveNavRevertsWithNoNewRewards() public {
        vm.expectRevert(
            abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueAboveNav.selector, 1 ether, 1 ether + 1)
        );
        _set(1 ether + 1);
    }

    function test_StaleOracleCanBeRefreshed() public {
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert("Oracle: stale value");
        oracle.getValue();

        _set(1 ether);
        assertEq(oracle.getValue(), 1 ether);
    }

    function test_SafeCanStillLowerDirectly() public {
        vm.prank(safe);
        oracle.setValue(0.9 ether);
        assertEq(oracle.value(), 0.9 ether);
        // The floor follows whatever the oracle now holds.
        _set(0.95 ether);
        assertEq(oracle.value(), 0.95 ether);
    }

    // ------------------------------------------------------------------ the NAV figure

    function test_MaxValueCountsAdapterLockbox() public {
        assertEq(w0g.balanceOf(address(core)), 10 ether);
        assertEq(w0g.balanceOf(adapter), 90 ether);
        assertEq(updater.maxValue(), 1 ether);

        core.pushToTarget(10 ether);
        assertEq(updater.maxValue(), 1 ether);
    }

    function test_MaxValueRoundsDown() public {
        _distribute(1);
        // (100e18 + 1) * 1e18 / 100e18 = 1e18 + 0.01, floored.
        assertEq(updater.maxValue(), 1 ether);
        _distribute(99);
        assertEq(updater.maxValue(), 1 ether + 1);
    }

    function test_PendingWithdrawalStaysInBothTerms() public {
        _distribute(10 ether);
        uint256 before = updater.maxValue();

        vm.prank(user);
        core.requestWithdrawal(40 ether);
        assertEq(core.totalSupply(), 100 ether);
        assertEq(updater.maxValue(), before);
    }

    function test_HandledWithdrawalLeavesBothTerms() public {
        _distribute(10 ether);
        _set(1.1 ether);

        vm.prank(user);
        core.requestWithdrawal(5 ether);
        uint256 paid = core.handleEpoch(5 ether);

        assertEq(paid, 5.5 ether);
        assertEq(w0g.balanceOf(queue), 5.5 ether);
        assertEq(core.totalSupply(), 95 ether);
        assertEq(updater.maxValue(), 1.1 ether);
    }

    function test_DepositAtStalePriceDilutesTowardIt() public {
        _distribute(10 ether);
        assertEq(updater.maxValue(), 1.1 ether);

        // The oracle still says 1.0, so this deposit buys shares cheaply and drags NAV toward 1.0
        // without crossing it.
        _deposit(makeAddr("sniper"), 100 ether);
        uint256 nav = updater.maxValue();
        assertLt(nav, 1.1 ether);
        assertGe(nav, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueAboveNav.selector, nav, 1.1 ether));
        _set(1.1 ether);
        _set(nav);
    }

    function test_DonationRaisesBound() public {
        w0g.transfer(adapter, 10 ether);
        assertEq(updater.maxValue(), 1.1 ether);
    }

    function test_ZeroSupplyReverts() public {
        vm.prank(adapter);
        w0g.transfer(address(core), 90 ether);
        vm.prank(user);
        core.requestWithdrawal(100 ether);
        core.handleEpoch(100 ether);
        assertEq(core.totalSupply(), 0);

        vm.expectRevert(IOracleUpdater.OracleUpdaterZeroSupply.selector);
        updater.maxValue();
        vm.expectRevert(IOracleUpdater.OracleUpdaterZeroSupply.selector);
        _set(1 ether);
    }

    function testFuzz_AcceptsExactlyTheBand(uint256 rewards, uint256 value) public {
        _distribute(bound(rewards, 0, 1_000_000 ether));
        uint256 nav = updater.maxValue();
        uint256 current = oracle.value();

        vm.prank(operator);
        if (value < current) {
            vm.expectRevert(abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueDecrease.selector, current, value));
            updater.setValue(value);
        } else if (value > nav) {
            vm.expectRevert(abi.encodeWithSelector(IOracleUpdater.OracleUpdaterValueAboveNav.selector, nav, value));
            updater.setValue(value);
        } else {
            updater.setValue(value);
            assertEq(oracle.value(), value);
        }
    }

    // ------------------------------------------------------------------ upgrades

    function test_OnlyBeaconOwnerUpgrades() public {
        OracleUpdaterV2 v2 = new OracleUpdaterV2();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        vm.prank(operator);
        beacon.upgradeTo(address(v2));

        vm.prank(safe);
        beacon.upgradeTo(address(v2));
        assertEq(OracleUpdaterV2(address(updater)).version(), 2);
        // Storage survives the upgrade.
        assertEq(address(updater.sourceCore()), address(core));
        assertTrue(updater.hasRole(updater.UPDATER_ROLE(), operator));
    }
}
