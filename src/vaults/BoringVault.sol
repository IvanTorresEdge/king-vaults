// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVault} from "../base/KingVault.sol";
import {IKingVault} from "../interfaces/IKingVault.sol";
import {ITellerWithMultiAssetSupport} from "../interfaces/external/ITellerWithMultiAssetSupport.sol";
import {IAccountantWithRateProviders} from "../interfaces/external/IAccountantWithRateProviders.sol";
import {IAtomicQueue} from "../interfaces/external/IAtomicQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceProvider} from "../interfaces/IPriceProvider.sol";

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

    /**
     * @notice Thrown when slippage protection fails (received < expected)
     * @param expected Expected shares based on accountant rate
     * @param received Actual shares received from deposit
     */
    error SlippageExceeded(uint256 expected, uint256 received);

    // ============================================
    // Events
    // ============================================

    /**
     * @notice Emitted when assets are successfully deposited to BoringVault via Teller
     * @dev Indicates atomic deposit completed and shares received
     * @param token ERC-20 token address deposited
     * @param amount Token amount deposited to Teller
     * @param sharesReceived BoringVault share tokens minted
     */
    event DepositCompleted(address indexed token, uint256 amount, uint256 sharesReceived);

    /**
     * @notice Emitted when withdrawal request is queued in AtomicQueue
     * @dev Indicates shares committed to pending withdrawal (Type A or Type B)
     * @param asset ERC-20 token address we expect to receive
     * @param shareAmount BoringVault shares offered for withdrawal
     * @param expectedAmount Asset amount expected from solver
     * @param deadline Unix timestamp after which request expires
     */
    event WithdrawalQueued(
        address indexed asset,
        uint256 shareAmount,
        uint256 expectedAmount,
        uint64 deadline
    );

    /**
     * @notice Emitted when withdrawal is fulfilled by solver
     * @dev Indicates assets received and shares transferred to solver
     * @param asset ERC-20 token address received
     * @param amountReceived Actual asset amount received from solver
     */
    event WithdrawalConfirmed(address indexed asset, uint256 amountReceived);

    /**
     * @notice Emitted when withdrawal request is cancelled before fulfillment
     * @dev Shares returned to available pool, accounting restored
     * @param asset ERC-20 token address of cancelled request
     * @param shareAmount BoringVault shares returned to available pool
     */
    event WithdrawalCancelled(address indexed asset, uint256 shareAmount);

    /**
     * @notice Emitted when profit shares are queued for withdrawal (Type B)
     * @dev Tracks profit harvest initiation before solver fulfillment
     * @param profitShares BoringVault shares representing profits
     * @param profitValue ETH-denominated value of profit shares
     */
    event ProfitSharesQueued(uint256 profitShares, uint256 profitValue);

    /**
     * @notice Emitted when principal withdrawal completes (Type A)
     * @dev Assets returned to King main vault after solver fulfills
     * @param asset ERC-20 token address withdrawn
     * @param amount Asset amount transferred to receiver
     * @param receiver Address receiving assets (King main vault)
     * @param timestamp Block timestamp of completion
     */
    event PrincipalWithdrawCompleted(
        address indexed asset,
        uint256 amount,
        address indexed receiver,
        uint256 timestamp
    );

    /**
     * @notice Emitted when principal withdrawal request is cancelled (Type A)
     * @dev Principal deposits restored, queued tracking cleared
     * @param asset ERC-20 token address of cancelled withdrawal
     * @param amount Asset amount that was queued (now restored)
     * @param timestamp Block timestamp of cancellation
     */
    event WithdrawFromVaultCancelled(address indexed asset, uint256 amount, uint256 timestamp);

    /**
     * @notice Emitted when profit harvest request is cancelled (Type B)
     * @dev Profit shares returned to vault, queued profit tracking cleared
     * @param asset ERC-20 token address of cancelled harvest
     * @param amount Asset amount that was queued for distribution
     * @param timestamp Block timestamp of cancellation
     */
    event ProfitsHarvestCancelled(address indexed asset, uint256 amount, uint256 timestamp);

    /**
     * @notice Emitted when maximum slippage tolerance is updated
     * @dev Affects deposit slippage protection calculations
     * @param oldSlippage Previous slippage in basis points
     * @param newSlippage New slippage in basis points
     */
    event MaxSlippageUpdated(uint16 oldSlippage, uint16 newSlippage);

    /**
     * @notice Emitted when AtomicQueue address is updated
     * @dev Can only be changed when no pending withdrawals exist
     * @param oldQueue Previous AtomicQueue address
     * @param newQueue New AtomicQueue address
     */
    event AtomicQueueUpdated(address indexed oldQueue, address indexed newQueue);

    /**
     * @notice Emitted when withdrawal duration default is updated
     * @dev Affects deadline calculation for new withdrawal requests
     * @param oldDuration Previous duration in seconds
     * @param newDuration New duration in seconds
     */
    event WithdrawalDurationUpdated(uint64 oldDuration, uint64 newDuration);

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
    // Core Vault Operations
    // ============================================

    /**
     * @notice Deploy idle assets to BoringVault via Teller (atomic operation)
     * @dev Owner-only function to deploy assets from this vault to Veda BoringVault
     * @dev Atomic operation: assets transferred and shares received in single transaction
     * @dev Does NOT modify _deposits (only King main vault modifies principal tracking)
     * @dev Slippage protection: minimumMint calculated from maxSlippageBPS
     *
     * @param _asset ERC-20 token address to deposit
     * @param _amount Token amount to deposit
     * @return shares Amount of BoringVault shares received
     *
     * @custom:validation Asset must be registered via registerAssets()
     * @custom:validation Amount must be > 0
     * @custom:validation Contract must have sufficient idle balance
     * @custom:validation Teller must not be paused
     * @custom:validation Contract must not be paused
     *
     * @custom:security Approves BoringVault (NOT Teller) to spend assets
     * @custom:security Slippage protection via minimumMint calculation
     * @custom:security Verifies shares received >= minimumMint
     *
     * Workflow:
     * 1. Validate inputs (registered asset, amount > 0, sufficient balance)
     * 2. Calculate expected shares using accountant rate
     * 3. Apply slippage protection: minShares = expected × (10000 - maxSlippageBPS) / 10000
     * 4. Record share balance before deposit
     * 5. Approve BoringVault to spend assets
     * 6. Call Teller.deposit() with slippage protection
     * 7. Verify shares received >= minShares
     * 8. Emit DepositCompleted event
     *
     * Example:
     * ```solidity
     * // Deploy 1000 ETHFI to BoringVault
     * uint256 shares = boringVault.depositToVault(ETHFI, 1000e18);
     * // Shares received based on current exchange rate
     * // _deposits[ETHFI] unchanged (managed by King main vault)
     * ```
     */
    function depositToVault(
        address _asset,
        uint256 _amount
    ) external onlyOwner whenNotPaused returns (uint256 shares) {
        // Validate inputs
        if (!_registeredTokens[_asset]) revert AssetNotAccepted(_asset);
        if (_amount == 0) revert ZeroAmount();

        // Check sufficient idle balance
        uint256 idle = IERC20(_asset).balanceOf(address(this));
        if (idle < _amount) {
            revert InsufficientAvailableBalance(_asset, _amount, idle);
        }

        // Calculate expected shares and apply slippage protection
        uint256 expectedShares = _calculateExpectedShares(_asset, _amount);
        uint256 minShares = (expectedShares * (10_000 - maxSlippageBPS)) / 10_000;

        // Record share balance before deposit
        uint256 sharesBefore = IERC20(vault).balanceOf(address(this));

        // Approve BoringVault to spend assets (NOT Teller)
        IERC20(_asset).approve(vault, _amount);

        // Execute atomic deposit via Teller
        shares = ITellerWithMultiAssetSupport(teller).deposit(
            ERC20(_asset),
            _amount,
            minShares
        );

        // Verify shares received
        uint256 sharesAfter = IERC20(vault).balanceOf(address(this));
        uint256 sharesReceived = sharesAfter - sharesBefore;

        if (sharesReceived < minShares) {
            revert SlippageExceeded(expectedShares, sharesReceived);
        }

        // NOTE: _deposits[_asset] is NOT modified here
        // Only King main vault modifies _deposits via deposit()/withdraw()
        // This is governance deploying already-tracked assets to Veda

        emit DepositCompleted(_asset, _amount, sharesReceived);

        return sharesReceived;
    }

    /**
     * @notice Queue withdrawal of assets from BoringVault (principal return, Type A)
     * @dev Owner-only function to queue principal withdrawal via AtomicQueue
     * @dev Asynchronous operation: Request queued → solver fulfills → call completePrincipalWithdraw()
     * @dev DUAL TRACKING: Increments _queuedWithdraw[_asset] to protect from profit contamination
     *
     * @param _asset ERC-20 token address we want to receive
     * @param _shareAmount BoringVault shares to withdraw
     * @param _deadline Unix timestamp for request expiration (0 = use default withdrawalDuration)
     */
    function withdrawFromVault(
        address _asset,
        uint256 _shareAmount,
        uint64 _deadline
    ) external onlyOwner whenNotPaused {
        // Validate inputs
        if (_shareAmount == 0) revert ZeroAmount();
        if (!_registeredTokens[_asset]) revert AssetNotAccepted(_asset);

        // Check no pending withdrawal for this asset
        if (_withdrawalRequests[_asset].deadline > 0) {
            revert WithdrawalNotQueued();
        }

        // Check sufficient available shares
        uint256 currentShares = IERC20(vault).balanceOf(address(this));
        uint256 availableShares = currentShares - _pendingShares;

        if (_shareAmount > availableShares) {
            revert InsufficientAvailableBalance(vault, _shareAmount, availableShares);
        }

        // Calculate deadline (use default if not provided)
        uint64 deadline = _deadline == 0 ? uint64(block.timestamp) + withdrawalDuration : _deadline;

        // Calculate expected asset amount from shares
        uint256 expectedAmount = _calculateExpectedAssets(_asset, _shareAmount);

        // Calculate atomic price with slippage protection
        uint256 atomicPrice = _calculateAtomicPrice(_asset, _shareAmount, expectedAmount);

        // Create AtomicRequest struct
        IAtomicQueue.AtomicRequest memory request = IAtomicQueue.AtomicRequest({
            deadline: deadline,
            atomicPrice: uint88(atomicPrice),
            offerAmount: uint96(_shareAmount),
            inSolve: false
        });

        // Approve AtomicQueue to spend shares
        IERC20(vault).approve(atomicQueue, _shareAmount);

        // Queue withdrawal in AtomicQueue
        IAtomicQueue(atomicQueue).updateAtomicRequest(
            ERC20(vault), // offer: BoringVault shares
            ERC20(_asset), // want: Asset we expect to receive
            request
        );

        // Store withdrawal request details
        _withdrawalRequests[_asset] = WithdrawalRequest({
            asset: _asset,
            offer: expectedAmount, // IN-TRANSIT ASSET TRACKING
            want: _shareAmount,
            deadline: deadline
        });

        // Update pending shares
        _pendingShares += _shareAmount;

        // DUAL TRACKING: Increment queued withdraw (Type A tracking)
        _queuedWithdraw[_asset] += expectedAmount;

        emit WithdrawalQueued(_asset, _shareAmount, expectedAmount, deadline);
    }

    /**
     * @notice Complete principal withdrawal after solver fulfillment (Type A)
     * @dev Owner-only function to finalize principal return to King main vault
     * @dev Call this after solver has fulfilled the AtomicQueue request
     * @dev DUAL TRACKING: Decrements _queuedWithdraw[_asset] to clear Type A tracking
     *
     * @param _asset ERC-20 token address received from solver
     * @param _amount Asset amount to transfer to receiver
     * @param _receiver Address to receive assets (typically King main vault)
     */
    function completePrincipalWithdraw(
        address _asset,
        uint256 _amount,
        address _receiver
    ) external onlyOwner whenNotPaused {
        // Validate withdrawal request exists
        WithdrawalRequest memory request = _withdrawalRequests[_asset];
        if (request.deadline == 0) {
            revert WithdrawalNotQueued();
        }

        // Validate amount is within queued range
        uint256 queuedAmount = _queuedWithdraw[_asset];
        if (_amount > queuedAmount) {
            revert InsufficientAvailableBalance(_asset, _amount, queuedAmount);
        }

        // Validate receiver
        if (_receiver == address(0)) revert ZeroAddress();

        // Check sufficient idle balance
        uint256 idle = IERC20(_asset).balanceOf(address(this));
        if (idle < _amount) {
            revert InsufficientAvailableBalance(_asset, _amount, idle);
        }

        // Transfer assets to receiver (main vault)
        SafeERC20.safeTransfer(IERC20(_asset), _receiver, _amount);

        // DUAL TRACKING: Decrement queued withdraw (clear Type A tracking)
        _queuedWithdraw[_asset] -= _amount;

        // Delete withdrawal request
        delete _withdrawalRequests[_asset];

        // Reset pending shares
        _pendingShares = 0;

        emit PrincipalWithdrawCompleted(_asset, _amount, _receiver, block.timestamp);
    }

    /**
     * @notice Cancel pending principal withdrawal request (Type A)
     * @dev Owner-only function to cancel unfulfilled withdrawal and restore state
     * @dev CRITICAL: Restores _deposits[_asset] since parent optimistically reduced it
     * @dev DUAL TRACKING: Decrements _queuedWithdraw[_asset] to clear Type A tracking
     *
     * @param _asset ERC-20 token address of withdrawal to cancel
     */
    function cancelWithdrawFromVault(address _asset) external onlyOwner whenNotPaused {
        // Validate withdrawal request exists
        WithdrawalRequest memory request = _withdrawalRequests[_asset];
        if (request.deadline == 0) {
            revert NoWithdrawalQueued();
        }

        // Get queued amount (must be > 0)
        uint256 queuedAmount = _queuedWithdraw[_asset];
        if (queuedAmount == 0) {
            revert NoWithdrawalQueued();
        }

        // Create empty AtomicRequest to cancel
        IAtomicQueue.AtomicRequest memory emptyRequest =
            IAtomicQueue.AtomicRequest({deadline: 0, atomicPrice: 0, offerAmount: 0, inSolve: false});

        // Cancel withdrawal in AtomicQueue
        IAtomicQueue(atomicQueue).updateAtomicRequest(
            ERC20(vault), // offer: BoringVault shares
            ERC20(_asset), // want: Asset
            emptyRequest
        );

        // CRITICAL: Restore principal deposits (was reduced optimistically)
        _deposits[_asset] += queuedAmount;

        // DUAL TRACKING: Decrement queued withdraw (clear Type A tracking)
        _queuedWithdraw[_asset] -= queuedAmount;

        // Delete withdrawal request
        delete _withdrawalRequests[_asset];

        // Reset pending shares
        _pendingShares = 0;

        emit WithdrawFromVaultCancelled(_asset, queuedAmount, block.timestamp);
    }

    /**
     * @notice Calculate available balance for principal withdrawals (protection function)
     * @dev Prevents profit assets from being withdrawn as principal
     * @dev DUAL TRACKING: Uses both _queuedProfits and _queuedWithdraw
     *
     * @param _asset ERC-20 token address to check
     * @return available Amount available for principal withdrawal (after reserving profits)
     */
    function availableForWithdraw(address _asset) public view returns (uint256) {
        // Get current idle balance
        uint256 balance = IERC20(_asset).balanceOf(address(this));

        // Get principal deposits (from parent)
        uint256 principal = _deposits[_asset];

        // Get queued amounts (dual tracking)
        uint256 queuedProfits = _queuedProfits[_asset];
        uint256 queuedWithdraw = _queuedWithdraw[_asset];

        // Calculate total reserved amount
        uint256 reserved = principal + queuedProfits + queuedWithdraw;

        // Return available (with underflow protection)
        if (balance <= reserved) return 0;
        return balance - reserved;
    }

    /**
     * @notice Withdraw assets from vault (overrides parent to add protection)
     * @dev Only callable by King main vault
     * @dev PROTECTION: Uses availableForWithdraw() to prevent profit contamination
     *
     * @param _assets ERC-20 token addresses to withdraw
     * @param _amounts Token amounts to withdraw (parallel arrays)
     * @param _receiver Address to receive withdrawn assets (King main vault)
     */
    function withdraw(address[] memory _assets, uint256[] memory _amounts, address _receiver)
        external
        override
    {
        // Access control: only kingVault can call
        _requireKingVault();

        // Pause check: cannot withdraw when paused
        _requireNotPaused();
        // Validate arrays
        if (_assets.length != _amounts.length) revert InvalidAssetArray();
        if (_receiver == address(0)) revert ZeroAddress();

        // Process each asset
        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];
            uint256 amount = _amounts[i];

            // Validate inputs
            if (amount == 0) revert ZeroAmount();
            if (!_registeredTokens[asset]) revert AssetNotAccepted(asset);

            // Get idle balance
            uint256 idle = IERC20(asset).balanceOf(address(this));

            if (idle >= amount) {
                // Sufficient idle balance, transfer directly
                SafeERC20.safeTransfer(IERC20(asset), _receiver, amount);
                _deposits[asset] -= amount;
            } else {
                // Need to withdraw from BoringVault
                uint256 needed = amount - idle;

                // PROTECTION: Check availability (prevents profit contamination)
                uint256 available = availableForWithdraw(asset);
                if (needed > available) {
                    revert InsufficientAvailableBalance(asset, needed, available);
                }

                // Transfer any idle first
                if (idle > 0) {
                    SafeERC20.safeTransfer(IERC20(asset), _receiver, idle);
                    _deposits[asset] -= idle;
                }

                // Calculate shares needed for remaining amount
                uint256 rate = IAccountantWithRateProviders(accountant).getRateInQuoteSafe(ERC20(asset));
                uint8 decimals = IAccountantWithRateProviders(accountant).decimals();
                uint256 sharesNeeded = Math.mulDiv(needed, 10 ** decimals, rate);

                // Queue withdrawal from BoringVault (Type A)
                this.withdrawFromVault(asset, sharesNeeded, 0); // 0 = use default deadline

                // Reduce deposits optimistically (will be restored if cancelled)
                _deposits[asset] -= needed;
            }
        }

        emit Withdrawn(_assets, _amounts, _receiver, block.timestamp);
    }

    // ============================================
    // Internal Helpers
    // ============================================

    /**
     * @notice Calculate expected shares for deposit amount
     * @dev Queries Accountant for current exchange rate and converts assets to shares
     * @dev Uses getRateInQuoteSafe() for safety (reverts if Accountant paused)
     * @param _asset ERC-20 token address being deposited
     * @param _amount Asset amount to convert to shares
     * @return expectedShares Estimated shares to receive
     *
     * @custom:formula shares = amount × (10^decimals / rate)
     * @custom:example 1000 ETHFI @ rate 2.0 → 500 shares (assuming 18 decimals)
     */
    function _calculateExpectedShares(
        address _asset,
        uint256 _amount
    ) internal view returns (uint256 expectedShares) {
        // Query current exchange rate for this asset
        uint256 rate = IAccountantWithRateProviders(accountant).getRateInQuoteSafe(ERC20(_asset));
        require(rate > 0, "Invalid rate");

        // Get decimals for rate (typically 18)
        uint8 decimals = IAccountantWithRateProviders(accountant).decimals();

        // Calculate expected shares with proper decimals handling
        // shares = amount × (10^decimals / rate)
        expectedShares = Math.mulDiv(_amount, 10 ** decimals, rate);
    }

    /**
     * @notice Calculate total ETH value of current vault shares
     * @dev Queries current share balance and converts to ETH using Accountant rate
     * @dev Uses getRate() (not Safe variant) since this is view-only calculation
     * @return value Total value in ETH (18 decimals)
     *
     * @custom:formula value = shares × rate / (10^decimals)
     * @custom:example 500 shares @ rate 2.4 → 1200 ETH
     */
    function _calculateVaultShareValue() internal view returns (uint256 value) {
        // Get current share balance
        uint256 shares = IERC20(vault).balanceOf(address(this));

        if (shares == 0) return 0;

        // Query current exchange rate
        uint256 rate = IAccountantWithRateProviders(accountant).getRate();
        require(rate > 0, "Invalid rate");

        // Get decimals for rate
        uint8 decimals = IAccountantWithRateProviders(accountant).decimals();

        // Calculate value with proper decimals handling
        // value = shares × rate / (10^decimals)
        value = Math.mulDiv(shares, rate, 10 ** decimals);
    }

    /**
     * @notice Calculate expected asset amount from share amount
     * @dev Converts shares to assets using current Accountant exchange rate
     * @dev Used for withdrawal calculations
     * @param _asset ERC-20 token address we expect to receive
     * @param _shareAmount BoringVault shares to convert
     * @return expectedAmount Asset amount we expect to receive
     *
     * @custom:formula assets = shares × rate / (10^decimals)
     * @custom:example 100 shares @ rate 2.4 → 240 WETH
     */
    function _calculateExpectedAssets(
        address _asset,
        uint256 _shareAmount
    ) internal view returns (uint256 expectedAmount) {
        // Query current exchange rate for this asset
        uint256 rate = IAccountantWithRateProviders(accountant).getRateInQuoteSafe(ERC20(_asset));
        require(rate > 0, "Invalid rate");

        // Get decimals for rate
        uint8 decimals = IAccountantWithRateProviders(accountant).decimals();

        // Calculate expected assets with proper decimals handling
        // assets = shares × rate / (10^decimals)
        expectedAmount = Math.mulDiv(_shareAmount, rate, 10 ** decimals);
    }

    /**
     * @notice Calculate atomic price for AtomicQueue withdrawal request
     * @dev Applies slippage protection to expected amount and calculates price per share
     * @dev Result must fit in uint88 for AtomicRequest struct
     * @param _shareAmount BoringVault shares we're offering
     * @param _expectedAmount Asset amount we expect (before slippage)
     * @return atomicPrice Minimum price per share (in asset terms, 18 decimals)
     *
     * @custom:formula atomicPrice = minAmount × (10^decimals) / shares
     * @custom:formula minAmount = expectedAmount × (10000 - slippage) / 10000
     * @custom:example 100 shares for 240 WETH, 50 BPS slippage → price = 239.88 / 100 = 2.3988
     */
    function _calculateAtomicPrice(
        address, /* _asset - unused but kept for interface consistency */
        uint256 _shareAmount,
        uint256 _expectedAmount
    ) internal view returns (uint256 atomicPrice) {
        // Apply slippage protection to expected amount
        uint256 minAmount = Math.mulDiv(_expectedAmount, 10_000 - maxSlippageBPS, 10_000);

        // Get decimals for price calculation
        uint8 decimals = IAccountantWithRateProviders(accountant).decimals();

        // Calculate atomic price: minAmount per share
        // atomicPrice = minAmount × (10^decimals) / shares
        atomicPrice = Math.mulDiv(minAmount, 10 ** decimals, _shareAmount);

        // Ensure result fits in uint88 (AtomicRequest struct limitation)
        require(atomicPrice <= type(uint88).max, "Atomic price overflow");
    }

    // ============================================
    // Profit Calculation
    // ============================================

    /**
     * @notice Calculate current profit (share value - principal deposits)
     * @dev Profit = Current BoringVault share value - Total principal deposits (in ETH)
     * @dev Returns 0 if at a loss (no negative profit)
     * @dev Used by harvestProfits() to determine withdrawal amount
     *
     * @return profit Current profit in ETH terms (18 decimals)
     *
     * @custom:formula profit = max(0, shareValue - principalSum)
     * @custom:example
     * Scenario: 1000 ETHFI deposited → 500 shares @ 2.0 rate
     *   Later: shares worth 1200 ETHFI @ 2.4 rate
     *   Principal: 1000 ETHFI (in ETH via price provider)
     *   Share Value: 1200 ETH (_calculateVaultShareValue)
     *   Profit: 1200 - 1000 = 200 ETH
     *
     * Algorithm:
     * 1. Calculate current share value in ETH
     * 2. Sum all principal deposits across registered assets
     * 3. Convert each asset principal to ETH using price provider
     * 4. Return max(0, shareValue - principalSum)
     */
    function calculateProfit() public view returns (uint256 profit) {
        // Get current BoringVault share value in ETH
        uint256 currentValue = _calculateVaultShareValue();

        // Calculate total principal across all registered assets
        uint256 totalPrincipal = 0;
        IPriceProvider provider = IPriceProvider(priceProvider);

        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];

            // Skip unregistered assets
            if (!_registeredTokens[asset]) continue;

            // Get principal deposits (from parent KingVault)
            uint256 deposited = _deposits[asset];

            if (deposited == 0) continue;

            // Get asset price in ETH
            uint256 priceInEth = provider.getPriceInEth(asset);
            require(priceInEth > 0, "Invalid price");

            // Get asset decimals
            uint8 decimals = IERC20Metadata(asset).decimals();

            // Convert deposited amount to ETH
            // principalInEth = deposited × priceInEth / (10^decimals)
            uint256 principalInEth = Math.mulDiv(deposited, priceInEth, 10 ** decimals);

            totalPrincipal += principalInEth;
        }

        // Calculate profit (or 0 if at a loss)
        if (currentValue > totalPrincipal) {
            profit = currentValue - totalPrincipal;
        } else {
            profit = 0; // No profit or at a loss
        }

        return profit;
    }

    /**
     * @notice Harvest profits by queuing withdrawal of profit shares (Type B)
     * @dev Owner-only function to initiate profit distribution cycle
     * @dev Queues withdrawal for profit shares only (NOT principal)
     * @dev DUAL TRACKING: Increments _queuedProfits[baseAsset] to protect from principal contamination
     * @dev Does NOT modify _deposits (profit ≠ principal)
     *
     * @custom:validation Profit must be > 0
     * @custom:validation Share value must be > 0
     * @custom:validation Profit shares must be > 0
     * @custom:validation No concurrent withdrawals for base asset
     *
     * Workflow:
     * 1. Calculate current profit (shareValue - principal)
     * 2. Calculate profit shares from current share balance
     * 3. Get base asset from Accountant
     * 4. Queue withdrawal for profit shares via internal helper
     * 5. Increment _queuedProfits[baseAsset] (Type B tracking)
     * 6. Emit events
     *
     * After solver fulfills:
     * - Call distributeProfits() to send assets to recipients
     * - distributeProfits() clears _queuedProfits tracking
     *
     * Example:
     * ```solidity
     * // Vault has 500 shares worth 1200 ETH, principal = 1000 ETH
     * // Profit = 200 ETH = 16.67% of shareValue
     * // Profit shares = 500 × 0.1667 = 83.33 shares
     * boringVault.harvestProfits();
     * // Queues 83.33 share withdrawal for ~200 WETH
     * // _queuedProfits[WETH] = 200e18
     * // _deposits[WETH] UNCHANGED (profit ≠ principal)
     * ```
     */
    function harvestProfits() external override onlyOwner whenNotPaused {
        // 1. Calculate current profit
        uint256 profitInEth = calculateProfit();
        require(profitInEth > 0, "No profit to harvest");

        // 2. Get current share value
        uint256 shareValue = _calculateVaultShareValue();
        require(shareValue > 0, "No share value");

        // 3. Get current share balance
        uint256 currentShares = IERC20(vault).balanceOf(address(this));
        require(currentShares > 0, "No shares");

        // 4. Calculate profit shares
        // profitShares = currentShares × profitInEth / shareValue
        uint256 profitShares = Math.mulDiv(currentShares, profitInEth, shareValue);

        // 5. Validate profit shares
        require(profitShares > 0, "No profit shares");
        require(profitShares <= currentShares, "Invalid profit calculation");

        // 6. Get base asset from Accountant
        address baseAsset = IAccountantWithRateProviders(accountant).base();
        require(baseAsset != address(0), "Invalid base asset");

        // 7. Check no pending withdrawal for base asset
        if (_withdrawalRequests[baseAsset].deadline > 0) {
            revert WithdrawalNotQueued();
        }

        // 8. Calculate expected asset amount from profit shares
        uint256 expectedAmount = _calculateExpectedAssets(baseAsset, profitShares);

        // 9. DUAL TRACKING: Increment queued profits (Type B tracking)
        _queuedProfits[baseAsset] += expectedAmount;

        // 10. Queue withdrawal for profit shares (Type B)
        // Uses internal helper to avoid modifying _queuedWithdraw
        _queueProfitWithdrawal(baseAsset, profitShares, 0); // 0 = use default deadline

        // 11. Emit events
        emit ProfitsHarvested(block.timestamp); // Inherited from IKingVault
        emit ProfitSharesQueued(profitShares, profitInEth);
    }

    /**
     * @notice Internal helper to queue profit withdrawal (Type B)
     * @dev Similar to withdrawFromVault() but for Type B (profit) withdrawals
     * @dev Does NOT modify _deposits (profit ≠ principal)
     * @dev Does NOT modify _queuedWithdraw (only Type A uses this)
     * @dev Called by harvestProfits() after setting _queuedProfits
     *
     * @param _asset ERC-20 token address we want to receive
     * @param _shareAmount BoringVault shares to withdraw
     * @param _deadline Unix timestamp for request expiration (0 = use default)
     *
     * @custom:security No access control needed (internal function)
     * @custom:security Assumes validation done by caller (harvestProfits)
     */
    function _queueProfitWithdrawal(
        address _asset,
        uint256 _shareAmount,
        uint64 _deadline
    ) internal {
        // Calculate deadline (use default if not provided)
        uint64 deadline = _deadline == 0 ? uint64(block.timestamp) + withdrawalDuration : _deadline;

        // Calculate expected asset amount from shares
        uint256 expectedAmount = _calculateExpectedAssets(_asset, _shareAmount);

        // Calculate atomic price with slippage protection
        uint256 atomicPrice = _calculateAtomicPrice(_asset, _shareAmount, expectedAmount);

        // Create AtomicRequest struct
        IAtomicQueue.AtomicRequest memory request = IAtomicQueue.AtomicRequest({
            deadline: deadline,
            atomicPrice: uint88(atomicPrice),
            offerAmount: uint96(_shareAmount),
            inSolve: false
        });

        // Approve AtomicQueue to spend shares
        IERC20(vault).approve(atomicQueue, _shareAmount);

        // Queue withdrawal in AtomicQueue
        IAtomicQueue(atomicQueue).updateAtomicRequest(
            ERC20(vault), // offer: BoringVault shares
            ERC20(_asset), // want: Asset we expect to receive
            request
        );

        // Store withdrawal request details
        _withdrawalRequests[_asset] = WithdrawalRequest({
            asset: _asset,
            offer: expectedAmount, // IN-TRANSIT ASSET TRACKING
            want: _shareAmount,
            deadline: deadline
        });

        // Update pending shares
        _pendingShares += _shareAmount;

        // NOTE: Does NOT modify _queuedWithdraw (only Type A uses this)
        // NOTE: Does NOT modify _deposits (profit ≠ principal)
        // NOTE: _queuedProfits already incremented by harvestProfits()

        emit WithdrawalQueued(_asset, _shareAmount, expectedAmount, deadline);
    }

    /**
     * @notice Distribute idle profits to recipients and clear queued profit tracking
     * @dev Overrides parent KingVault.distributeProfits() to add _queuedProfits cleanup
     * @dev Only callable by owner (governance multi-sig)
     * @dev DUAL TRACKING: Clears _queuedProfits[asset] for all assets after distribution
     *
     * @custom:validation Executes parent distribution logic
     * @custom:validation Clears Type B tracking after successful distribution
     *
     * Workflow:
     * 1. Execute distribution logic (inherited from parent):
     *    a. Calculate idle profit (balance - deposits)
     *    b. Distribute to configured recipients
     *    c. Emit ProfitsDistributed event
     * 2. Clear _queuedProfits for all assets (Type B cleanup)
     *
     * Example:
     * ```solidity
     * // After solver fulfills profit harvest:
     * // - 200 WETH arrived as idle balance
     * // - _queuedProfits[WETH] = 200e18 (still tracked)
     *
     * boringVault.distributeProfits();
     * // - Parent sends 200 WETH to recipients
     * // - _queuedProfits[WETH] = 0 (cleared)
     * // - Ready for next harvest cycle
     * ```
     */
    function distributeProfits() external override onlyOwner whenNotPaused {
        // Access control already verified by modifiers above

        // Validate we have at least one recipient configured
        if (_profitsRecipients.length == 0) {
            revert InvalidAssetArray(); // No recipients configured
        }

        // Prepare event data structures
        address[] memory distributedTokens = new address[](_assets.length);
        uint256[] memory tokenTotalAmounts = new uint256[](_assets.length);
        uint256 tokenCount = 0;

        // 2D array for amounts per recipient per token
        uint256[][] memory recipientAmounts = new uint256[][](_profitsRecipients.length);
        for (uint256 i = 0; i < _profitsRecipients.length; i++) {
            recipientAmounts[i] = new uint256[](_assets.length);
        }

        // Iterate through all assets
        for (uint256 i = 0; i < _assets.length; i++) {
            address token = _assets[i];

            // Skip if token is not registered/accepted
            if (!_registeredTokens[token]) {
                continue;
            }

            // Get current balance and deposited principal
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 principal = _deposits[token];

            // Calculate profit (only distribute if balance > principal)
            if (balance <= principal) {
                continue; // No profit to distribute
            }

            uint256 profit = balance - principal;

            // Track token for event
            distributedTokens[tokenCount] = token;
            tokenTotalAmounts[tokenCount] = profit;

            // Distribute profit to each recipient
            for (uint256 j = 0; j < _profitsRecipients.length; j++) {
                address recipient = _profitsRecipients[j];
                uint16 percentBPS = _profitsDistribution[recipient];

                // Calculate recipient's share using mulDiv for precision
                // share = (profit * percentBPS) / HUNDRED_PERCENT_IN_BPS
                uint256 share = Math.mulDiv(profit, uint256(percentBPS), HUNDRED_PERCENT_IN_BPS);

                // Transfer share to recipient (skip if share is 0)
                if (share > 0) {
                    SafeERC20.safeTransfer(IERC20(token), recipient, share);
                    recipientAmounts[j][tokenCount] = share;
                }
            }

            tokenCount++;
        }

        // Resize arrays to actual count (remove empty slots)
        address[] memory finalTokens = new address[](tokenCount);
        uint256[] memory finalTotalAmounts = new uint256[](tokenCount);
        uint256[][] memory finalRecipientAmounts = new uint256[][](_profitsRecipients.length);

        for (uint256 i = 0; i < tokenCount; i++) {
            finalTokens[i] = distributedTokens[i];
            finalTotalAmounts[i] = tokenTotalAmounts[i];
        }

        for (uint256 i = 0; i < _profitsRecipients.length; i++) {
            finalRecipientAmounts[i] = new uint256[](tokenCount);
            for (uint256 j = 0; j < tokenCount; j++) {
                finalRecipientAmounts[i][j] = recipientAmounts[i][j];
            }
        }

        // Emit event with distribution details
        emit ProfitsDistributed(_profitsRecipients, finalTokens, finalRecipientAmounts, block.timestamp);

        // DUAL TRACKING: Clear queued profits for all assets (Type B cleanup)
        // After distribution completes, profit assets are no longer reserved
        for (uint256 i = 0; i < _assets.length; i++) {
            address asset = _assets[i];
            if (_queuedProfits[asset] > 0) {
                _queuedProfits[asset] = 0;
            }
        }
    }

    /**
     * @notice Cancel pending profit harvest request (Type B)
     * @dev Owner-only function to cancel unfulfilled profit withdrawal
     * @dev DUAL TRACKING: Decrements _queuedProfits[_asset] to clear Type B tracking
     * @dev Does NOT modify _deposits (profit was never counted as principal)
     *
     * @param _asset ERC-20 token address of profit harvest to cancel
     *
     * @custom:validation Queued profits must exist for asset
     * @custom:validation Withdrawal request must exist
     *
     * Workflow:
     * 1. Validate _queuedProfits[_asset] > 0
     * 2. Get queued amount
     * 3. Cancel AtomicQueue request (set to empty)
     * 4. Decrement _queuedProfits[_asset] (clear Type B tracking)
     * 5. Delete _withdrawalRequests[_asset]
     * 6. Reset _pendingShares
     * 7. Emit event
     *
     * CRITICAL: Does NOT restore _deposits (profit was never principal)
     *
     * Example:
     * ```solidity
     * // Profit harvest queued: 83 shares for 200 WETH
     * // _queuedProfits[WETH] = 200e18
     * // _deposits[WETH] = 1000e18 (unchanged)
     *
     * // Solver never fulfills, governance cancels:
     * boringVault.cancelProfitsHarvest(WETH);
     *
     * // - _queuedProfits[WETH] = 0 (cleared)
     * // - _deposits[WETH] = 1000e18 (still unchanged)
     * // - 83 shares restored to available pool
     * ```
     */
    function cancelProfitsHarvest(address _asset) external onlyOwner whenNotPaused {
        // 1. Validate queued profits exist
        uint256 queuedAmount = _queuedProfits[_asset];
        if (queuedAmount == 0) {
            revert NoProfitsQueued();
        }

        // 2. Validate withdrawal request exists
        WithdrawalRequest memory request = _withdrawalRequests[_asset];
        if (request.deadline == 0) {
            revert NoWithdrawalQueued();
        }

        // 3. Create empty AtomicRequest to cancel
        IAtomicQueue.AtomicRequest memory emptyRequest =
            IAtomicQueue.AtomicRequest({deadline: 0, atomicPrice: 0, offerAmount: 0, inSolve: false});

        // 4. Cancel withdrawal in AtomicQueue
        IAtomicQueue(atomicQueue).updateAtomicRequest(
            ERC20(vault), // offer: BoringVault shares
            ERC20(_asset), // want: Asset
            emptyRequest
        );

        // 5. DUAL TRACKING: Decrement queued profits (clear Type B tracking)
        _queuedProfits[_asset] -= queuedAmount;

        // 6. Delete withdrawal request
        delete _withdrawalRequests[_asset];

        // 7. Reset pending shares
        _pendingShares = 0;

        // CRITICAL: Does NOT modify _deposits (profit was never principal)
        // Shares automatically restored (no internal tracking, use balanceOf())

        // 8. Emit event
        emit ProfitsHarvestCancelled(_asset, queuedAmount, block.timestamp);
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
