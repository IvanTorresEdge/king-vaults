// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVault} from "../base/KingVault.sol";
import {IKingVault} from "../interfaces/IKingVault.sol";
import {ITellerWithMultiAssetSupport} from "../interfaces/external/ITellerWithMultiAssetSupport.sol";
import {IAccountantWithRateProviders} from "../interfaces/external/IAccountantWithRateProviders.sol";
import {IAtomicQueue} from "../interfaces/external/IAtomicQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title BoringVault
 * @notice King Vault implementation for Veda Finance BoringVault integration
 * @dev Extends KingVault with Veda-specific deposit/withdrawal logic
 * @dev Uses atomic deposits (Teller) and asynchronous withdrawals (AtomicQueue)
 * @dev Tracks principal separately from share appreciation for profit calculation
 *
 * Architecture:
 * - Inherits: KingVault (UUPS upgradeable base with asset management)
 * - Integrates: Veda BoringVault ecosystem (Vault, Teller, Accountant, AtomicQueue)
 * - Pattern: UUPS proxy with immutable external addresses
 *
 * Key Features:
 * - Atomic deposits: Assets → Shares in single transaction via Teller
 * - Asynchronous withdrawals: Queue → Solver fulfillment via AtomicQueue
 * - Profit tracking: Separate principal from share appreciation
 * - Configurable: Slippage tolerance, withdrawal duration
 * - Emergency controls: Pause, upgrade, configuration
 *
 * Integration Flow:
 * 1. deposit(): Transfer asset → BoringVault, deposit to Teller → receive shares
 * 2. withdraw(): Queue request via AtomicQueue → solver fulfills → transfer asset back
 * 3. harvestProfits(): Calculate share appreciation → distribute to recipients
 *
 * @custom:security-contact security@kingprotocol.com
 */
contract BoringVault is KingVault {
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
    // Mutable State
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
    // Internal State
    // ============================================

    /**
     * @notice Pending shares committed to withdrawal
     * @dev Only one withdrawal request at a time (single _pendingShares tracks all pending)
     * @dev Set when withdrawFromVault() or harvestProfits() called
     * @dev Cleared when completePrincipalWithdraw() or distributeProfits() called
     * @dev Prevents concurrent withdrawal requests
     */
    uint256 internal _pendingShares;

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
    mapping(address => uint256) private _queuedProfits;

    /**
     * @notice Tracks principal assets queued for return to main vault (Type A withdrawals)
     * @dev asset => amount queued
     * @dev Incremented when withdrawFromVault() queues principal withdrawal
     * @dev Cleared when completePrincipalWithdraw() completes
     * @dev CRITICAL: Used by availableForWithdraw() to prevent over-withdrawal
     */
    mapping(address => uint256) private _queuedWithdraw;

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
    // Constants
    // ============================================

    /**
     * @notice Maximum allowed slippage limit (1000 BPS = 10%)
     * @dev Prevents owner from setting excessive slippage tolerance
     */
    uint16 public constant MAX_SLIPPAGE_LIMIT = 1_000; // 10%

    /**
     * @notice Default slippage tolerance (50 BPS = 0.5%)
     * @dev Applied during initialization if not specified
     */
    uint16 public constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%

    // ============================================
    // Custom Errors
    // ============================================

    /**
     * @notice Thrown when attempting to withdraw more than available balance
     * @param asset The asset being withdrawn
     * @param needed The amount requested for withdrawal
     * @param available The actual balance available
     */
    error InsufficientAvailableBalance(address asset, uint256 needed, uint256 available);

    /**
     * @notice Thrown when attempting to finalize a withdrawal that hasn't been queued
     * @dev Check that updateAtomicRequest() was called and solver fulfilled it
     */
    error WithdrawalNotQueued();

    /**
     * @notice Thrown when attempting to cancel a non-existent withdrawal request
     * @dev Verify getUserAtomicRequest() returns a valid request before canceling
     */
    error NoWithdrawalQueued();

    /**
     * @notice Thrown when attempting to harvest profits with no queued withdrawals
     * @dev Ensure requestProfitWithdrawal() was called before harvesting
     */
    error NoProfitsQueued();

    // ============================================
    // Storage Gap
    // ============================================

    /**
     * @dev Storage gap for future upgrades (OpenZeppelin UUPS pattern)
     * @dev Reserves 50 storage slots to prevent storage collisions
     * @dev Subtract used slots when adding new state variables
     */
    uint256[50] private __gap;

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Initialize immutable Veda integration addresses
     * @dev Constructor runs once during implementation deployment (NOT proxy)
     * @dev Disables initializers to prevent implementation contract initialization
     * @param _vault Veda BoringVault contract address (shares)
     * @param _teller Veda Teller contract address (deposits)
     * @param _accountant Veda Accountant contract address (pricing)
     */
    constructor(address _vault, address _teller, address _accountant) {
        if (_vault == address(0)) revert ZeroAddress();
        if (_teller == address(0)) revert ZeroAddress();
        if (_accountant == address(0)) revert ZeroAddress();

        vault = _vault;
        teller = _teller;
        accountant = _accountant;

        _disableInitializers();
    }

    // ============================================
    // Initializer
    // ============================================

    /**
     * @notice Initialize proxy state (called once per proxy deployment)
     * @dev Initializes parent KingVault and BoringVault-specific state
     * @dev Can only be called once per proxy (initializer modifier)
     * @param _owner Protocol owner address (access control)
     * @param _kingVault King Protocol core vault address (deposit/withdraw authorization)
     * @param _priceProvider Price oracle address (TVL calculations)
     * @param _atomicQueue Veda AtomicQueue address (withdrawal requests)
     * @param _tokens Initial asset addresses to register
     * @param _accepted Initial acceptance status for each asset
     */
    function initialize(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address _atomicQueue,
        address[] memory _tokens,
        bool[] memory _accepted
    ) external initializer {
        if (_atomicQueue == address(0)) revert ZeroAddress();

        // Initialize parent KingVault
        __KingVault_init(_owner, _kingVault, _priceProvider, _tokens, _accepted);

        // Initialize BoringVault state
        atomicQueue = _atomicQueue;
        maxSlippageBPS = DEFAULT_SLIPPAGE_BPS;
        withdrawalDuration = 7 days;
    }

    // ============================================
    // UUPS Upgrade
    // ============================================

    /**
     * @notice Authorization for contract upgrades is inherited from KingVaultStorage
     * @dev KingVaultStorage._authorizeUpgrade() requires owner via _checkOwner()
     * @dev No need to override - parent implementation is sufficient
     */
}
