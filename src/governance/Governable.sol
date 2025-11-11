// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title Governable
 * @notice Access control pattern for governance operations
 * @dev Provides governor role management for King Protocol vaults
 */
abstract contract Governable {
    // ============================================
    // Events
    // ============================================

    /**
     * @notice Emitted when governor is updated
     * @param oldGovernor Previous governor address
     * @param newGovernor New governor address
     */
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    // ============================================
    // State Variables
    // ============================================

    /**
     * @notice Address with governor privileges
     * @dev Governor can perform administrative functions
     */
    address public governor;

    // ============================================
    // Errors
    // ============================================

    /**
     * @notice Thrown when caller is not the governor
     */
    error OnlyGovernor();

    /**
     * @notice Thrown when new governor address is zero
     */
    error ZeroAddress();

    // ============================================
    // Modifiers
    // ============================================

    /**
     * @notice Restricts function access to governor only
     */
    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor();
        _;
    }

    // ============================================
    // Initialization
    // ============================================

    /**
     * @notice Initialize governor
     * @dev Should be called during contract initialization
     * @param _governor Address of the initial governor
     */
    function __Governable_init(address _governor) internal {
        if (_governor == address(0)) revert ZeroAddress();
        governor = _governor;
        emit GovernorUpdated(address(0), _governor);
    }

    // ============================================
    // Admin Functions
    // ============================================

    /**
     * @notice Transfer governor role to new address
     * @dev Only callable by current governor
     * @param _newGovernor Address of the new governor
     */
    function setGovernor(address _newGovernor) external onlyGovernor {
        if (_newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = governor;
        governor = _newGovernor;
        emit GovernorUpdated(oldGovernor, _newGovernor);
    }
}
