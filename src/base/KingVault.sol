// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVaultStorage} from "./KingVaultStorage.sol";
import {IKingVault} from "../interfaces/IKingVault.sol";

/**
 * @title KingVault
 * @notice Abstract base contract for King Protocol vault implementations
 * @dev Provides common vault infrastructure for multi-token deposits, withdrawals, TVL tracking
 * @dev Specialized vaults (BoringVault, TokenizedVault) extend this contract
 */
abstract contract KingVault is KingVaultStorage, IKingVault {
    // ============================================
    // Initialization
    // ============================================

    /**
     * @notice Initialize the vault with required addresses
     * @dev Called once during proxy deployment
     * @dev Initializes parent contracts and sets core addresses
     * @param _owner Address of the owner (governance)
     * @param _kingVault Address of King's core vault (immutable after init)
     * @param _priceProvider Address of the price provider for TVL calculation
     * @param _tokens Optional array of initial tokens to register
     * @param _accepted Optional array of acceptance status for initial tokens
     */
    function __KingVault_init(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address[] memory _tokens,
        bool[] memory _accepted
    ) internal onlyInitializing {
        // Validate core addresses
        if (_owner == address(0)) revert ZeroAddress();
        if (_kingVault == address(0)) revert ZeroAddress();
        if (_priceProvider == address(0)) revert ZeroAddress();

        // Initialize parent contracts
        __Ownable2Step_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Transfer ownership to specified owner
        _transferOwnership(_owner);

        // Set core addresses (kingVault is immutable by design - Decision 11)
        kingVault = _kingVault;
        priceProvider = _priceProvider;

        // Register initial tokens if provided
        if (_tokens.length > 0) {
            _registerAssets(_tokens, _accepted);
        }
    }

    // ============================================
    // Internal Asset Registration
    // ============================================

    /**
     * @notice Internal function to register assets
     * @dev Validates tokens and updates storage mappings
     * @dev Full implementation in Feature 5 (Task 5.2)
     * @param _tokens Array of token addresses to register
     * @param _accepted Array of acceptance status for tokens
     */
    function _registerAssets(address[] memory _tokens, bool[] memory _accepted) internal virtual {
        // Stub for now - full implementation in Task 5.2
        // Will include:
        // - Validate arrays non-empty and matching length
        // - Loop through tokens:
        //   - Validate token != address(0)
        //   - Get price from IPriceProvider and validate > 0
        //   - Update _registeredTokens[token] = _accepted[i]
        //   - Call _addToAssets(token) if _accepted[i] == true
        //   - Emit TokenAdded or TokenRemoved events
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get array of all registered and accepted assets
     * @return acceptedTokens Array of accepted token addresses
     * @dev Filters _assets array by _registeredTokens[token] == true
     */
    function assets() external view override returns (address[] memory acceptedTokens) {
        // Count accepted tokens
        uint256 count = 0;
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_registeredTokens[_assets[i]]) {
                count++;
            }
        }

        // Create result array with correct size
        acceptedTokens = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_registeredTokens[_assets[i]]) {
                acceptedTokens[index] = _assets[i];
                index++;
            }
        }
    }
}
