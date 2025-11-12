// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVault} from "../../src/base/KingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title KingVaultHarness
 * @notice Test harness for KingVault abstract contract
 * @dev Provides concrete implementations for testing and exposes internal functions
 */
contract KingVaultHarness is KingVault {
    // ============================================
    // Initialization
    // ============================================

    /**
     * @notice Initialize the vault (proxy pattern)
     * @param _owner Address of the owner
     * @param _kingVault Address of King's core vault
     * @param _priceProvider Address of the price provider
     */
    function initialize(
        address _owner,
        address _kingVault,
        address _priceProvider
    ) external initializer {
        address[] memory emptyTokens = new address[](0);
        bool[] memory emptyAccepted = new bool[](0);
        __KingVault_init(_owner, _kingVault, _priceProvider, emptyTokens, emptyAccepted);
    }

    // ============================================
    // Abstract Function Implementations
    // ============================================

    /**
     * @notice Stub implementation of harvestProfits for testing
     * @dev Just emits the event, no actual logic needed for deposit tests
     */
    function harvestProfits() external override {
        _requireOwner();
        emit ProfitsHarvested(block.timestamp);
    }

    /**
     * @notice Override _registerAssets to set storage directly (bypasses IPriceProvider dependency)
     * @dev For testing purposes only - allows registering tokens without price provider
     * @param _tokens Array of token addresses to register
     * @param _accepted Array of acceptance status for tokens
     */
    function _registerAssets(address[] memory _tokens, bool[] memory _accepted) internal override {
        // Validate arrays
        require(_tokens.length > 0 && _tokens.length == _accepted.length, "Invalid arrays");

        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            bool accepted = _accepted[i];

            // Validate token address
            require(token != address(0), "Zero address");

            // Safety check: Prevent disabling token if deposits exist
            if (!accepted && _deposits[token] > 0) {
                revert CannotDisableTokenWithDeposits(token, _deposits[token]);
            }

            // Update registration status
            _registeredTokens[token] = accepted;

            // Add to assets array if accepted (only if not already present)
            if (accepted) {
                _addToAssets(token);
            }

            // Emit appropriate event
            if (accepted) {
                emit TokenAdded(token);
            } else {
                emit TokenRemoved(token);
            }
        }
    }

    // ============================================
    // Exposed Internal Functions for Testing
    // ============================================

    /**
     * @notice Get deposits amount for a token
     * @param token Token address
     * @return Amount deposited
     */
    function getDeposits(address token) external view returns (uint256) {
        return _deposits[token];
    }

    /**
     * @notice Check if a token is registered and accepted
     * @param token Token address
     * @return True if token is accepted
     */
    function isTokenRegistered(address token) external view returns (bool) {
        return _registeredTokens[token];
    }

    /**
     * @notice Get all assets (including inactive ones)
     * @return Array of all asset addresses
     */
    function getAssets() external view returns (address[] memory) {
        return _assets;
    }

    /**
     * @notice Manually register tokens for testing
     * @dev Public wrapper around _registerAssets for test setup
     * @param _tokens Array of token addresses
     * @param _accepted Array of acceptance status
     */
    function registerTokens(address[] memory _tokens, bool[] memory _accepted) external {
        _requireOwner();
        _registerAssets(_tokens, _accepted);
    }

    /**
     * @notice Pause vault operations
     * @dev Callable by owner OR King's core vault
     */
    function pause() external override {
        _requireOwnerOrKingVault();
        _pause();
    }

    /**
     * @notice Resume vault operations
     * @dev Callable by owner OR King's core vault
     */
    function unpause() external override {
        _requireOwnerOrKingVault();
        _unpause();
    }

    /**
     * @notice Public wrapper for registerAssets (implements IKingVault interface)
     * @dev Only callable by owner
     */
    function registerAssets(address[] memory _tokens, bool[] memory _accepted) external override {
        _requireOwner();
        _registerAssets(_tokens, _accepted);
    }
}
