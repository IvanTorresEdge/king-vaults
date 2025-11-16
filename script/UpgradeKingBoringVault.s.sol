// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {KingBoringVault} from "../src/vaults/KingBoringVault.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeKingBoringVault
 * @notice Upgrade script for KingBoringVault with storage layout validation
 * @dev Supports Ledger (--ledger) and named account (--account) authentication
 * @dev Includes storage layout generation and validation workflow
 */
contract UpgradeKingBoringVault is Script {
    using stdToml for string;

    // Reuse same structs from deployment script
    struct NetworkConfig {
        string rpcUrl;
        string etherscanApiKey;
        address kingVault;
    }

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

    function loadNetworkConfig(uint256 chainId) internal view returns (NetworkConfig memory network) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/config/vaults.toml");
        string memory toml = vm.readFile(path);

        string memory networkKey = string.concat(".networks.", vm.toString(chainId));

        network.rpcUrl = vm.parseTomlString(toml, string.concat(networkKey, ".rpc_url"));
        network.etherscanApiKey = vm.parseTomlString(toml, string.concat(networkKey, ".etherscan_api_key"));

        try vm.parseTomlAddress(toml, string.concat(networkKey, ".king_vault")) returns (address vault) {
            network.kingVault = vault;
        } catch {
            network.kingVault = address(0);
        }

        return network;
    }

    function setupAuth() internal view {
        // In simulation mode (no --broadcast), we don't need actual authentication
        // When --broadcast is used, forge will handle authentication via --ledger or --account

        console.log("  Authentication will be handled by Foundry");
        console.log("  Use --ledger for hardware wallet");
        console.log("  Use --account <name> for named account");
    }

    // ============================================
    // Deployment
    // ============================================

    function deployImplementation(VaultConfig memory config) internal returns (address implementation) {
        KingBoringVault impl = new KingBoringVault(config.vaultAddress, config.teller, config.accountant);

        return address(impl);
    }

    // ============================================
    // Verification
    // ============================================

    function verifyUpgrade(address proxy, address newImplementation) internal view {
        // Get implementation from proxy
        bytes32 IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address currentImpl = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));

        require(currentImpl == newImplementation, "Upgrade verification failed");
        console.log("  Current implementation matches expected");
    }

    // ============================================
    // Output
    // ============================================

    function outputUpgradeResults(string memory vaultId, address proxy, address newImplementation) internal view {
        console.log("=== Upgrade Complete ===");
        console.log("");
        console.log("Vault:", vaultId);
        console.log("Proxy:", proxy);
        console.log("New implementation:", newImplementation);
        console.log("");
        console.log("UPGRADE SUCCESSFUL");
    }
}
