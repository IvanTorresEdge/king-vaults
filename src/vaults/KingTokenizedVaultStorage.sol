// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVaultStorage} from "../base/KingVaultStorage.sol";

/**
 * @title KingTokenizedVaultStorage
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice Storage contract for KingTokenizedVault (ERC-4626 integration)
 * @dev Extends KingVaultStorage with ERC-4626-specific state variables
 * @dev Follows storage separation pattern: all state here, logic in KingTokenizedVault
 *
 * Architecture Pattern:
 * - Storage Contract: KingTokenizedVaultStorage (this file) - holds ALL state
 * - Implementation Contract: KingTokenizedVault - holds ONLY logic
 * - Follows exact pattern from KingBoringVault for consistency
 *
 * Key Design:
 * - Immutable vault and withdrawal mode (set in constructor)
 * - Mutable configuration (slippage, duration) set in initialize()
 * - Dual tracking for Type A (principal) and Type B (profit) withdrawals
 * - Storage gap reserves 45 slots for future upgrades
 */
abstract contract KingTokenizedVaultStorage is KingVaultStorage {
    // ============================================
    // Immutable State
    // ============================================

    /**
     * @notice Target ERC-4626 vault address
     * @dev Immutable - set in constructor, never changes
     * @dev Example: Concrete vault address
     * @dev All deposits and withdrawals route through this vault
     */
    address public immutable vault;

    /**
     * @notice Withdrawal mode flag
     * @dev Immutable - set in constructor, never changes
     * @dev true = atomic (immediate withdrawals)
     * @dev false = async (queued withdrawals requiring completion)
     */
    bool public immutable isAtomic;

    // ============================================
    // Mutable Configuration
    // ============================================

    /**
     * @notice Maximum allowed slippage in basis points (1 BPS = 0.01%)
     * @dev Used for share conversion slippage protection
     * @dev Default: 50 BPS (0.5%), Max: 1000 BPS (10%)
     * @dev Set in initialize(), can be updated by owner
     */
    uint16 public maxSlippageBPS;

    /**
     * @notice Default duration for async withdrawal requests (seconds)
     * @dev Used as deadline offset when creating withdrawal requests
     * @dev Default: 7 days
     * @dev Only applies to async mode (isAtomic = false)
     */
    uint64 public withdrawalDuration;

    // ============================================
    // Withdrawal Tracking
    // ============================================

    /**
     * @notice Pending shares committed to withdrawal
     * @dev Only one withdrawal request at a time
     * @dev Set when withdrawFromVault() called
     * @dev Cleared when completeWithdrawal() or cancelWithdrawal() called
     * @dev Prevents concurrent withdrawal requests
     */
    uint256 internal _pendingShares;

    /**
     * @notice Tracks withdrawal request details per asset
     * @dev asset => WithdrawalRequest struct
     * @dev Only one withdrawal request per asset at a time
     * @dev Deleted after confirmation or cancellation
     */
    mapping(address => WithdrawalRequest) internal _withdrawalRequests;

    /**
     * @notice Tracks profit assets queued for distribution (Type B withdrawals)
     * @dev asset => amount queued
     * @dev Incremented when harvestProfits() queues profit withdrawal
     * @dev Cleared when distributeProfits() completes
     * @dev Protects profit assets from being withdrawn as principal
     * @dev CRITICAL: Used by availableForWithdraw() to prevent accounting errors
     */
    mapping(address => uint256) internal _queuedProfits;

    /**
     * @notice Tracks principal assets queued for return to main vault (Type A withdrawals)
     * @dev asset => amount queued
     * @dev Incremented when withdrawFromVault() queues principal withdrawal
     * @dev Cleared when completeWithdrawal() completes
     * @dev CRITICAL: Used by availableForWithdraw() to prevent over-withdrawal
     */
    mapping(address => uint256) internal _queuedWithdraw;

    // ============================================
    // Structs
    // ============================================

    /**
     * @notice Withdrawal request details
     * @dev Stored in _withdrawalRequests mapping
     * @param asset ERC-20 token address we expect to receive
     * @param shares Share amount being withdrawn
     * @param expected Expected asset amount based on conversion rate
     * @param deadline Unix timestamp after which request expires (async mode only)
     * @param isProfitWithdrawal Type A (false) or Type B (true) withdrawal
     */
    struct WithdrawalRequest {
        address asset;      // Asset we expect to receive
        uint256 shares;     // Share amount committed to withdrawal
        uint256 expected;   // Expected asset amount
        uint64 deadline;    // Request deadline timestamp (async mode)
        bool isProfitWithdrawal; // Type A (false) or Type B (true)
    }

    // ============================================
    // Storage Gap
    // ============================================

    /**
     * @dev Storage gap for future upgrades (OpenZeppelin UUPS pattern)
     * @dev Reserves 45 storage slots to prevent storage collisions
     * @dev Total storage slots: 50 (5 used + 45 gap)
     * @dev Critical for UUPS upgradeability pattern
     * @dev Subtract used slots when adding new state variables
     */
    uint256[45] private __gap;

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Constructor that disables initializers
     * @dev Prevents implementation contract from being initialized
     * @dev Required for UUPS proxy pattern security
     * @dev Immutables are set in derived contract constructor
     */
    constructor() {
        _disableInitializers();
    }
}
