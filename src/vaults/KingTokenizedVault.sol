// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVault} from "../base/KingVault.sol";
import {KingTokenizedVaultStorage} from "./KingTokenizedVaultStorage.sol";
import {IKingVault} from "../interfaces/IKingVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title KingTokenizedVault
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice King Vault implementation for ERC-4626 compliant vault integration
 * @dev Extends KingVault with ERC-4626-specific deposit/withdrawal logic
 * @dev Uses dual operational flows: Flow A (custody) and Flow B (deployment)
 * @dev Tracks principal separately from share appreciation for profit calculation
 *
 * Architecture:
 * - Inherits: KingTokenizedVaultStorage (state) + KingVault (base logic)
 * - Integrates: Any ERC-4626 compliant vault (Concrete, etc.)
 * - Pattern: UUPS proxy with immutable external vault address
 *
 * Key Features:
 * - Atomic OR async withdrawals (configured at deployment)
 * - Dual flow architecture (Flow A: custody, Flow B: deployment)
 * - Profit tracking: Separate principal from share appreciation
 * - Configurable: Slippage tolerance, withdrawal duration
 * - Emergency controls: Pause, upgrade, configuration
 *
 * Integration Flow:
 * 1. deposit(): Transfer asset from core vault (Flow A)
 * 2. depositToVault(): Deploy to ERC-4626, receive shares (Flow B)
 * 3. withdrawFromVault(): Queue/execute withdrawal (Flow B)
 * 4. withdraw(): Return assets to core vault (Flow A)
 * 5. harvestProfits(): Calculate and withdraw profit shares
 */
