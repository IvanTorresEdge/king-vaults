// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVaultStorage} from "../../src/base/KingVaultStorage.sol";

/**
 * @title KingVaultStorageHarness
 * @notice Test harness that exposes internal functions for testing
 */
contract KingVaultStorageHarness is KingVaultStorage {
    /**
     * @notice Initialize the contract
     * @param _owner Owner address
     * @param _kingVault King vault address
     * @param _priceProvider Price provider address
     */
    function initialize(address _owner, address _kingVault, address _priceProvider) external initializer {
        __Ownable_init(_owner);
        __Pausable_init();
        __UUPSUpgradeable_init();

        kingVault = _kingVault;
        priceProvider = _priceProvider;
    }

    // Expose internal helper functions
    function exposed_getDecimals(address token) external view returns (uint8) {
        return _getDecimals(token);
    }

    function exposed_addToAssets(address token) external {
        _addToAssets(token);
    }

    function exposed_addToProfitsRecipients(address recipient) external {
        _addToProfitsRecipients(recipient);
    }

    function exposed_removeFromProfitsRecipients(address recipient) external {
        _removeFromProfitsRecipients(recipient);
    }

    // Expose access control functions
    function exposed_requireKingVault() external view {
        _requireKingVault();
    }

    function exposed_requireOwner() external view {
        _requireOwner();
    }

    function exposed_requireOwnerOrKingVault() external view {
        _requireOwnerOrKingVault();
    }

    // Expose storage getters for testing
    function getAssets() external view returns (address[] memory) {
        return _assets;
    }

    function getProfitsRecipients() external view returns (address[] memory) {
        return _profitsRecipients;
    }

    function isTokenRegistered(address token) external view returns (bool) {
        return _registeredTokens[token];
    }

    function getDeposits(address token) external view returns (uint256) {
        return _deposits[token];
    }

    function getProfitsDistribution(address recipient) external view returns (uint16) {
        return _profitsDistribution[recipient];
    }

    // Helper to set storage for testing
    function setTokenRegistered(address token, bool status) external {
        _registeredTokens[token] = status;
    }

    function setDeposits(address token, uint256 amount) external {
        _deposits[token] = amount;
    }

    function setProfitsDistribution(address recipient, uint16 percent) external {
        _profitsDistribution[recipient] = percent;
    }
}
