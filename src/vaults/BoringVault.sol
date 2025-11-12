// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVault} from "../base/KingVault.sol";
import {IKingVault} from "../interfaces/IKingVault.sol";
import {ITellerWithMultiAssetSupport} from "../interfaces/external/ITellerWithMultiAssetSupport.sol";
import {IAccountantWithRateProviders} from "../interfaces/external/IAccountantWithRateProviders.sol";
import {IAtomicQueue} from "../interfaces/external/IAtomicQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    // UUPS Upgrade
    // ============================================

    /**
     * @notice Authorization for contract upgrades is inherited from KingVaultStorage
     * @dev KingVaultStorage._authorizeUpgrade() requires owner via _checkOwner()
     * @dev No need to override - parent implementation is sufficient
     */
}
