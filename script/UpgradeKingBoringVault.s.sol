// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseKingVaultScript} from "./shared/BaseKingVaultScript.sol";
import {console} from "forge-std/console.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {KingBoringVault} from "../src/vaults/KingBoringVault.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeKingBoringVault
 * @notice Upgrade script for KingBoringVault with storage layout validation
 * @dev Extends BaseKingVaultScript for shared upgrade functionality
 * @dev Supports Ledger (--ledger) and named account (--account) authentication
 * @dev Includes storage layout generation and validation workflow
 *
 * Inherited functions from BaseKingVaultScript:
 * - loadNetworkConfig(): Load network configuration from TOML
 * - setupAuth(): Configure authentication (Ledger/named account)
 * - verifyUpgrade(): Verify upgrade was successful
 */
contract UpgradeKingBoringVault is BaseKingVaultScript {
    using stdToml for string;

    // Reuse same structs from deployment script
    struct VaultConfig {
        string id;
        uint256 network;
        string vaultType;
        string name;
        string symbol;
        uint8 decimals;
        address owner;
        address kingVault;
        address priceProvider;
        address atomicQueue;
        address vaultAddress;
        address teller;
        address accountant;
        address[] assets;
    }

    // ============================================
    // Main Entry Point
    // ============================================

    /**
     * @notice Upgrade KingBoringVault implementation
     * @param vaultId Vault identifier from config/vaults.toml
     */
    function upgrade(string memory vaultId) external {
        console.log("=== KingBoringVault Upgrade ===");
        console.log("Vault ID:", vaultId);
        console.log("");

        // Step 1: Load configuration
        console.log("[Step 1/6] Loading configuration...");
        VaultConfig memory config = loadVaultConfig(vaultId);
        NetworkConfig memory network = loadNetworkConfig(config.network);

        require(network.kingVault != address(0), "No existing vault to upgrade");
        console.log("  Existing proxy:", network.kingVault);
        console.log("");

        // Step 2: Generate storage layout
        console.log("[Step 2/6] Generating storage layout...");
        generateStorageLayout();
        console.log("  Storage layout saved to: storage-layout-new.txt");
        console.log("  IMPORTANT: Review storage layout before continuing!");
        console.log("  Compare: storage-layout-old.txt vs storage-layout-new.txt");
        console.log("  Run: diff storage-layout-old.txt storage-layout-new.txt");
        console.log("");

        // In simulation mode, stop here for manual review
        if (!vm.envOr("BROADCAST", false)) {
            console.log("SIMULATION MODE - Stopping for storage layout review");
            console.log("After reviewing, run with --broadcast to execute upgrade");
            return;
        }

        // Step 3: Setup authentication
        console.log("[Step 3/6] Setting up authentication...");
        setupAuth();
        console.log("");

        // Step 4: Deploy new implementation
        console.log("[Step 4/6] Deploying new implementation...");
        vm.startBroadcast();

        address newImplementation = deployImplementation(config);
        console.log("  New implementation:", newImplementation);
        console.log("");

        // Step 5: Execute upgrade
        console.log("[Step 5/6] Executing UUPS upgrade...");
        UUPSUpgradeable vault = UUPSUpgradeable(network.kingVault);
        vault.upgradeToAndCall(newImplementation, "");
        console.log("  Upgrade executed");
        console.log("");

        vm.stopBroadcast();

        // Step 6: Verify upgrade
        console.log("[Step 6/6] Verifying upgrade...");
        verifyUpgrade(network.kingVault, newImplementation);
        console.log("  Verification complete");
        console.log("");

        // Output results
        outputUpgradeResults(vaultId, network.kingVault, newImplementation);
    }

    // ============================================
    // Storage Layout Generation
    // ============================================

    /**
     * @notice Generate storage layout for new implementation
     * @dev Uses forge inspect to generate layout
     * @dev Saves to storage-layout-new.txt for manual comparison
     */
    function generateStorageLayout() internal {
        string[] memory inputs = new string[](5);
        inputs[0] = "forge";
        inputs[1] = "inspect";
        inputs[2] = "src/vaults/KingBoringVault.sol:KingBoringVault";
        inputs[3] = "storage-layout";
        inputs[4] = "--pretty";

        bytes memory result = vm.ffi(inputs);
        vm.writeFile("storage-layout-new.txt", string(result));
    }

    // ============================================
    // Configuration Loading (reuse from deploy script)
    // ============================================

    function loadVaultConfig(string memory vaultId) internal view returns (VaultConfig memory config) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/config/vaults.toml");
        string memory toml = vm.readFile(path);

        string memory vaultsKey = ".vaults";
        string[] memory vaultIds = vm.parseTomlKeys(toml, vaultsKey);

        for (uint256 i = 0; i < vaultIds.length; i++) {
            string memory currentKey = string.concat(vaultsKey, ".", vm.toString(i));
            string memory currentId = vm.parseTomlString(toml, string.concat(currentKey, ".id"));

            if (keccak256(abi.encodePacked(currentId)) == keccak256(abi.encodePacked(vaultId))) {
                config.id = currentId;
                config.network = vm.parseTomlUint(toml, string.concat(currentKey, ".network"));
                config.vaultAddress = vm.parseTomlAddress(toml, string.concat(currentKey, ".vault_address"));
                config.teller = vm.parseTomlAddress(toml, string.concat(currentKey, ".teller"));
                config.accountant = vm.parseTomlAddress(toml, string.concat(currentKey, ".accountant"));
                return config;
            }
        }

        revert(string.concat("Vault ID not found in config: ", vaultId));
    }

    // ============================================
    // Deployment
    // ============================================

    function deployImplementation(VaultConfig memory config) internal returns (address implementation) {
        KingBoringVault impl = new KingBoringVault(config.vaultAddress, config.teller, config.accountant);

        return address(impl);
    }

    // ============================================
    // Output
    // ============================================

    function outputUpgradeResults(string memory vaultId, address proxy, address newImplementation) internal pure {
        console.log("=== Upgrade Complete ===");
        console.log("");
        console.log("Vault:", vaultId);
        console.log("Proxy:", proxy);
        console.log("New implementation:", newImplementation);
        console.log("");
        console.log("UPGRADE SUCCESSFUL");
    }
}
