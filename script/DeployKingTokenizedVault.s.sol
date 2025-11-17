// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseKingVaultScript} from "./shared/BaseKingVaultScript.sol";
import {console} from "forge-std/console.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {KingTokenizedVault} from "../src/vaults/KingTokenizedVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployKingTokenizedVault
 * @notice Deployment script for KingTokenizedVault with TOML configuration
 * @dev Extends BaseKingVaultScript for shared deployment functionality
 * @dev Supports Ledger (--ledger) and named account (--account) authentication
 * @dev Zero private keys - all authentication via Foundry keystore or hardware wallet
 *
 * Inherited functions from BaseKingVaultScript:
 * - loadNetworkConfig(): Load network configuration from TOML
 * - setupAuth(): Configure authentication (Ledger/named account)
 * - registerAssets(): Register vault assets
 * - setupProfitsDistribution(): Configure profit distribution
 * - verifyContracts(): Verify contracts on Etherscan
 */
contract DeployKingTokenizedVault is BaseKingVaultScript {
    using stdToml for string;

    // ============================================
    // Data Structures
    // ============================================

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
        address vaultAddress; // ERC-4626 vault (immutable)
        bool isAtomic; // Withdrawal mode (immutable)
        address[] assets;
        address[] profitRecipients;
        uint16[] profitPercentsBPS;
    }

    struct DeploymentResult {
        address implementation;
        address proxy;
        uint256 gasUsed;
    }

    // ============================================
    // State
    // ============================================

    DeploymentResult public result;

    // ============================================
    // Main Entry Point
    // ============================================

    /**
     * @notice Deploy KingTokenizedVault with configuration from TOML
     * @param vaultId Vault identifier from config/vaults.toml
     */
    function deploy(string memory vaultId) external {
        console.log("=== KingTokenizedVault Deployment ===");
        console.log("Vault ID:", vaultId);
        console.log("");

        // Step 1: Load and validate configuration
        console.log("[Step 1/7] Loading configuration...");
        VaultConfig memory config = loadVaultConfig(vaultId);
        NetworkConfig memory network = loadNetworkConfig(config.network);
        validateConfig(config);

        console.log("  Network:", config.network);
        console.log("  Owner:", config.owner);
        console.log("  ERC-4626 Vault:", config.vaultAddress);
        console.log("  Mode:", config.isAtomic ? "Atomic" : "Async");
        console.log("  Assets:", config.assets.length);
        console.log("");

        // Step 2: Setup authentication
        console.log("[Step 2/7] Setting up authentication...");
        setupAuth();
        console.log("");

        // Step 3: Start broadcast
        uint256 gasStart = gasleft();
        vm.startBroadcast();

        // Step 4: Deploy implementation
        console.log("[Step 3/7] Deploying implementation...");
        address implementation = deployImplementation(config);
        console.log("  Implementation:", implementation);
        console.log("");

        // Step 5: Deploy proxy
        console.log("[Step 4/7] Deploying proxy...");
        address proxy = deployProxy(implementation, config);
        console.log("  Proxy:", proxy);
        console.log("");

        // Step 6: Initialize vault
        console.log("[Step 5/7] Initializing vault...");
        initializeVault(proxy, config);
        console.log("  Initialized:");
        console.log("    - Name:", config.name);
        console.log("    - Symbol:", config.symbol);
        console.log("    - Decimals:", config.decimals);
        console.log("");

        // Step 7: Register assets
        console.log("[Step 6/8] Registering assets...");
        registerAssets(proxy, config.assets);
        console.log("  Registered", config.assets.length, "assets");
        console.log("");

        // Step 8: Setup profit distribution
        console.log("[Step 7/8] Setting up profit distribution...");
        if (config.profitRecipients.length > 0) {
            setupProfitsDistribution(proxy, config.profitRecipients, config.profitPercentsBPS);
            console.log("  Configured", config.profitRecipients.length, "profit recipients");
        } else {
            console.log("  Skipped (no recipients configured)");
        }
        console.log("");

        // Stop broadcast
        vm.stopBroadcast();

        uint256 gasUsed = gasStart - gasleft();

        // Step 9: Verify on Etherscan (if requested)
        console.log("[Step 8/8] Verification...");
        if (vm.envOr("VERIFY", false)) {
            verifyContracts(implementation, proxy, network);
            console.log("  Verification complete");
        } else {
            console.log("  Skipped (add --verify flag to enable)");
        }
        console.log("");

        // Save results
        result = DeploymentResult({implementation: implementation, proxy: proxy, gasUsed: gasUsed});

        // Output summary
        outputResults(vaultId, implementation, proxy, gasUsed);
    }

    // ============================================
    // Configuration Loading
    // ============================================

    /**
     * @notice Load vault configuration from TOML file
     * @param vaultId Vault identifier (e.g., "tokenized-vault-concrete-atomic")
     * @return config Parsed vault configuration
     */
    function loadVaultConfig(string memory vaultId) internal view returns (VaultConfig memory config) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/config/vaults.toml");
        string memory toml = vm.readFile(path);

        // Try to find vault by iterating through array indices
        // TOML arrays are 0-indexed: vaults[0], vaults[1], etc.
        for (uint256 i = 0; i < 100; i++) {
            // Try to parse vault at index i
            string memory currentKey = string.concat(".vaults[", vm.toString(i), "]");

            // Try to read the ID - if it fails, we've reached the end of the array
            try vm.parseTomlString(toml, string.concat(currentKey, ".id")) returns (string memory currentId) {
                // Check if this is the vault we're looking for
                if (keccak256(abi.encodePacked(currentId)) == keccak256(abi.encodePacked(vaultId))) {
                    // Check vault type - only accept KingTokenizedVault
                    string memory vaultType = vm.parseTomlString(toml, string.concat(currentKey, ".type"));
                    if (keccak256(abi.encodePacked(vaultType)) != keccak256(abi.encodePacked("KingTokenizedVault"))) {
                        revert(
                            string.concat("Vault type mismatch: expected 'KingTokenizedVault', got '", vaultType, "'")
                        );
                    }

                    // Found matching vault - parse all fields
                    config.id = currentId;
                    config.network = vm.parseTomlUint(toml, string.concat(currentKey, ".network"));
                    config.vaultType = vaultType;
                    config.name = vm.parseTomlString(toml, string.concat(currentKey, ".name"));
                    config.symbol = vm.parseTomlString(toml, string.concat(currentKey, ".symbol"));
                    config.decimals = uint8(vm.parseTomlUint(toml, string.concat(currentKey, ".decimals")));
                    config.owner = vm.parseTomlAddress(toml, string.concat(currentKey, ".owner"));
                    config.kingVault = vm.parseTomlAddress(toml, string.concat(currentKey, ".king_vault"));
                    config.priceProvider = vm.parseTomlAddress(toml, string.concat(currentKey, ".price_provider"));
                    config.vaultAddress = vm.parseTomlAddress(toml, string.concat(currentKey, ".vault_address"));
                    config.isAtomic = vm.parseTomlBool(toml, string.concat(currentKey, ".is_atomic"));
                    config.assets = vm.parseTomlAddressArray(toml, string.concat(currentKey, ".assets"));

                    // Parse profit distribution (optional)
                    try vm.parseTomlAddressArray(toml, string.concat(currentKey, ".profit_recipients")) returns (
                        address[] memory recipients
                    ) {
                        config.profitRecipients = recipients;
                        // Parse corresponding percentages
                        uint256[] memory percents =
                            vm.parseTomlUintArray(toml, string.concat(currentKey, ".profit_percents_bps"));
                        config.profitPercentsBPS = new uint16[](percents.length);
                        for (uint256 j = 0; j < percents.length; j++) {
                            config.profitPercentsBPS[j] = uint16(percents[j]);
                        }
                    } catch {
                        // Profit distribution not configured - leave empty
                        config.profitRecipients = new address[](0);
                        config.profitPercentsBPS = new uint16[](0);
                    }

                    return config;
                }
            } catch {
                // End of array reached, vault not found
                break;
            }
        }

        revert(string.concat("Vault ID not found in config: ", vaultId));
    }

    /**
     * @notice Validate configuration before deployment
     * @param config Vault configuration to validate
     */
    function validateConfig(VaultConfig memory config) internal pure {
        require(bytes(config.id).length > 0, "Invalid vault ID");
        require(config.network > 0, "Invalid network");
        require(config.owner != address(0), "Invalid owner address");
        require(config.kingVault != address(0), "Invalid king vault address");
        require(config.priceProvider != address(0), "Invalid price provider address");
        require(config.vaultAddress != address(0), "Invalid ERC-4626 vault address");
        require(config.assets.length > 0, "No assets configured");
    }

    // ============================================
    // Deployment Functions
    // ============================================

    /**
     * @notice Deploy implementation contract
     * @param config Vault configuration
     * @return implementation Address of deployed implementation
     */
    function deployImplementation(VaultConfig memory config) internal returns (address implementation) {
        KingTokenizedVault impl = new KingTokenizedVault(
            config.vaultAddress, // ERC-4626 vault (immutable)
            config.isAtomic // Withdrawal mode (immutable)
        );

        return address(impl);
    }

    /**
     * @notice Deploy UUPS proxy
     * @param implementation Address of implementation contract
     * @param config Vault configuration
     * @return proxy Address of deployed proxy
     */
    function deployProxy(address implementation, VaultConfig memory config) internal returns (address proxy) {
        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector,
            config.owner,
            config.kingVault,
            config.priceProvider,
            new address[](0), // No assets during init
            new bool[](0) // Will register separately
        );

        // Deploy proxy
        ERC1967Proxy proxyContract = new ERC1967Proxy(implementation, initData);

        return address(proxyContract);
    }

    /**
     * @notice Initialize vault (already done in proxy constructor)
     * @param proxy Address of deployed proxy
     * @param config Vault configuration
     */
    function initializeVault(address proxy, VaultConfig memory config) internal view {
        // Initialization happens in proxy constructor
        // This function exists for logging/verification purposes

        // Verify initialization
        KingTokenizedVault vault = KingTokenizedVault(payable(proxy));
        require(vault.owner() == config.owner, "Owner mismatch");
        require(vault.kingVault() == config.kingVault, "King vault mismatch");
    }

    // ============================================
    // Output
    // ============================================

    /**
     * @notice Output deployment results
     * @param vaultId Vault identifier
     * @param implementation Implementation address
     * @param proxy Proxy address
     * @param gasUsed Total gas used
     */
    function outputResults(string memory vaultId, address implementation, address proxy, uint256 gasUsed)
        internal
        view
    {
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("Vault:", vaultId);
        console.log("Implementation:", implementation);
        console.log("Proxy (KingTokenizedVault):", proxy);
        console.log("Gas used:", gasUsed);
        console.log("");

        if (!vm.envOr("BROADCAST", false)) {
            console.log("SIMULATION COMPLETE - No transactions broadcast");
            console.log("To deploy, add --broadcast flag");
        } else {
            console.log("DEPLOYMENT SUCCESSFUL");
            console.log("Transactions broadcast to network");
        }
    }
}
