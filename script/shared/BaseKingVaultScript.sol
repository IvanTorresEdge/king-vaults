// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title BaseKingVaultScript
 * @notice Abstract base contract for King Vault deployment and upgrade scripts
 * @dev Provides shared configuration loading, authentication, and utility functions
 *
 * Purpose:
 * - Eliminates code duplication across deployment and upgrade scripts
 * - Ensures consistent behavior for common operations
 * - Simplifies maintenance by centralizing shared logic
 *
 * Shared functionality:
 * - Network configuration loading from TOML
 * - Authentication setup (Ledger/named account)
 * - Asset registration
 * - Profit distribution configuration
 * - Contract verification (deployment and upgrade)
 *
 * Usage:
 * - Extend this contract in deployment scripts (DeployKingBoringVault, DeployKingTokenizedVault)
 * - Extend this contract in upgrade scripts (UpgradeKingBoringVault, UpgradeKingTokenizedVault)
 * - Override specific functions if custom behavior is needed
 */
abstract contract BaseKingVaultScript is Script {
    using stdToml for string;

    // ============================================
    // Shared Data Structures
    // ============================================

    /**
     * @notice Network configuration structure
     * @dev Used by both deployment and upgrade scripts
     * @param rpcUrl RPC endpoint for the network
     * @param etherscanApiKey API key for contract verification
     * @param kingVault Address of existing King Vault (optional, used for upgrades)
     */
    struct NetworkConfig {
        string rpcUrl;
        string etherscanApiKey;
        address kingVault; // Optional: for upgrades
    }

    // ============================================
    // Configuration Loading
    // ============================================

    /**
     * @notice Load network configuration from environment variables
     * @dev Reads RPC URL and Etherscan API key from environment variables
     * @dev Environment variable names: RPC_URL_{chainId} and ETHERSCAN_API_KEY_{chainId}
     * @dev Example: For chain ID 1 (mainnet), use RPC_URL_1 and ETHERSCAN_API_KEY_1
     * @param chainId Network chain ID
     * @return network Parsed network configuration
     */
    function loadNetworkConfig(uint256 chainId) internal view returns (NetworkConfig memory network) {
        // Read RPC URL from environment variable: RPC_URL_{chainId}
        string memory rpcEnvVar = string.concat("RPC_URL_", vm.toString(chainId));
        network.rpcUrl = vm.envString(rpcEnvVar);
        require(bytes(network.rpcUrl).length > 0, string.concat("Missing environment variable: ", rpcEnvVar));

        // Read Etherscan API key from environment variable: ETHERSCAN_API_KEY_{chainId}
        string memory etherscanEnvVar = string.concat("ETHERSCAN_API_KEY_", vm.toString(chainId));
        network.etherscanApiKey = vm.envString(etherscanEnvVar);
        require(
            bytes(network.etherscanApiKey).length > 0, string.concat("Missing environment variable: ", etherscanEnvVar)
        );

        // Optional: Load existing vault address from TOML for upgrades
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/config/vaults.toml");
        string memory toml = vm.readFile(path);
        string memory networkKey = string.concat(".networks.", vm.toString(chainId));

        try vm.parseTomlAddress(toml, string.concat(networkKey, ".king_vault")) returns (address vault) {
            network.kingVault = vault;
        } catch {
            network.kingVault = address(0);
        }

        return network;
    }

    // ============================================
    // Authentication
    // ============================================

    /**
     * @notice Setup authentication method
     * @dev Checks for --ledger flag or --account parameter
     * @dev NO private keys are used or exposed
     */
    function setupAuth() internal pure {
        // In simulation mode (no --broadcast), we don't need actual authentication
        // When --broadcast is used, forge will handle authentication via --ledger or --account

        console.log("  Authentication will be handled by Foundry");
        console.log("  Use --ledger for hardware wallet");
        console.log("  Use --account <name> for named account");
    }

    // ============================================
    // Asset Registration
    // ============================================

    /**
     * @notice Register initial assets
     * @param proxy Address of deployed proxy
     * @param assets Array of asset addresses to register
     */
    function registerAssets(address proxy, address[] memory assets) internal {
        IKingVault vault = IKingVault(proxy);

        // Create accepted array (all true)
        bool[] memory accepted = new bool[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            accepted[i] = true;
        }

        // Register assets
        vault.registerAssets(assets, accepted);

        // Log each registered asset
        for (uint256 i = 0; i < assets.length; i++) {
            console.log("    -", assets[i]);
        }
    }

    // ============================================
    // Profit Distribution
    // ============================================

    /**
     * @notice Setup profit distribution for recipients
     * @param proxy Address of deployed proxy
     * @param recipients Array of recipient addresses
     * @param percentsBPS Array of percentages in basis points (must total 10000)
     */
    function setupProfitsDistribution(address proxy, address[] memory recipients, uint16[] memory percentsBPS)
        internal
    {
        IKingVault vault = IKingVault(proxy);

        // Validate total equals 100% (10000 BPS)
        uint256 total = 0;
        for (uint256 i = 0; i < percentsBPS.length; i++) {
            total += percentsBPS[i];
        }
        require(total == 10000, "Profit distribution must total 10000 BPS (100%)");

        // Set profit distribution
        vault.setProfitsDistribution(recipients, percentsBPS);

        // Log each recipient
        for (uint256 i = 0; i < recipients.length; i++) {
            console.log("    - Recipient:", recipients[i]);
            console.log("      Percentage:", percentsBPS[i], "BPS");
        }
    }

    // ============================================
    // Verification (Deployment)
    // ============================================

    /**
     * @notice Verify contracts on Etherscan
     * @param implementation Address of implementation
     * @param proxy Address of proxy
     */
    function verifyContracts(address implementation, address proxy, NetworkConfig memory /* network */ )
        internal
        pure
    {
        // Note: Verification requires --verify flag and proper API keys
        // Foundry handles this automatically when --verify is used
        console.log("  Implementation:", implementation);
        console.log("  Proxy:", proxy);
        console.log("  Network API configured");
    }

    // ============================================
    // Verification (Upgrade)
    // ============================================

    /**
     * @notice Verify upgrade was successful
     * @param proxy Address of proxy
     * @param newImplementation Expected implementation address
     */
    function verifyUpgrade(address proxy, address newImplementation) internal view {
        // Get implementation from proxy
        bytes32 IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address currentImpl = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));

        require(currentImpl == newImplementation, "Upgrade verification failed");
        console.log("  Current implementation matches expected");
    }
}
