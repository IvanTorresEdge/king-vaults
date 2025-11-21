// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title MockKingVaultController
 * @notice Mock contract to simulate King's core vault controller for testing
 * @dev Simple contract with minimal functionality to satisfy contract validation
 */
contract MockKingVaultController {
    // This is just a placeholder contract to provide code at an address
    // Used in tests to satisfy kingVault.code.length > 0 validation

    function isContract() external pure returns (bool) {
        return true;
    }
}