contract KingTokenizedVault is KingTokenizedVaultStorage, KingVault {
    // ============================================
    // Constants
    // ============================================

    /**
     * @notice Maximum allowed slippage limit (1000 BPS = 10%)
     * @dev Prevents owner from setting excessive slippage tolerance
     */
    uint16 public constant MAX_SLIPPAGE_LIMIT = 10_00; // 10%

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
     * @dev Check that withdrawal was initiated before completing
     */
    error WithdrawalNotQueued();

    /**
     * @notice Thrown when attempting to cancel a non-existent withdrawal request
     * @dev Verify withdrawal exists before canceling
     */
    error NoWithdrawalQueued();

    /**
     * @notice Thrown when attempting to harvest profits with no queued withdrawals
     * @dev Ensure profit withdrawal was initiated before harvesting
     */
    error NoProfitsQueued();

    /**
     * @notice Thrown when slippage protection fails (received < expected)
     * @param expected Expected shares/assets based on conversion rate
     * @param received Actual shares/assets received
     */
    error SlippageExceeded(uint256 expected, uint256 received);

    /**
     * @notice Thrown when slippage exceeds maximum allowed limit
     * @param requested The requested slippage in BPS
     * @param maximum The maximum allowed slippage in BPS
     */
    error SlippageExceedsLimit(uint16 requested, uint16 maximum);

    /**
     * @notice Thrown when attempting to harvest profits with no profit available
     * @dev Indicates share value has not appreciated since last harvest
     */
    error NoProfitToHarvest();

    /**
     * @notice Thrown when share value calculation returns zero
     * @dev Indicates vault is returning zero conversion rate
     */
    error NoShareValue();

    /**
     * @notice Thrown when vault has no shares but profit harvest is attempted
     * @dev Should never happen in normal flow as deposits create shares
     */
    error NoShares();

    /**
     * @notice Thrown when profit share calculation returns zero
     * @dev Indicates no actual profit despite profitInEth being positive
     */
    error NoProfitShares();

    /**
     * @notice Thrown when calculated profit shares exceed current vault shares
     * @dev This indicates a serious calculation error and prevents over-withdrawal
     */
    error InvalidProfitCalculation();

    // ============================================
    // Events
    // ============================================

    /**
     * @notice Emitted when assets are successfully deposited to ERC-4626 vault
     * @dev Indicates deposit completed and shares received
     * @param asset ERC-20 token address deposited
     * @param amount Token amount deposited to vault
     * @param sharesReceived Vault share tokens minted
     */
    event DepositCompleted(address indexed asset, uint256 amount, uint256 sharesReceived);

    /**
     * @notice Emitted when withdrawal is queued or completed
     * @dev For atomic mode: withdrawal completed immediately
     * @dev For async mode: withdrawal queued, requires completion call
     * @param asset ERC-20 token address withdrawn
     * @param shareAmount Vault shares withdrawn
     * @param expectedAmount Asset amount expected from withdrawal
     * @param deadline Unix timestamp for async mode deadline (0 for atomic)
     */
    event WithdrawalQueued(address indexed asset, uint256 shareAmount, uint256 expectedAmount, uint64 deadline);

    /**
     * @notice Emitted when async withdrawal is completed
     * @dev Only emitted in async mode after completeWithdrawal() call
     * @param asset ERC-20 token address received
     * @param amountReceived Actual asset amount received
     */
    event WithdrawalConfirmed(address indexed asset, uint256 amountReceived);

    /**
     * @notice Emitted when withdrawal request is cancelled
     * @dev Shares returned to available pool, accounting restored
     * @param asset ERC-20 token address of cancelled request
     * @param shareAmount Vault shares returned to available pool
     */
    event WithdrawalCancelled(address indexed asset, uint256 shareAmount);

    /**
     * @notice Emitted when profit shares are queued for withdrawal (Type B)
     * @dev Tracks profit harvest initiation
     * @param profitShares Vault shares representing profits
     * @param profitValue ETH-denominated value of profit shares
     */
    event ProfitSharesQueued(uint256 profitShares, uint256 profitValue);

    /**
     * @notice Emitted when maximum slippage tolerance is updated
     * @dev Affects deposit/withdrawal slippage protection calculations
     * @param oldSlippage Previous slippage in basis points
     * @param newSlippage New slippage in basis points
     */
    event MaxSlippageUpdated(uint16 oldSlippage, uint16 newSlippage);

    /**
     * @notice Emitted when withdrawal duration default is updated
     * @dev Affects deadline calculation for new withdrawal requests (async mode)
     * @param oldDuration Previous duration in seconds
     * @param newDuration New duration in seconds
     */
    event WithdrawalDurationUpdated(uint64 oldDuration, uint64 newDuration);

    /**
     * @notice Emitted when proxy is initialized
     * @dev Tracks initial configuration for monitoring and verification
     * @param owner Protocol owner address
     * @param kingVault King Protocol core vault address
     * @param priceProvider Price oracle address
     * @param timestamp Block timestamp of initialization
     */
    event Initialized(
        address indexed owner,
        address indexed kingVault,
        address priceProvider,
        uint256 timestamp
    );

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Initialize immutable ERC-4626 integration addresses
     * @dev Constructor runs once during implementation deployment (NOT proxy)
     * @dev Disables initializers to prevent implementation contract initialization
     * @param _vault ERC-4626 vault contract address
     * @param _isAtomic Withdrawal mode (true = atomic, false = async)
     */
    constructor(address _vault, bool _isAtomic) {
        if (_vault == address(0)) revert ZeroAddress();

        vault = _vault;
        isAtomic = _isAtomic;

        _disableInitializers();
    }

    // ============================================
    // Initializer
    // ============================================

    /**
     * @notice Initialize proxy state (called once per proxy deployment)
     * @dev Initializes parent KingVault and KingTokenizedVault-specific state
     * @dev Can only be called once per proxy (initializer modifier)
     * @param _owner Protocol owner address (access control)
     * @param _kingVault King Protocol core vault address (deposit/withdraw authorization)
     * @param _priceProvider Price oracle address (TVL calculations)
     * @param _assets Initial asset addresses to register
     * @param _accepted Initial acceptance status for each asset
     */
    function initialize(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address[] memory _assets,
        bool[] memory _accepted
    ) external initializer {
        // Validate all address parameters
        if (_owner == address(0)) revert ZeroAddress();
        if (_kingVault == address(0)) revert ZeroAddress();
        if (_priceProvider == address(0)) revert ZeroAddress();

        // Initialize parent KingVault
        __KingVault_init(_owner, _kingVault, _priceProvider, _assets, _accepted);

        // Initialize KingTokenizedVault state
        maxSlippageBPS = DEFAULT_SLIPPAGE_BPS;
        withdrawalDuration = 7 days;

        // Emit initialization event for auditability
        emit Initialized(_owner, _kingVault, _priceProvider, block.timestamp);
    }

    /**
     * @notice Deploy idle assets to ERC-4626 vault (atomic mode)
     * @dev Only callable by owner when not paused
     * @dev Validates asset, approves vault, deposits and receives shares
     * @dev Applies slippage protection based on maxSlippageBPS
     * @param asset ERC-20 token address to deposit
     * @param amount Asset amount to deposit
     * @return shares Amount of vault shares received
     */
    function depositToVault(address asset, uint256 amount)
        external
        onlyOwner
        whenNotPaused
        returns (uint256 shares)
    {
        // Validate amount
        if (amount == 0) revert ZeroAmount();

        // Validate asset is registered
        if (!_registeredTokens[asset]) revert AssetNotAccepted(asset);

        // Check sufficient idle balance
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (idle < amount) {
            revert InsufficientAvailableBalance(asset, amount, idle);
        }

        // Preview expected shares and calculate minimum acceptable
        uint256 expectedShares = IERC4626(vault).convertToShares(amount);
        uint256 minShares = Math.mulDiv(expectedShares, 10_000 - maxSlippageBPS, 10_000);

        // Approve vault to spend assets
        SafeERC20.forceApprove(IERC20(asset), vault, amount);

        // Deposit to ERC-4626 vault and receive shares
        shares = IERC4626(vault).deposit(amount, address(this));

        // Validate slippage protection
        if (shares < minShares) {
            revert SlippageExceeded(expectedShares, shares);
        }

        // Emit deposit event
        emit DepositCompleted(asset, amount, shares);
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
