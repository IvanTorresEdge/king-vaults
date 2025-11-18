// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVault} from "../base/KingVault.sol";
import {KingTokenizedVaultStorage} from "./KingTokenizedVaultStorage.sol";
import {IKingVault} from "../interfaces/IKingVault.sol";
import {IPriceProvider} from "../interfaces/IPriceProvider.sol";
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
    using SafeERC20 for IERC20;

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
     * @notice Thrown when attempting withdrawal operation in wrong mode
     */
    error InvalidWithdrawalMode();

    /**
     * @notice Thrown when no withdrawal request exists for the specified asset
     * @param asset Asset address with no pending request
     */
    error NoWithdrawalRequest(address asset);

    /**
     * @notice Thrown when withdrawal request deadline has expired
     * @param asset Asset address of expired request
     * @param deadline Expiration timestamp that was exceeded
     */
    error WithdrawalExpired(address asset, uint64 deadline);

    /**
     * @notice Thrown when attempting to create duplicate withdrawal request
     * @param asset Asset address with existing pending request
     */
    error PendingWithdrawalExists(address asset);

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

    /**
     * @notice Thrown when distributeProfits called but no profits are queued
     * @dev Prevents unnecessary gas consumption on empty distribution
     */
    error NoProfitsToDistribute();

    /**
     * @notice Thrown when slippage parameter exceeds maximum allowed (10%)
     * @dev Maximum slippage is 1000 basis points (10%)
     * @param slippage Requested slippage that was rejected
     */
    error InvalidSlippage(uint16 slippage);

    /**
     * @notice Thrown when withdrawal duration is invalid (0 or > 30 days)
     * @dev Duration must be between 1 second and 30 days
     * @param duration Invalid duration value
     */
    error InvalidDuration(uint64 duration);

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
     * @notice Emitted when slippage is updated via setMaxSlippage
     * @dev Simplified version without old value tracking
     * @param newSlippage New slippage in basis points
     */
    event SlippageUpdated(uint16 newSlippage);

    /**
     * @notice Emitted when profits are distributed to main vault (Type B)
     * @dev Tracks completion of profit distribution cycle
     * @param asset ERC-20 token address distributed
     * @param amount Token amount distributed
     */
    event ProfitsDistributed(address indexed asset, uint256 amount);

    /**
     * @notice Emitted when proxy is initialized
     * @dev Tracks initial configuration for monitoring and verification
     * @param owner Protocol owner address
     * @param kingVault King Protocol core vault address
     * @param priceProvider Price oracle address
     * @param timestamp Block timestamp of initialization
     */
    event Initialized(address indexed owner, address indexed kingVault, address priceProvider, uint256 timestamp);

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
    function depositToVault(address asset, uint256 amount) external onlyOwner whenNotPaused returns (uint256 shares) {
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

    /**
     * @notice Withdraw assets from ERC-4626 vault (both atomic and async modes)
     * @dev Only callable by owner when not paused
     * @dev Atomic mode: Completes immediately via IERC4626.redeem()
     * @dev Async mode: Creates withdrawal request, locks shares, requires completeWithdrawal()
     * @param asset ERC-20 token address to receive
     * @param shareAmount Vault share amount to redeem
     * @param isProfitWithdrawal True for Type B (profit), false for Type A (principal)
     * @return assetsReceived Amount of assets received (atomic mode only, 0 for async)
     */
    function withdrawFromVault(address asset, uint256 shareAmount, bool isProfitWithdrawal)
        external
        onlyOwner
        whenNotPaused
        returns (uint256 assetsReceived)
    {
        // Validate share amount
        if (shareAmount == 0) revert ZeroAmount();

        // Validate asset is registered
        if (!_registeredTokens[asset]) revert AssetNotAccepted(asset);

        // Calculate available shares (total - total pending across all assets)
        uint256 totalShares = IERC20(vault).balanceOf(address(this));
        uint256 totalPending = _getTotalPendingShares();
        uint256 availableShares = totalShares - totalPending;

        // Check sufficient shares available
        if (availableShares < shareAmount) {
            revert InsufficientBalance(vault, shareAmount, availableShares);
        }

        if (isAtomic) {
            // ATOMIC MODE: Immediate redemption
            // Preview expected assets and calculate minimum acceptable
            uint256 expectedAssets = IERC4626(vault).convertToAssets(shareAmount);
            uint256 minAssets = Math.mulDiv(expectedAssets, 10_000 - maxSlippageBPS, 10_000);

            // Redeem shares for assets
            assetsReceived = IERC4626(vault).redeem(shareAmount, address(this), address(this));

            // Validate slippage protection
            if (assetsReceived < minAssets) {
                revert SlippageExceeded(expectedAssets, assetsReceived);
            }

            // Track in appropriate queue based on type
            // IMPORTANT: In atomic mode, only profit withdrawals are queued for distribution
            // Principal withdrawals complete immediately and assets become available for Flow A withdrawal
            if (isProfitWithdrawal) {
                _queuedProfits[asset] += assetsReceived;
            }
            // Note: Principal withdrawals (isProfitWithdrawal=false) do NOT queue in atomic mode
            // Assets are immediately available for withdrawal to kingVault via withdraw()

            // Emit completion event
            emit WithdrawalConfirmed(asset, assetsReceived);
        } else {
            // ASYNC MODE: Create withdrawal request
            // Prevent duplicate requests for same asset
            if (_withdrawalRequests[asset].asset != address(0)) {
                revert PendingWithdrawalExists(asset);
            }

            // Preview expected assets for request record
            uint256 expectedAssets = IERC4626(vault).convertToAssets(shareAmount);

            // Create withdrawal request (Type A - principal withdrawal)
            _withdrawalRequests[asset] = WithdrawalRequest({
                asset: asset,
                shares: shareAmount,
                expected: expectedAssets,
                deadline: uint64(block.timestamp + withdrawalDuration),
                isProfitWithdrawal: false
            });

            // Lock shares for this asset
            _pendingSharesByAsset[asset] += shareAmount;

            // Emit queue event
            emit WithdrawalQueued(asset, shareAmount, expectedAssets, _withdrawalRequests[asset].deadline);

            assetsReceived = 0; // Return 0 for async (not yet completed)
        }
    }

    /**
     * @notice Complete pending async withdrawal request
     * @dev Only callable in async mode
     * @dev Validates deadline, redeems shares, routes to appropriate queue
     * @dev Routes assets based on WithdrawalRequest.isProfitWithdrawal flag
     * @param asset Asset address of pending request
     * @return assetsReceived Amount of assets received
     */
    function completeWithdrawal(address asset) external onlyOwner whenNotPaused returns (uint256 assetsReceived) {
        // Validate async mode
        if (isAtomic) revert InvalidWithdrawalMode();

        // Get withdrawal request
        WithdrawalRequest memory request = _withdrawalRequests[asset];

        // Validate request exists
        if (request.asset == address(0)) revert NoWithdrawalRequest(asset);

        // Validate deadline not expired
        if (block.timestamp > request.deadline) {
            revert WithdrawalExpired(asset, request.deadline);
        }

        // Calculate minimum acceptable assets with slippage
        uint256 minAssets = Math.mulDiv(request.expected, 10_000 - maxSlippageBPS, 10_000);

        // Redeem shares for assets
        assetsReceived = IERC4626(vault).redeem(request.shares, address(this), address(this));

        // Validate slippage protection
        if (assetsReceived < minAssets) {
            revert SlippageExceeded(request.expected, assetsReceived);
        }

        // Release locked shares for this asset
        _pendingSharesByAsset[asset] -= request.shares;

        // Track in appropriate queue based on withdrawal type (Type A vs Type B)
        if (request.isProfitWithdrawal) {
            // Type B: Profit withdrawal - queue for distribution
            _queuedProfits[asset] += assetsReceived;
        } else {
            // Type A: Principal withdrawal - queue for return to main vault
            _queuedWithdraw[asset] += assetsReceived;
        }

        // Clear withdrawal request
        delete _withdrawalRequests[asset];

        // Emit completion event
        emit WithdrawalConfirmed(asset, assetsReceived);
    }

    /**
     * @notice Cancel pending async withdrawal request
     * @dev Only callable in async mode
     * @dev Releases locked shares back to available pool
     * @param asset Asset address of pending request
     */
    function cancelWithdrawal(address asset) external onlyOwner {
        // Validate async mode
        if (isAtomic) revert InvalidWithdrawalMode();

        // Get withdrawal request
        WithdrawalRequest memory request = _withdrawalRequests[asset];

        // Validate request exists
        if (request.asset == address(0)) revert NoWithdrawalRequest(asset);

        // Release locked shares for this asset
        _pendingSharesByAsset[asset] -= request.shares;

        // Clear withdrawal request
        delete _withdrawalRequests[asset];

        // Emit cancellation event
        emit WithdrawalCancelled(asset, request.shares);
    }

    /**
     * @notice Calculate available balance for withdrawals to main vault (override)
     * @dev Returns idle balance minus queued operations (principal + profit withdrawals)
     * @dev Protects assets reserved for Type A (principal) and Type B (profit) operations
     * @param _asset Asset address to check
     * @return Available amount that can be safely withdrawn to main vault
     *
     * @custom:formula available = idle - queuedPrincipal - queuedProfit
     * @custom:override Adds withdrawal queue tracking to base implementation
     */
    function availableForWithdraw(address _asset) public view override returns (uint256) {
        // Get idle balance (not deployed to vault)
        uint256 idle = IERC20(_asset).balanceOf(address(this));

        // Get queued amounts (dual tracking)
        uint256 queuedPrincipal = _queuedWithdraw[_asset];
        uint256 queuedProfit = _queuedProfits[_asset];

        // Calculate available (return 0 if queued amounts exceed idle)
        uint256 reserved = queuedPrincipal + queuedProfit;

        if (idle <= reserved) return 0;

        return idle - reserved;
    }

    /**
     * @notice Override withdraw to add availability protection
     * @dev Prevents withdrawal of assets locked in shares or queued operations
     * @dev Validates ALL amounts before executing ANY transfers (atomic check)
     * @param _tokens Array of asset addresses to withdraw
     * @param _amounts Array of amounts to withdraw
     * @param _receiver Address to receive withdrawn assets
     */
    function withdraw(address[] memory _tokens, uint256[] memory _amounts, address _receiver) public override {
        // Access control: only kingVault can call
        _requireKingVault();

        // Pause check
        _requireNotPaused();

        // Validate receiver
        if (_receiver == address(0)) revert ZeroAddress();

        // Validate arrays
        if (_tokens.length == 0 || _tokens.length != _amounts.length) {
            revert InvalidAssetArray();
        }

        // CRITICAL: Check availability for ALL assets BEFORE any transfers
        // This ensures atomic behavior - either all succeed or all fail
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 amount = _amounts[i];

            if (amount == 0) revert ZeroAmount();

            uint256 available = availableForWithdraw(token);
            if (available < amount) {
                revert InsufficientAvailableBalance(token, amount, available);
            }
        }

        // All checks passed - execute withdrawals
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 amount = _amounts[i];

            // Transfer tokens to receiver
            SafeERC20.safeTransfer(IERC20(token), _receiver, amount);

            // Update principal tracking
            _deposits[token] -= amount;

            // SECURITY FIX (CF-02): Decrement _queuedWithdraw when returning recalled principal
            // This prevents deadlock where _queuedWithdraw stays sticky after completeWithdrawal()
            uint256 queuedAmount = _queuedWithdraw[token];
            if (queuedAmount > 0) {
                // Decrement up to the amount being withdrawn
                uint256 toDeduct = amount < queuedAmount ? amount : queuedAmount;
                _queuedWithdraw[token] -= toDeduct;
            }
        }

        // Emit event
        emit Withdrawn(_tokens, _amounts, _receiver, block.timestamp);
    }

    /**
     * @notice Get withdrawal request details for an asset
     * @dev Returns empty struct if no request exists
     * @param asset Asset address to query
     * @return request Withdrawal request details
     */
    function getWithdrawalRequest(address asset) external view returns (WithdrawalRequest memory request) {
        return _withdrawalRequests[asset];
    }

    /**
     * @notice Get current vault shares held by this contract
     * @dev Reads ERC-4626 share token balance
     * @return shares Total vault shares owned
     */
    function getVaultShares() external view returns (uint256 shares) {
        return IERC20(vault).balanceOf(address(this));
    }

    // NOTE: tvl() function is inherited from parent KingVault
    // It correctly uses _deposits mapping for principal-only TVL tracking
    // Share appreciation does NOT affect TVL - it's tracked as profit separately
    //
    // CRITICAL ACCOUNTING:
    // - _deposits[asset] only changes when King main vault calls deposit()/withdraw()
    // - Deployment to ERC-4626 vault does NOT affect TVL (principal unchanged)
    // - Share value appreciation does NOT affect TVL
    // - Profit = shareValue - principal (separate from TVL, tracked by calculateProfit)
    //
    // Example: 10 WETH deposited → deployed to ERC-4626 vault
    //   Later: ERC-4626 shares appreciate 1.5x
    //   TVL remains 10 WETH (principal only)
    //   Profit = (10 WETH × 1.5) - 10 WETH = 5 WETH (NOT in TVL)

    // ============================================
    // Flow B: Profit Management
    // ============================================

    /**
     * @notice Calculate current profit from share appreciation
     * @dev Profit = (current share value in ETH) - (principal deposits in ETH)
     * @dev Uses price provider for asset-to-ETH conversions
     * @dev Handles multi-asset principal tracking via _deposits mapping
     * @return profitInEth Total profit across all assets in ETH (18 decimals)
     */
    function calculateProfit() public view returns (uint256 profitInEth) {
        // Get price provider
        IPriceProvider provider = IPriceProvider(priceProvider);

        // Calculate total principal value in ETH
        uint256 totalPrincipalEth = 0;
        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];

            // Skip if not registered
            if (!_registeredTokens[asset]) continue;

            // Get principal amount
            uint256 principal = _deposits[asset];
            if (principal == 0) continue;

            // Get price in ETH
            uint256 priceInEth = provider.getPriceInEth(asset);
            if (priceInEth == 0) revert PriceNotAvailable(asset);

            // Get decimals
            uint8 decimals = IERC20Metadata(asset).decimals();

            // Calculate principal value in ETH
            uint256 principalEth = Math.mulDiv(principal, priceInEth, 10 ** decimals);
            totalPrincipalEth += principalEth;
        }

        // Calculate current share value in ETH
        uint256 shares = IERC20(vault).balanceOf(address(this));

        if (shares == 0) {
            return 0; // No shares = no profit
        }

        // Convert shares to assets using ERC-4626
        uint256 currentAssets = IERC4626(vault).convertToAssets(shares);

        // Get the underlying asset of the ERC-4626 vault
        address underlyingAsset = IERC4626(vault).asset();

        // Convert current assets to ETH
        uint256 assetPriceInEth = provider.getPriceInEth(underlyingAsset);
        if (assetPriceInEth == 0) revert PriceNotAvailable(underlyingAsset);

        uint8 assetDecimals = IERC20Metadata(underlyingAsset).decimals();
        uint256 currentValueEth = Math.mulDiv(currentAssets, assetPriceInEth, 10 ** assetDecimals);

        // Calculate profit (current value - principal)
        if (currentValueEth <= totalPrincipalEth) {
            return 0; // No profit or loss
        }

        return currentValueEth - totalPrincipalEth;
    }

    /**
     * @notice Override harvestProfits to implement ERC-4626 profit withdrawal
     * @dev Calculates profit shares and queues Type B withdrawal
     * @dev Only callable by owner when not paused
     * @dev Profit = (current share value) - (principal deposits)
     */
    function harvestProfits() external override onlyOwner whenNotPaused {
        // Calculate current profit
        uint256 profitInEth = calculateProfit();

        // Revert if no profit to harvest
        if (profitInEth == 0) revert NoProfitToHarvest();

        // Get current shares
        uint256 totalShares = IERC20(vault).balanceOf(address(this));
        if (totalShares == 0) revert NoShares();

        // Calculate current share value in ETH
        uint256 currentAssets = IERC4626(vault).convertToAssets(totalShares);
        address underlyingAsset = IERC4626(vault).asset();

        IPriceProvider provider = IPriceProvider(priceProvider);
        uint256 assetPriceInEth = provider.getPriceInEth(underlyingAsset);
        if (assetPriceInEth == 0) revert PriceNotAvailable(underlyingAsset);

        uint8 assetDecimals = IERC20Metadata(underlyingAsset).decimals();
        uint256 currentValueEth = Math.mulDiv(currentAssets, assetPriceInEth, 10 ** assetDecimals);

        if (currentValueEth == 0) revert NoShareValue();

        // Calculate profit shares: (profitInEth / currentValueEth) * totalShares
        uint256 profitShares = Math.mulDiv(profitInEth, totalShares, currentValueEth);

        if (profitShares == 0) revert NoProfitShares();
        if (profitShares > totalShares) revert InvalidProfitCalculation();

        // Validate sufficient shares available (not already pending)
        uint256 totalPending = _getTotalPendingShares();
        uint256 availableShares = totalShares - totalPending;
        if (availableShares < profitShares) {
            revert InsufficientBalance(vault, profitShares, availableShares);
        }

        // Execute withdrawal based on mode
        if (isAtomic) {
            // ATOMIC MODE: Immediate redemption
            uint256 expectedAssets = IERC4626(vault).convertToAssets(profitShares);
            uint256 minAssets = Math.mulDiv(expectedAssets, 10_000 - maxSlippageBPS, 10_000);

            // Redeem shares for assets
            uint256 assetsReceived = IERC4626(vault).redeem(profitShares, address(this), address(this));

            // Validate slippage
            if (assetsReceived < minAssets) {
                revert SlippageExceeded(expectedAssets, assetsReceived);
            }

            // Track in profit queue (Type B)
            _queuedProfits[underlyingAsset] += assetsReceived;

            // Emit events
            emit ProfitSharesQueued(profitShares, profitInEth);
            emit WithdrawalConfirmed(underlyingAsset, assetsReceived);
        } else {
            // ASYNC MODE: Create withdrawal request
            if (_withdrawalRequests[underlyingAsset].asset != address(0)) {
                revert PendingWithdrawalExists(underlyingAsset);
            }

            uint256 expectedAssets = IERC4626(vault).convertToAssets(profitShares);

            // Create withdrawal request (Type B - profit withdrawal)
            _withdrawalRequests[underlyingAsset] = WithdrawalRequest({
                asset: underlyingAsset,
                shares: profitShares,
                expected: expectedAssets,
                deadline: uint64(block.timestamp + withdrawalDuration),
                isProfitWithdrawal: true
            });

            // Lock shares for this asset
            _pendingSharesByAsset[underlyingAsset] += profitShares;

            // Emit events
            emit ProfitSharesQueued(profitShares, profitInEth);
            emit WithdrawalQueued(
                underlyingAsset, profitShares, expectedAssets, _withdrawalRequests[underlyingAsset].deadline
            );
        }

        // Emit harvest event
        emit ProfitsHarvested(block.timestamp);
    }

    /**
     * @notice Override distributeProfits to process queued profit withdrawals
     * @dev Processes _queuedProfits and delegates to base class for proper recipient distribution
     * @dev Type B withdrawal completion - distributes harvested profits to configured recipients
     * @dev SECURITY FIX (HF-01): Delegates to base class to respect _profitsRecipients configuration
     */
    function distributeProfits() external override onlyOwner whenNotPaused {
        // Check if there are queued profits
        bool hasProfits = false;
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_queuedProfits[_assets[i]] > 0) {
                hasProfits = true;
                break;
            }
        }

        if (!hasProfits) revert NoProfitsToDistribute();

        // SECURITY FIX (HF-01): Move queued profits to _deposits so base class can distribute them
        // This makes profits visible to base distributeProfits() logic as "balance > principal"
        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];
            uint256 profitAmount = _queuedProfits[asset];

            if (profitAmount > 0) {
                // Verify we have the assets
                uint256 balance = IERC20(asset).balanceOf(address(this));
                if (balance < profitAmount) {
                    revert InsufficientBalance(asset, profitAmount, balance);
                }

                // Add profits to deposits so base class sees: balance > _deposits = profit
                _deposits[asset] += profitAmount;

                // Clear queued profits
                _queuedProfits[asset] = 0;
            }
        }

        // Delegate to base class which properly distributes to _profitsRecipients
        // Base class calculates: profit = balance - _deposits for each asset
        // Now that we've added _queuedProfits to _deposits, base class will see them as profit
        super.distributeProfits();
    }

    // ============================================
    // Internal Helpers
    // ============================================

    /**
     * @notice Calculate total pending shares across all assets
     * @dev Sums _pendingSharesByAsset for all registered assets
     * @return totalPending Total shares committed to pending withdrawals
     */
    function _getTotalPendingShares() internal view returns (uint256 totalPending) {
        for (uint256 i = 0; i < _assets.length; i++) {
            totalPending += _pendingSharesByAsset[_assets[i]];
        }
        return totalPending;
    }

    // ============================================
    // Configuration Functions
    // ============================================

    /**
     * @notice Set maximum slippage tolerance for deposits
     * @dev Only owner can update slippage parameters
     * @param _maxSlippageBPS Maximum slippage in basis points (1 BPS = 0.01%)
     * @custom:throws InvalidSlippage if slippage exceeds 10% (1000 BPS)
     */
    function setMaxSlippage(uint16 _maxSlippageBPS) external onlyOwner {
        if (_maxSlippageBPS > 1000) revert InvalidSlippage(_maxSlippageBPS);
        maxSlippageBPS = _maxSlippageBPS;
        emit SlippageUpdated(_maxSlippageBPS);
    }

    /**
     * @notice Set default duration for withdrawal requests
     * @dev Only owner can update withdrawal duration
     * @param _withdrawalDuration Duration in seconds for withdrawal deadlines
     * @custom:throws InvalidDuration if duration is 0 or exceeds 30 days
     */
    function setWithdrawalDuration(uint64 _withdrawalDuration) external onlyOwner {
        if (_withdrawalDuration == 0 || _withdrawalDuration > 30 days) {
            revert InvalidDuration(_withdrawalDuration);
        }
        uint64 oldDuration = withdrawalDuration;
        withdrawalDuration = _withdrawalDuration;
        emit WithdrawalDurationUpdated(oldDuration, _withdrawalDuration);
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
