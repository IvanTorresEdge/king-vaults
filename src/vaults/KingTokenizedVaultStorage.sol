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
     * @notice Pending shares committed to withdrawal per asset
     * @dev Tracks shares committed for each asset's withdrawal request
     * @dev Multiple assets can have concurrent withdrawal requests
     * @dev Set when withdrawFromVault() called for an asset
     * @dev Cleared when completeWithdrawal() or cancelWithdrawal() called for that asset
     * @dev Per-asset tracking enables concurrent withdrawals without accounting collisions
     * @dev Maps: asset address => pending share amount for that asset
     */
    mapping(address => uint256) internal _pendingSharesByAsset;

    /**
     * @notice Tracks withdrawal request details per asset
     * @dev asset => WithdrawalRequest struct
     * @dev Only one withdrawal request per asset at a time
     * @dev Deleted after confirmation or cancellation
     */
    mapping(address => WithdrawalRequest) internal _withdrawalRequests;

    /**
     * @notice Tracks profit assets queued for distribution (Type B withdrawals)
     * @dev asset => QueuedAmount struct (amount + balanceSnapshot)
     * @dev Incremented when harvestProfits() queues profit withdrawal
     * @dev Cleared when distributeProfits() completes
     * @dev Protects profit assets from being withdrawn as principal
     * @dev CRITICAL: Used by availableForWithdraw() to prevent accounting errors
     * @dev balanceSnapshot updated on every deposit()/withdraw() to detect asset arrival
     */
    mapping(address => QueuedAmount) internal _queuedProfits;

    /**
     * @notice Tracks principal assets queued for return to main vault (Type A withdrawals)
     * @dev asset => QueuedAmount struct (amount + balanceSnapshot)
     * @dev Incremented when withdrawFromVault() queues principal withdrawal
     * @dev Cleared when completeWithdrawal() completes
     * @dev CRITICAL: Used by availableForWithdraw() to prevent over-withdrawal
     * @dev balanceSnapshot updated on every deposit()/withdraw() to detect asset arrival
     */
    mapping(address => QueuedAmount) internal _queuedWithdraw;

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
        address asset; // Asset we expect to receive
        uint256 shares; // Share amount committed to withdrawal
        uint256 expected; // Expected asset amount
        uint64 deadline; // Request deadline timestamp (async mode)
        bool isProfitWithdrawal; // Type A (false) or Type B (true)
    }

    /**
     * @notice Queued amount with balance snapshot for asset arrival detection
     * @dev Used by _queuedWithdraw and _queuedProfits mappings
     * @param amount Amount of assets queued for withdrawal/distribution
     * @param balanceSnapshot Contract balance when queued, updated on deposit()/withdraw()
     * @dev balanceSnapshot enables detection of asset arrival from external vault:
     *      - Initial: Set to current balance when withdrawal/profit queued
     *      - Updates: Incremented on deposit(), decremented on withdraw()
     *      - Detection: If currentBalance >= balanceSnapshot + amount, assets arrived
     */
    struct QueuedAmount {
        uint256 amount; // Amount queued
        uint256 balanceSnapshot; // Balance snapshot for arrival detection
    }

    // ============================================
    // Storage Gap
    // ============================================

    /**
     * @dev Storage gap for future upgrades (OpenZeppelin UUPS pattern)
     * @dev Reserves 44 slots to complete 50-slot layer (6 used + 44 gap = 50 total)
     * @dev Used slots: maxSlippageBPS+withdrawalDuration, _pendingSharesByAsset,
     *      _withdrawalRequests, _queuedProfits, _queuedWithdraw, isAtomic
     * @dev Parent occupies slots 0-49, this layer occupies slots 50-99
     * @dev Critical for UUPS upgradeability pattern
     * @dev Follows OpenZeppelin standard: each inheritance layer occupies exactly 50 slots
     */
    uint256[44] private __gap;

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
