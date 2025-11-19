// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVaultStorage} from "../base/KingVaultStorage.sol";

/**
 * @title KingBoringVaultStorage
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice Storage contract for KingBoringVault (Veda Finance BoringVault integration)
 * @dev Extends KingVaultStorage with Veda-specific state variables
 * @dev Follows storage separation pattern: all state here, logic in KingBoringVault
 *
 * Architecture Pattern:
 * - Storage Contract: KingBoringVaultStorage (this file) - holds ALL state
 * - Implementation Contract: KingBoringVault - holds ONLY logic
 * - Consistent with KingTokenizedVault storage separation pattern
 *
 * Key Design:
 * - Immutable vault, teller, accountant (set in constructor)
 * - Mutable configuration (atomicQueue, slippage, duration) set in initialize()
 * - Dual tracking for Type A (principal) and Type B (profit) withdrawals
 * - Storage gap reserves 45 slots for future upgrades
 */
abstract contract KingBoringVaultStorage is KingVaultStorage {
    // ============================================
    // Immutable State
    // ============================================

    /**
     * @notice Veda BoringVault contract address (ERC20 shares)
     * @dev Immutable - set in constructor, never changes
     * @dev Example: 0x917ceE801a67f933F2e6b33fC0cD1ED2d5909D88 (sETHFI vault)
     */
    address public immutable vault;

    /**
     * @notice Veda Teller contract address (handles deposits)
     * @dev Immutable - set in constructor, never changes
     * @dev Example: 0xe2acf9f80a2756E51D1e53F9f41583C84279Fb1f (sETHFI Teller)
     */
    address public immutable teller;

    /**
     * @notice Veda Accountant contract address (provides exchange rates)
     * @dev Immutable - set in constructor, never changes
     * @dev Example: 0x05A1552c5e18F5A0BB9571b5F2D6a4765ebdA32b (sETHFI Accountant)
     */
    address public immutable accountant;

    // ============================================
    // Mutable Configuration
    // ============================================

    /**
     * @notice Veda AtomicQueue contract address (handles withdrawals)
     * @dev Mutable - set in initialize(), can be updated by owner
     * @dev Example: 0xD45884B592E316eB816199615A95C182F75dea07 (AtomicQueue)
     */
    address public atomicQueue;

    /**
     * @notice Maximum allowed slippage in basis points (1 BPS = 0.01%)
     * @dev Used for deposit slippage protection (minimumMint calculation)
     * @dev Default: 50 BPS (0.5%), Max: 10_00 BPS (10%)
     */
    uint16 public maxSlippageBPS;

    /**
     * @notice Default duration for withdrawal requests (seconds)
     * @dev Used as deadline offset when creating AtomicQueue requests
     * @dev Default: 7 days
     */
    uint64 public withdrawalDuration;

    // ============================================
    // Withdrawal Tracking
    // ============================================

    /**
     * @notice Pending shares committed to withdrawal per asset
     * @dev Tracks shares committed for each asset's withdrawal request
     * @dev Multiple assets can have concurrent withdrawal requests
     * @dev Set when withdrawFromVault() or harvestProfits() called for an asset
     * @dev Cleared when completePrincipalWithdraw() or distributeProfits() called for that asset
     * @dev Per-asset tracking enables concurrent withdrawals without accounting collisions
     * @dev Maps: asset address => pending share amount for that asset
     */
    mapping(address => uint256) internal _pendingSharesByAsset;

    /**
     * @notice Tracks withdrawal request details per asset
     * @dev asset => WithdrawalRequest struct
     * @dev Only one withdrawal request per asset at a time
     * @dev Deleted after confirmation or cancellation
     * @dev THE ONLY THING WE TRACK: In-transit assets during withdrawals
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
     * @dev Cleared when completePrincipalWithdraw() completes
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
     * @param offer Asset amount offered for shares (IN-TRANSIT ASSET TRACKING)
     * @param want Share amount we want to withdraw
     * @param deadline Unix timestamp after which request expires (can be cancelled)
     */
    struct WithdrawalRequest {
        address asset; // Asset we expect to receive
        uint256 offer; // Asset amount offered for shares
        uint256 want; // Share amount we want to withdraw
        uint64 deadline; // Request deadline timestamp
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
