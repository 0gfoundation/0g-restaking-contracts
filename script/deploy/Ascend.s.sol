// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {JsonUtils} from "./Utils.s.sol";
import {AscendRouter} from "../../src/ascend/AscendRouter.sol";
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
}
