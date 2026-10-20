// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {JsonUtils} from "./Utils.s.sol";
import {AscendRouter} from "../../src/ascend/AscendRouter.sol";
import {OracleUpdater} from "../../src/ascend/OracleUpdater.sol";
import {IMellowSourceCore} from "../../src/interfaces/IMellowSourceCore.sol";
import {Rewarder} from "../../src/Rewarder.sol";

contract AscendRouterScript is Script, JsonUtils {
    function run() public virtual {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");
        address owner = vm.addr(privKey);

        string memory obj = "ascend";

        (string memory json, string memory path) = loadOrInitJson(obj);

        // Read initialization parameters from JSON file
        address wETH = vm.parseJsonAddress(json, ".WETH");
        address mellowVault = vm.parseJsonAddress(json, ".MellowVault");
        address foundation = vm.parseJsonAddress(json, ".Foundation");
        address paymentLayer = vm.parseJsonAddress(json, ".PaymentLayer");
        uint256 mellowVaultPercentage = vm.parseJsonUint(json, ".MellowVaultPercentage");
        uint256 foundationPercentage = vm.parseJsonUint(json, ".FoundationPercentage");
        uint256 paymentLayerPercentage = vm.parseJsonUint(json, ".PaymentLayerPercentage");

        vm.startBroadcast(privKey);

        // Keep whatever else the record already holds (the OracleUpdater entries among them).
        vm.serializeJson(obj, json);

        // Deploy AscendRouter implementation contract
        AscendRouter routerImpl = new AscendRouter();
        // Deploy upgradeable beacon
        UpgradeableBeacon routerBeacon = new UpgradeableBeacon(address(routerImpl), owner);

        // Deploy proxy contract and initialize with parameters from JSON file
        BeaconProxy routerProxy = new BeaconProxy(
            address(routerBeacon),
            abi.encodeCall(
                AscendRouter.initialize,
                (
                    wETH,
                    mellowVault,
                    foundation,
                    paymentLayer,
                    mellowVaultPercentage,
                    foundationPercentage,
                    paymentLayerPercentage
                )
            )
        );

        vm.serializeAddress(obj, "WETH", wETH);
        vm.serializeAddress(obj, "MellowVault", mellowVault);
        vm.serializeAddress(obj, "Foundation", foundation);
        vm.serializeAddress(obj, "PaymentLayer", paymentLayer);
        vm.serializeUint(obj, "MellowVaultPercentage", mellowVaultPercentage);
        vm.serializeUint(obj, "FoundationPercentage", foundationPercentage);
        vm.serializeUint(obj, "PaymentLayerPercentage", paymentLayerPercentage);

        vm.serializeAddress(obj, "AscendRouterImpl", address(routerImpl));
        vm.serializeAddress(obj, "AscendRouterBeacon", address(routerBeacon));
        string memory finalJson = vm.serializeAddress(obj, "AscendRouter", address(routerProxy));
        vm.writeJson(finalJson, path);

        vm.stopBroadcast();
    }

    function distribute() public virtual {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");

        string memory obj = "ascend";

        (string memory json,) = loadOrInitJson(obj);

        // Read AscendRouter address from JSON file
        address ascendRouterAddress = vm.parseJsonAddress(json, ".AscendRouter");
        require(ascendRouterAddress != address(0), "AscendRouter address not found in JSON file");

        vm.startBroadcast(privKey);

        if (ascendRouterAddress.balance > 0) {
            // Call distribute method
            AscendRouter(payable(ascendRouterAddress)).distribute();
        }

        console2.log("AscendRouter distributed successfully");

        vm.stopBroadcast();
    }

    /// @notice Claim rewards from one or more Rewarders into `account`, then distribute the
    ///         AscendRouter balance, all within a single broadcast.
    /// @dev Running the claims and the distribute as separate `forge script` invocations makes
    ///      each process read the sender nonce independently. Against a load-balanced RPC a later
    ///      process can read a stale nonce that does not yet reflect the just-mined claim, so its
    ///      transaction is rejected as "nonce too low" and silently dropped — leaving the claimed
    ///      funds stranded in the router, undistributed. Bundling every call into one broadcast
    ///      lets forge assign sequential nonces locally (one nonce read at the start), removing
    ///      that race. `account` is normally the AscendRouter address so the claimed rewards land
    ///      where `distribute()` reads them.
    function claimAndDistribute(address[] calldata rewarders, address account) public virtual {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");

        string memory obj = "ascend";

        (string memory json,) = loadOrInitJson(obj);

        // Read AscendRouter address from JSON file
        address ascendRouterAddress = vm.parseJsonAddress(json, ".AscendRouter");
        require(ascendRouterAddress != address(0), "AscendRouter address not found in JSON file");

        vm.startBroadcast(privKey);

        for (uint256 i = 0; i < rewarders.length; ++i) {
            uint256 reward = Rewarder(payable(rewarders[i])).claim(account);
            console2.log("reward: ", reward);
        }

        if (ascendRouterAddress.balance > 0) {
            // Call distribute method
            AscendRouter(payable(ascendRouterAddress)).distribute();
        }

        console2.log("AscendRouter distributed successfully");

        vm.stopBroadcast();
    }

    function grantDistributor(
        address distributor
    ) public virtual {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");

        string memory obj = "ascend";

        (string memory json,) = loadOrInitJson(obj);

        address ascendRouterAddress = vm.parseJsonAddress(json, ".AscendRouter");
        require(ascendRouterAddress != address(0), "AscendRouter address not found in JSON file");

        vm.startBroadcast(privKey);

        AscendRouter(payable(ascendRouterAddress)).grantRole(
            AscendRouter(payable(ascendRouterAddress)).DISTRIBUTOR_ROLE(), distributor
        );

        console2.log("Granted DISTRIBUTOR_ROLE to:", distributor);

        vm.stopBroadcast();
    }

    function updateParams() public virtual {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");

        string memory obj = "ascend";

        (string memory json, string memory path) = loadOrInitJson(obj);

        // Read AscendRouter address from JSON file
        address ascendRouterAddress = vm.parseJsonAddress(json, ".AscendRouter");
        require(ascendRouterAddress != address(0), "AscendRouter address not found in JSON file");

        // Read update parameters from JSON file
        address mellowVault = vm.parseJsonAddress(json, ".MellowVault");
        address foundation = vm.parseJsonAddress(json, ".Foundation");
        address paymentLayer = vm.parseJsonAddress(json, ".PaymentLayer");
        uint256 mellowVaultPercentage = vm.parseJsonUint(json, ".MellowVaultPercentage");
        uint256 foundationPercentage = vm.parseJsonUint(json, ".FoundationPercentage");
        uint256 paymentLayerPercentage = vm.parseJsonUint(json, ".PaymentLayerPercentage");

        console2.log("Updating AscendRouter parameters from:", path);
        console2.log("AscendRouter address:", ascendRouterAddress);
        console2.log("MellowVault:", mellowVault);
        console2.log("Foundation:", foundation);
        console2.log("PaymentLayer:", paymentLayer);
        console2.log("MellowVaultPercentage:", mellowVaultPercentage);
        console2.log("FoundationPercentage:", foundationPercentage);
        console2.log("PaymentLayerPercentage:", paymentLayerPercentage);

        vm.startBroadcast(privKey);

        // Call updateParams method
        AscendRouter(payable(ascendRouterAddress)).updateParams(
            mellowVault, foundation, paymentLayer, mellowVaultPercentage, foundationPercentage, paymentLayerPercentage
        );

        console2.log("AscendRouter parameters updated successfully");

        vm.stopBroadcast();
    }

    /// @notice Deploy the OracleUpdater for the aOG vault recorded as `MellowVault`.
    /// @dev Reads `OracleUpdaterAdmin` (the vault's admin multisig, which becomes both the beacon
    ///      owner and the proxy's admin) and `OracleUpdaterOperator` (the account that writes the
    ///      oracle) from the ascend JSON, and records the deployed addresses back into it. The
    ///      broadcasting key is left with no role and no ownership. Granting the updater the
    ///      oracle's SET_VALUE_ROLE is a separate multisig transaction on the SourceCore.
    function deployOracleUpdater() public virtual {
        uint256 privKey = vm.envUint("PRIVATE_KEY_0G");

        string memory obj = "ascend";

        (string memory json, string memory path) = loadOrInitJson(obj);

        address sourceCore = vm.parseJsonAddress(json, ".MellowVault");
        address admin = vm.parseJsonAddress(json, ".OracleUpdaterAdmin");
        address operator = vm.parseJsonAddress(json, ".OracleUpdaterOperator");
        require(admin.code.length > 0, "OracleUpdaterAdmin must be a multisig contract");

        vm.startBroadcast(privKey);
        (address impl, address beacon, address proxy) = deployOracleUpdaterContracts(sourceCore, admin, operator);
        vm.stopBroadcast();

        checkOracleUpdater(proxy, beacon, sourceCore, admin, operator, vm.addr(privKey));

        vm.serializeJson(obj, json);
        vm.serializeAddress(obj, "OracleUpdaterImpl", impl);
        vm.serializeAddress(obj, "OracleUpdaterBeacon", beacon);
        string memory finalJson = vm.serializeAddress(obj, "OracleUpdater", proxy);
        vm.writeJson(finalJson, path);

        console2.log("OracleUpdater:", proxy);
        console2.log("OracleUpdater maxValue:", OracleUpdater(proxy).maxValue());
        console2.log("Oracle value:", IMellowSourceCore(sourceCore).oracle().value());
    }

    function deployOracleUpdaterContracts(
        address sourceCore,
        address admin,
        address operator
    ) internal returns (address impl, address beacon, address proxy) {
        impl = address(new OracleUpdater());
        beacon = address(new UpgradeableBeacon(impl, admin));
        proxy =
            address(new BeaconProxy(beacon, abi.encodeCall(OracleUpdater.initialize, (sourceCore, admin, operator))));
    }

    function checkOracleUpdater(
        address proxy,
        address beacon,
        address sourceCore,
        address admin,
        address operator,
        address deployer
    ) internal view {
        OracleUpdater updater = OracleUpdater(proxy);
        require(UpgradeableBeacon(beacon).owner() == admin, "beacon owner is not the admin");
        require(address(updater.sourceCore()) == sourceCore, "wrong source core");
        require(updater.hasRole(updater.DEFAULT_ADMIN_ROLE(), admin), "admin role missing");
        require(updater.hasRole(updater.UPDATER_ROLE(), operator), "updater role missing");
        if (deployer != admin && deployer != operator) {
            require(!updater.hasRole(updater.DEFAULT_ADMIN_ROLE(), deployer), "deployer kept admin");
            require(!updater.hasRole(updater.UPDATER_ROLE(), deployer), "deployer kept updater");
        }
        require(
            updater.maxValue() >= IMellowSourceCore(sourceCore).oracle().value(),
            "oracle value is above the on-chain NAV"
        );
    }
}
