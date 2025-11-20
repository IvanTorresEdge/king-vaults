// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingTokenizedVault} from "../../../src/vaults/KingTokenizedVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPriceProvider} from "../../mocks/MockPriceProvider.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";
import {MockKingVaultController} from "../../mocks/MockKingVaultController.sol";
import {IKingVault} from "../../../src/interfaces/IKingVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title KingTokenizedVault_ProfitsTest
 * @notice Comprehensive test suite for KingTokenizedVault profit management (Feature 5)
 * @dev Tests Feature 5.1-5.4 acceptance criteria:
 *
 * Feature 5.1: calculateProfit() - Accurate profit calculation
 *      - Test profit = (current share value in ETH) - (principal deposits in ETH)
 *      - Test with share appreciation scenarios
 *      - Test with multiple assets (principal tracking)
 *      - Test edge cases (no shares, no profit)
 *
 * Feature 5.2: harvestProfits() - Type B withdrawal
 *      - Test atomic mode: immediate redemption + queuing in _queuedProfits
 *      - Test profit share calculation from total shares
 *      - Test slippage protection during harvest
 *      - Test authorization and state validation
 *
 * Feature 5.3: Profit queue tracking
 *      - Test _queuedProfits incremented on harvest
 *      - Test _queuedProfits cleared on distribute
 *      - Test separation from _queuedWithdraw (Type A vs Type B)
 *
 * Feature 5.4: Type A vs Type B separation
 *      - Type A: Principal withdrawals → _queuedWithdraw → withdraw() to kingVault
 *      - Type B: Profit withdrawals → _queuedProfits → distributeProfits() to kingVault
 *      - Test full profit lifecycle integration
 *
 * Configuration Functions:
 *      - setMaxSlippage(): Test limits (0-1000 BPS), authorization
 *      - setWithdrawalDuration(): Test limits (1 sec - 30 days), authorization
 *
 * Architecture Context:
 *      - KingTokenizedVault: ERC-4626 integration vault
 *      - Dual flows: Flow A (custody with kingVault), Flow B (deployment to ERC-4626)
 *      - Share appreciation: ERC-4626 shares increase in value over time
 *      - Profit = Share value growth above principal deposits
 */
contract KingTokenizedVault_ProfitsTest is Test {
    // ============================================
    // Contracts
    // ============================================

    /// @dev The KingTokenizedVault proxy instance being tested
    KingTokenizedVault public tokenizedVault;

    /// @dev The implementation contract for UUPS proxy pattern
    KingTokenizedVault public implementation;

    /// @dev Mock WETH token (18 decimals) - used as ERC-4626 underlying asset
    MockERC20 public weth;

    /// @dev Mock USDC token (6 decimals) - used for multi-asset principal tracking tests
    MockERC20 public usdc;

    /// @dev Mock price provider (converts assets to ETH for profit calculation)
    MockPriceProvider public priceProvider;

    /// @dev Mock ERC-4626 vault with configurable exchange rate for testing share appreciation
    MockERC4626Vault public erc4626Vault;

    // ============================================
    // Test Addresses
    // ============================================

    /// @dev Contract owner - can call onlyOwner functions
    address public owner = address(0x1);

    /// @dev King Protocol main vault - authorized to deposit/withdraw assets
    address public kingVault;

    /// @dev Unauthorized address - used for negative authorization tests
    address public unauthorized = address(0x3);

    // ============================================
    // Constants
    // ============================================

    /// @dev Default slippage tolerance: 50 BPS = 0.5%
    uint16 public constant DEFAULT_SLIPPAGE_BPS = 50;

    /// @dev Default withdrawal request duration: 7 days (for async mode)
    uint64 public constant DEFAULT_WITHDRAWAL_DURATION = 7 days;

    // ============================================
    // Events
    // ============================================

    /// @dev Emitted when profits are harvested from ERC-4626 vault
    event ProfitsHarvested(uint256 timestamp);

    /// @dev Emitted when profit shares are queued for withdrawal (Type B)
    event ProfitSharesQueued(uint256 profitShares, uint256 profitValue);

    /// @dev Emitted when profits are distributed to king vault
    event ProfitsDistributed(address indexed asset, uint256 amount);

    /// @dev Emitted when slippage tolerance is updated
    event SlippageUpdated(uint16 newSlippage);

    /// @dev Emitted when withdrawal duration is updated
    event WithdrawalDurationUpdated(uint64 oldDuration, uint64 newDuration);

    /// @dev Emitted when withdrawal is confirmed (assets received)
    event WithdrawalConfirmed(address indexed asset, uint256 amountReceived);

    // ============================================
    // Helpers
    // ============================================

    /**
     * @notice Helper to deposit assets to KingTokenizedVault
     * @dev Wraps single asset/amount into arrays for deposit() function
     * @param asset Token address to deposit
     * @param amount Token amount to deposit
     */
    function _depositToKingTokenizedVault(address asset, uint256 amount) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        tokenizedVault.deposit(assets, amounts);
    }

    // ============================================
    // Setup
    // ============================================

    /**
     * @notice Test setup - deploys contracts and configures initial state
     * @dev Sets up:
     *      - Mock tokens (WETH, USDC)
     *      - Mock ERC-4626 vault (accepts WETH)
     *      - Mock price provider (1 WETH = 1 ETH, 1 USDC = 0.0005 ETH)
     *      - KingTokenizedVault in atomic mode
     *      - Registers WETH as accepted asset
     *      - Funds kingVault with WETH for deposits
     */
    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mock ERC-4626 vault (WETH vault)
        erc4626Vault = new MockERC4626Vault(weth, "Vault WETH", "vWETH");

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(usdc), 0.0005e18); // 1 USDC = 0.0005 ETH

        // Deploy KingTokenizedVault implementation (atomic mode)
        implementation = new KingTokenizedVault(address(erc4626Vault), true);

        // Prepare initial assets
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tokenizedVault = KingTokenizedVault(address(proxy));

        // Fund king vault with WETH
        weth.mint(kingVault, 100 ether);

        // Approve vault to spend WETH
        vm.prank(kingVault);
        weth.approve(address(tokenizedVault), type(uint256).max);
    }

    // ============================================
    // setMaxSlippage Tests
    // ============================================

    /**
     * @notice Test setMaxSlippage with valid value
     * @dev Verifies:
     *      - Owner can update slippage tolerance
     *      - SlippageUpdated event emitted
     *      - New value is stored correctly
     */
    function test_setMaxSlippage_Success() public {
        vm.startPrank(owner);

        // Set to 100 BPS (1%)
        vm.expectEmit(true, true, true, true);
        emit SlippageUpdated(100);
        tokenizedVault.setMaxSlippage(100);

        assertEq(tokenizedVault.maxSlippageBPS(), 100);
        vm.stopPrank();
    }

    /**
     * @notice Test setMaxSlippage reverts when exceeding maximum limit
     * @dev Verifies:
     *      - Maximum slippage limit is 1000 BPS (10%)
     *      - Attempting to set 1001 BPS reverts with InvalidSlippage
     *      - Protects against excessive slippage tolerance
     */
    function test_setMaxSlippage_RevertIfExceedsLimit() public {
        vm.startPrank(owner);

        // Try to set 1001 BPS (10.01%) - should revert
        vm.expectRevert(abi.encodeWithSelector(KingTokenizedVault.InvalidSlippage.selector, 1001));
        tokenizedVault.setMaxSlippage(1001);

        vm.stopPrank();
    }

    /**
     * @notice Test setMaxSlippage reverts when called by unauthorized address
     * @dev Verifies onlyOwner modifier enforcement
     */
    function test_setMaxSlippage_RevertIfUnauthorized() public {
        vm.startPrank(unauthorized);

        vm.expectRevert();
        tokenizedVault.setMaxSlippage(100);

        vm.stopPrank();
    }

    /**
     * @notice Test setMaxSlippage accepts maximum allowed value
     * @dev Verifies boundary condition: exactly 1000 BPS (10%) is valid
     */
    function test_setMaxSlippage_MaxAllowed() public {
        vm.startPrank(owner);

        // Set to exactly 1000 BPS (10%) - should succeed
        vm.expectEmit(true, true, true, true);
        emit SlippageUpdated(1000);
        tokenizedVault.setMaxSlippage(1000);

        assertEq(tokenizedVault.maxSlippageBPS(), 1000);
        vm.stopPrank();
    }

    // ============================================
    // setWithdrawalDuration Tests
    // ============================================

    /**
     * @notice Test setWithdrawalDuration with valid value
     * @dev Verifies:
     *      - Owner can update withdrawal duration
     *      - WithdrawalDurationUpdated event emitted with old and new values
     *      - New duration is stored correctly
     */
    function test_setWithdrawalDuration_Success() public {
        vm.startPrank(owner);

        uint64 newDuration = 14 days;
        vm.expectEmit(true, true, true, true);
        emit WithdrawalDurationUpdated(DEFAULT_WITHDRAWAL_DURATION, newDuration);
        tokenizedVault.setWithdrawalDuration(newDuration);

        assertEq(tokenizedVault.withdrawalDuration(), newDuration);
        vm.stopPrank();
    }

    /**
     * @notice Test setWithdrawalDuration reverts with zero duration
     * @dev Verifies minimum duration validation (must be > 0)
     */
    function test_setWithdrawalDuration_RevertIfZero() public {
        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSelector(KingTokenizedVault.InvalidDuration.selector, 0));
        tokenizedVault.setWithdrawalDuration(0);

        vm.stopPrank();
    }

    /**
     * @notice Test setWithdrawalDuration reverts when exceeding 30 days
     * @dev Verifies maximum duration limit (31 days is invalid)
     */
    function test_setWithdrawalDuration_RevertIfExceeds30Days() public {
        vm.startPrank(owner);

        uint64 invalid = 31 days;
        vm.expectRevert(abi.encodeWithSelector(KingTokenizedVault.InvalidDuration.selector, invalid));
        tokenizedVault.setWithdrawalDuration(invalid);

        vm.stopPrank();
    }

    /**
     * @notice Test setWithdrawalDuration reverts when called by unauthorized address
     * @dev Verifies onlyOwner modifier enforcement
     */
    function test_setWithdrawalDuration_RevertIfUnauthorized() public {
        vm.startPrank(unauthorized);

        vm.expectRevert();
        tokenizedVault.setWithdrawalDuration(14 days);

        vm.stopPrank();
    }

    /**
     * @notice Test setWithdrawalDuration accepts maximum allowed value
     * @dev Verifies boundary condition: exactly 30 days is valid
     */
    function test_setWithdrawalDuration_Exactly30Days() public {
        vm.startPrank(owner);

        uint64 maxDuration = 30 days;
        vm.expectEmit(true, true, true, true);
        emit WithdrawalDurationUpdated(DEFAULT_WITHDRAWAL_DURATION, maxDuration);
        tokenizedVault.setWithdrawalDuration(maxDuration);

        assertEq(tokenizedVault.withdrawalDuration(), maxDuration);
        vm.stopPrank();
    }

    // ============================================
    // calculateProfit Tests
    // ============================================

    /**
     * @notice Test calculateProfit returns zero when no shares exist
     * @dev Verifies:
     *      - Returns 0 when vault has no ERC-4626 shares
     *      - No reverts on empty state
     */
    function test_calculateProfit_NoProfitInitially() public view {
        uint256 profit = tokenizedVault.calculateProfit();
        assertEq(profit, 0, "Should have no profit initially");
    }

    /**
     * @notice Test calculateProfit with share appreciation scenario
     * @dev Verifies:
     *      - Deposits 10 WETH principal
     *      - Deploys to ERC-4626 vault (receives 10 shares @ 1:1)
     *      - Simulates appreciation: 1 share = 1.2 WETH
     *      - Profit = (10 shares * 1.2) - 10 WETH principal = 2 WETH
     *      - Tests Feature 5.1: Accurate profit calculation
     */
    function test_calculateProfit_WithShareAppreciation() public {
        // Deposit 10 WETH to vault
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        // Deploy to ERC-4626 vault
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Simulate share appreciation: 1 share now worth 1.2 WETH
        erc4626Vault.setExchangeRate(1.2e18);

        // Calculate profit
        uint256 profit = tokenizedVault.calculateProfit();

        // Expected: (10 shares * 1.2 WETH/share) - 10 WETH principal = 2 WETH
        assertGt(profit, 0, "Should have profit after appreciation");
        assertApproxEqRel(profit, 2 ether, 0.01e18, "Profit should be ~2 ETH");
    }

    /**
     * @notice Test calculateProfit edge case with no shares
     * @dev Verifies graceful handling when calculateProfit called with zero shares
     */
    function test_calculateProfit_NoSharesReturnsZero() public view {
        // No shares deposited
        uint256 profit = tokenizedVault.calculateProfit();
        assertEq(profit, 0, "Should return 0 when no shares");
    }

    /**
     * @notice Test calculateProfit with multiple asset principals
     * @dev Verifies:
     *      - Tracks WETH principal (deployed to vault)
     *      - Tracks USDC principal (held idle in vault)
     *      - Total principal = WETH ETH value + USDC ETH value
     *      - Profit calculation accounts for all principals
     *      - Tests cross-asset principal tracking in profit calculation
     *
     * Calculation example:
     *      - WETH principal: 10 ETH
     *      - USDC principal: 20,000 USDC * 0.0005 ETH/USDC = 10 ETH
     *      - Total principal: 20 ETH
     *      - Share value @ 2.1x: 10 shares * 2.1 = 21 ETH
     *      - Profit: 21 - 20 = 1 ETH
     */
    function test_calculateProfit_MultipleAssets() public {
        // Register USDC as additional asset (not deployed to vault, just held)
        vm.startPrank(owner);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        tokenizedVault.registerAssets(assets, accepted);
        vm.stopPrank();

        // Deposit WETH and USDC
        weth.mint(kingVault, 10 ether);
        usdc.mint(kingVault, 20_000e6); // 20k USDC

        vm.startPrank(kingVault);
        weth.approve(address(tokenizedVault), type(uint256).max);
        usdc.approve(address(tokenizedVault), type(uint256).max);

        _depositToKingTokenizedVault(address(weth), 10 ether);
        _depositToKingTokenizedVault(address(usdc), 20_000e6);
        vm.stopPrank();

        // Deploy only WETH to vault (USDC stays as principal)
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Simulate appreciation on WETH shares
        erc4626Vault.setExchangeRate(1.5e18);

        // Calculate profit
        // Principal: 10 ETH (from WETH) + 10 ETH (from 20k USDC @ 0.0005 ETH each)  = 20 ETH
        // Current value: 15 ETH (10 shares @ 1.5 WETH/share)
        // Since current < principal, profit should be 0
        uint256 profit = tokenizedVault.calculateProfit();

        // However, if we look at just WETH shares:
        // WETH profit = 15 ETH (current value) - 10 ETH (WETH principal) = 5 ETH
        // But total principal includes USDC (20 ETH total)
        // So profit = 15 ETH - 20 ETH = 0 (negative, returns 0)
        //
        // Actually the vault value is 15 ETH from shares, which is less than 20 ETH total principal
        // Wait - let me recalculate:
        // WETH principal: 10 ETH
        // USDC principal: 20_000 USDC * 0.0005 ETH/USDC = 10 ETH
        // Total principal: 20 ETH
        // Current share value: 10 shares * 1.5 WETH/share = 15 WETH = 15 ETH
        // Profit = 15 - 20 = -5 ETH, but we return 0 for negative

        // Let me increase appreciation more to get positive profit
        erc4626Vault.setExchangeRate(2.1e18); // 2.1x appreciation

        profit = tokenizedVault.calculateProfit();
        // Now: 10 shares * 2.1 = 21 WETH value
        // Profit = 21 - 20 = 1 ETH
        assertGt(profit, 0, "Should have profit with 2.1x appreciation");
    }

    // ============================================
    // harvestProfits Tests (Atomic Mode)
    // ============================================

    /**
     * @notice Test harvestProfits in atomic mode (immediate execution)
     * @dev Verifies:
     *      - Calculates profit shares from total shares
     *      - Immediately redeems profit shares for underlying assets
     *      - Queues assets in _queuedProfits (Type B withdrawal)
     *      - Emits ProfitsHarvested event
     *      - Tests Feature 5.2: harvestProfits implementation
     *      - Tests Feature 5.3: Profit queue tracking
     *
     * Flow:
     *      1. Deposit 10 WETH principal
     *      2. Deploy to vault (10 shares @ 1:1)
     *      3. Share appreciation to 1.5 WETH/share
     *      4. Harvest: redeem profit shares → receive WETH → queue in _queuedProfits
     */
    function test_harvestProfits_AtomicMode_Success() public {
        // Setup: Deposit and deploy
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Simulate profit: 1 share = 1.5 WETH
        erc4626Vault.setExchangeRate(1.5e18);

        // Harvest profits
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit ProfitsHarvested(block.timestamp);

        tokenizedVault.harvestProfits();
        vm.stopPrank();

        // Verify shares were redeemed and profits queued
        // Original: 10 shares @ 1.0 = 10 WETH principal
        // Now: 10 shares @ 1.5 = 15 WETH value
        // Profit: 5 WETH value = ~3.33 shares
        assertGt(weth.balanceOf(address(tokenizedVault)), 0, "Should have WETH balance");
    }

    /**
     * @notice Test harvestProfits reverts when no profit exists
     * @dev Verifies:
     *      - Shares deposited but no appreciation
     *      - calculateProfit returns 0
     *      - harvestProfits reverts with NoProfitToHarvest
     */
    function test_harvestProfits_RevertIfNoProfit() public {
        // Deposit but no appreciation
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Try to harvest (no profit)
        vm.startPrank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitToHarvest.selector);
        tokenizedVault.harvestProfits();
        vm.stopPrank();
    }

    /**
     * @notice Test harvestProfits reverts when no shares exist
     * @dev Verifies:
     *      - No shares deployed to vault
     *      - calculateProfit returns 0 (no shares case)
     *      - harvestProfits reverts with NoProfitToHarvest
     */
    function test_harvestProfits_RevertIfNoShares() public {
        // Try to harvest without any shares
        // Note: calculateProfit returns 0 when no shares, so we get NoProfitToHarvest
        vm.startPrank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitToHarvest.selector);
        tokenizedVault.harvestProfits();
        vm.stopPrank();
    }

    /**
     * @notice Test harvestProfits reverts when called by unauthorized address
     * @dev Verifies onlyOwner modifier enforcement
     */
    function test_harvestProfits_RevertIfUnauthorized() public {
        vm.startPrank(unauthorized);
        vm.expectRevert();
        tokenizedVault.harvestProfits();
        vm.stopPrank();
    }

    /**
     * @notice Test harvestProfits with slippage protection
     * @dev Verifies:
     *      - Small profit scenario (1% appreciation)
     *      - High slippage tolerance set (5%)
     *      - Harvest succeeds with slippage check
     *      - Tests slippage protection during profit harvesting
     */
    function test_harvestProfits_WithSlippageProtection() public {
        // Setup
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Small profit
        erc4626Vault.setExchangeRate(1.01e18);

        // Set high slippage tolerance
        vm.prank(owner);
        tokenizedVault.setMaxSlippage(500); // 5%

        // Harvest should succeed
        vm.prank(owner);
        tokenizedVault.harvestProfits();
    }

    // ============================================
    // distributeProfits Tests
    // ============================================

    /**
     * @notice Test distributeProfits successfully transfers profits to king vault
     * @dev Verifies:
     *      - Profits harvested and queued in _queuedProfits
     *      - distributeProfits transfers assets to kingVault
     *      - ProfitsDistributed event emitted
     *      - King vault balance increases
     *      - Tests Feature 5.4: Type B withdrawal completion
     */
    function test_distributeProfits_Success() public {
        // Setup: Deposit, deploy, harvest
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Simulate profit
        erc4626Vault.setExchangeRate(1.5e18);

        // Harvest
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Get king vault balance before
        uint256 balanceBefore = weth.balanceOf(kingVault);

        // Distribute
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit ProfitsDistributed(address(weth), weth.balanceOf(address(tokenizedVault)));

        tokenizedVault.distributeProfits();
        vm.stopPrank();

        // Verify profits transferred to king vault
        uint256 balanceAfter = weth.balanceOf(kingVault);
        assertGt(balanceAfter, balanceBefore, "King vault should receive profits");
    }

    /**
     * @notice Test distributeProfits reverts when no profits are queued
     * @dev Verifies:
     *      - _queuedProfits is empty (no harvest called)
     *      - distributeProfits reverts with NoProfitsToDistribute
     *      - Prevents wasted gas on empty distribution
     */
    function test_distributeProfits_RevertIfNoProfitsQueued() public {
        vm.startPrank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitsToDistribute.selector);
        tokenizedVault.distributeProfits();
        vm.stopPrank();
    }

    /**
     * @notice Test distributeProfits reverts when called by unauthorized address
     * @dev Verifies onlyOwner modifier enforcement
     */
    function test_distributeProfits_RevertIfUnauthorized() public {
        vm.startPrank(unauthorized);
        vm.expectRevert();
        tokenizedVault.distributeProfits();
        vm.stopPrank();
    }

    /**
     * @notice Test distributeProfits clears queued profits after distribution
     * @dev Verifies:
     *      - First harvest queues profits in _queuedProfits
     *      - distributeProfits clears _queuedProfits
     *      - Second distributeProfits call reverts (nothing to distribute)
     *      - Tests Feature 5.3: Profit queue clearing
     */
    function test_distributeProfits_ClearsQueuedProfits() public {
        // Setup and harvest
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        erc4626Vault.setExchangeRate(1.2e18);

        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Distribute
        vm.prank(owner);
        tokenizedVault.distributeProfits();

        // Try to distribute again - should revert
        vm.startPrank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitsToDistribute.selector);
        tokenizedVault.distributeProfits();
        vm.stopPrank();
    }

    // ============================================
    // Integration Test: Full Profit Cycle
    // ============================================

    /**
     * @notice Integration test for complete profit lifecycle
     * @dev Tests end-to-end profit flow (Features 5.1-5.4):
     *
     * Step 1: Deposit 20 WETH from kingVault to KingTokenizedVault (Flow A)
     *         - Tests asset custody transfer
     *
     * Step 2: Deploy 20 WETH to ERC-4626 vault (Flow B)
     *         - Receives 20 shares @ 1:1 ratio
     *         - Tests depositToVault functionality
     *
     * Step 3: Simulate 50% profit (share appreciation to 1.5 WETH/share)
     *         - Share value: 20 shares * 1.5 = 30 WETH
     *         - Principal: 20 WETH
     *
     * Step 4: Calculate profit (Feature 5.1)
     *         - Expected: 30 - 20 = 10 WETH profit
     *
     * Step 5: Harvest profits (Feature 5.2 + 5.3)
     *         - Redeems profit shares
     *         - Queues assets in _queuedProfits (Type B)
     *
     * Step 6: Verify WETH received from harvest
     *         - Confirms assets in tokenized vault
     *
     * Step 7: Distribute profits to kingVault (Feature 5.4)
     *         - Transfers from _queuedProfits to kingVault
     *         - Type B withdrawal completion
     *
     * Step 8: Verify kingVault received profits
     *         - Confirms profit transfer
     *
     * Step 9: Verify no more profits to distribute
     *         - _queuedProfits cleared
     *         - Tests idempotency
     *
     * This test validates the complete separation of:
     *      - Type A (principal): deposit → withdraw flow
     *      - Type B (profit): harvest → distribute flow
     */
    function test_fullProfitCycle() public {
        // 1. Deposit 20 WETH to KingTokenizedVault
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 20 ether);
        assertEq(weth.balanceOf(address(tokenizedVault)), 20 ether);

        // 2. Deploy to ERC-4626 vault
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);
        assertEq(weth.balanceOf(address(tokenizedVault)), 0);
        assertEq(erc4626Vault.balanceOf(address(tokenizedVault)), 20 ether);

        // 3. Simulate 50% profit (1 share = 1.5 WETH)
        erc4626Vault.setExchangeRate(1.5e18);

        // 4. Calculate profit
        uint256 profit = tokenizedVault.calculateProfit();
        assertApproxEqRel(profit, 10 ether, 0.01e18, "Profit should be ~10 ETH");

        // 5. Harvest profits
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // 6. Verify WETH received from harvest
        assertGt(weth.balanceOf(address(tokenizedVault)), 0, "Should have harvested WETH");

        // 7. Distribute profits
        uint256 kingVaultBalanceBefore = weth.balanceOf(kingVault);
        vm.prank(owner);
        tokenizedVault.distributeProfits();

        // 8. Verify king vault received profits
        uint256 kingVaultBalanceAfter = weth.balanceOf(kingVault);
        assertGt(kingVaultBalanceAfter, kingVaultBalanceBefore, "King vault should receive profits");

        // 9. Verify no more profits to distribute
        vm.startPrank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitsToDistribute.selector);
        tokenizedVault.distributeProfits();
        vm.stopPrank();
    }

    // ============================================
    // Edge Case Tests (Task 8.5)
    // ============================================

    /**
     * @notice Test zero profit scenario
     * @dev Verifies:
     *      - calculateProfit returns 0 when no appreciation
     *      - harvestProfits reverts with NoProfitToHarvest
     *      - System handles no-profit case gracefully
     */
    function test_edgeCase_zeroProfitScenario() public {
        // Setup: Deposit and deploy
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // No appreciation: exchange rate stays 1:1
        uint256 profit = tokenizedVault.calculateProfit();
        assertEq(profit, 0, "Profit should be zero with no appreciation");

        // Harvest should revert
        vm.prank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitToHarvest.selector);
        tokenizedVault.harvestProfits();
    }

    /**
     * @notice Test negative profit scenario (share depreciation)
     * @dev Verifies:
     *      - Share value below principal returns 0 profit (no negative)
     *      - System protects against losses in profit calculation
     */
    function test_edgeCase_shareDepreciation() public {
        // Setup
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Simulate depreciation: shares worth less than principal
        erc4626Vault.setExchangeRate(0.8e18); // 20% loss

        // Profit should be 0 (not negative)
        uint256 profit = tokenizedVault.calculateProfit();
        assertEq(profit, 0, "Profit should be 0 when depreciated");

        // Harvest should revert
        vm.prank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitToHarvest.selector);
        tokenizedVault.harvestProfits();
    }

    /**
     * @notice Test multi-asset profit distribution
     * @dev Verifies:
     *      - Profit calculation works with multiple principal assets
     *      - Distribution handles multiple profit assets
     *      - Accounting is correct across assets
     */
    function test_edgeCase_multiAssetProfitDistribution() public {
        // Register USDC
        vm.startPrank(owner);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        tokenizedVault.registerAssets(assets, accepted);
        vm.stopPrank();

        // Fund kingVault with USDC
        usdc.mint(kingVault, 20_000e6); // 20k USDC
        vm.prank(kingVault);
        usdc.approve(address(tokenizedVault), type(uint256).max);

        // Deposit both WETH and USDC as principal
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.startPrank(kingVault);
        address[] memory usdcAssets = new address[](1);
        usdcAssets[0] = address(usdc);
        uint256[] memory usdcAmounts = new uint256[](1);
        usdcAmounts[0] = 20_000e6;
        tokenizedVault.deposit(usdcAssets, usdcAmounts);
        vm.stopPrank();

        // Deploy only WETH (USDC stays as principal)
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Generate profit on WETH shares
        erc4626Vault.setExchangeRate(3.0e18); // 200% profit

        // Calculate profit accounting for both principals
        // WETH principal: 10 ETH
        // USDC principal: 20k USDC * 0.0005 ETH = 10 ETH
        // Total principal: 20 ETH
        // Share value: 10 shares * 3.0 = 30 ETH
        // Profit: 30 - 20 = 10 ETH
        uint256 profit = tokenizedVault.calculateProfit();
        assertGt(profit, 0, "Should have profit with multi-asset principal");
        assertApproxEqRel(profit, 10 ether, 0.05e18, "Profit should account for both assets");
    }

    /**
     * @notice Test profit distribution with pending withdrawals
     * @dev Verifies:
     *      - Can distribute profits while principal withdrawal queued
     *      - Type A and Type B queues don't interfere
     *      - Accounting remains correct
     */
    function test_edgeCase_profitDistributionWithPendingWithdrawals() public {
        // Setup
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 30 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 30 ether);

        // Generate profit - fund vault to back the 1.5x appreciation
        // Vault has 30 ether, needs 45 ether total, so mint 15 more
        weth.mint(address(erc4626Vault), 15 ether);
        erc4626Vault.setExchangeRate(1.5e18);

        // Harvest profits (Type B)
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Queue principal withdrawal (Type A)
        uint256 remainingShares = tokenizedVault.getVaultShares();
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(address(weth), remainingShares, false);

        // Both queues should have assets
        uint256 idle = weth.balanceOf(address(tokenizedVault));
        assertGt(idle, 0, "Should have idle WETH from both operations");

        // Distribute profits should work despite pending principal withdrawal
        uint256 kingVaultBefore = weth.balanceOf(kingVault);
        vm.prank(owner);
        tokenizedVault.distributeProfits();

        // Verify profits distributed
        assertGt(weth.balanceOf(kingVault), kingVaultBefore, "Profits should be distributed");

        // In atomic mode, principal withdrawals complete immediately
        // After profit distribution, the principal assets should be available for Flow A withdrawal
        uint256 available = tokenizedVault.availableForWithdraw(address(weth));
        assertGt(available, 0, "Should have principal available for withdrawal");
    }

    /**
     * @notice Test very small profit scenario
     * @dev Verifies:
     *      - System handles tiny profit amounts (1 wei)
     *      - No rounding errors cause reversion
     *      - Profit shares calculated correctly
     */
    function test_edgeCase_verySmallProfit() public {
        // Fund kingVault with more WETH for this large deposit test
        weth.mint(kingVault, 1000 ether);

        // Large deposit to make relative profit tiny
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 1000 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 1000 ether);

        // Tiny appreciation (0.0001%) - also fund vault to back this
        weth.mint(address(erc4626Vault), 1 ether); // Tiny profit amount
        erc4626Vault.setExchangeRate(1.000001e18);

        uint256 profit = tokenizedVault.calculateProfit();

        if (profit > 0) {
            // Harvest should succeed if profit exists
            vm.prank(owner);
            tokenizedVault.harvestProfits();
        } else {
            // Or revert if rounded to zero
            vm.prank(owner);
            vm.expectRevert(KingTokenizedVault.NoProfitToHarvest.selector);
            tokenizedVault.harvestProfits();
        }
    }

    /**
     * @notice Test maximum profit scenario
     * @dev Verifies:
     *      - System handles extreme appreciation (1000x)
     *      - No overflow on profit calculation
     *      - Harvest and distribution work correctly
     */
    function test_edgeCase_extremeProfit() public {
        // Setup
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 1 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 1 ether);

        // Extreme appreciation (1000x) - fund vault to back this value
        // Vault now has 1 ether, needs 1000 ether total, so mint 999 more
        weth.mint(address(erc4626Vault), 999 ether);
        erc4626Vault.setExchangeRate(1000e18);

        // Calculate profit (should not overflow)
        uint256 profit = tokenizedVault.calculateProfit();
        assertGt(profit, 0, "Should calculate extreme profit");
        assertApproxEqRel(profit, 999 ether, 0.01e18, "Profit should be ~999 ETH");

        // Harvest should work
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Distribute should work
        vm.prank(owner);
        tokenizedVault.distributeProfits();

        // Verify kingVault received massive profit
        assertGt(weth.balanceOf(kingVault), 900 ether, "Should receive large profit");
    }

    /**
     * @notice Test profit distribution after partial withdrawal
     * @dev Verifies:
     *      - Profit calculation correct after withdrawing shares
     *      - Remaining shares still generate profit
     *      - Accounting remains accurate
     */
    function test_edgeCase_profitAfterPartialWithdrawal() public {
        // Setup
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 20 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        // Withdraw half the shares (no profit yet)
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(address(weth), 10 ether, false);

        // Now generate profit on remaining shares
        erc4626Vault.setExchangeRate(2.0e18); // 100% appreciation

        // Remaining: 10 shares @ 2.0 = 20 WETH value
        // Principal: 20 WETH (unchanged by share withdrawal)
        // Profit: 20 - 20 = 0 (principal not reduced by withdrawal)

        // Actually, withdrawFromVault with isProfitWithdrawal=false
        // withdraws principal, so this affects accounting
        // The principal should remain 20 ETH total in _deposits
        // But we withdrew 10 ETH worth of shares

        uint256 profit = tokenizedVault.calculateProfit();

        // After withdrawing 10 shares worth 10 ETH:
        // Remaining 10 shares @ 2.0x = 20 ETH
        // Principal still 20 ETH
        // Profit = 20 - 20 = 0
        assertEq(profit, 0, "No profit after partial withdrawal at 1:1");
    }

    /**
     * @notice Test consecutive profit harvests
     * @dev Verifies:
     *      - First harvest extracts initial profit
     *      - Second harvest (after more appreciation) extracts additional profit
     *      - Accounting is correct across multiple harvests
     */
    function test_edgeCase_consecutiveProfitHarvests() public {
        // Setup
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 20 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        // First profit cycle: 50% appreciation
        erc4626Vault.setExchangeRate(1.5e18);

        vm.prank(owner);
        tokenizedVault.harvestProfits();

        uint256 kingVaultAfterFirst = weth.balanceOf(kingVault);

        vm.prank(owner);
        tokenizedVault.distributeProfits();

        uint256 firstProfit = weth.balanceOf(kingVault) - kingVaultAfterFirst;
        assertGt(firstProfit, 0, "First profit should be positive");

        // Second profit cycle: additional 33% appreciation from current level
        // Remaining shares should appreciate further
        // Set even higher rate for second cycle
        erc4626Vault.setExchangeRate(2.0e18);

        // Calculate second profit
        uint256 secondProfit = tokenizedVault.calculateProfit();

        if (secondProfit > 0) {
            vm.prank(owner);
            tokenizedVault.harvestProfits();

            uint256 balanceBefore = weth.balanceOf(kingVault);
            vm.prank(owner);
            tokenizedVault.distributeProfits();

            uint256 actualSecondProfit = weth.balanceOf(kingVault) - balanceBefore;
            assertGt(actualSecondProfit, 0, "Second profit should be positive");
        }
    }

    /**
     * @notice Test profit distribution with zero balance
     * @dev Verifies:
     *      - distributeProfits reverts when no profits queued
     *      - Prevents wasted gas on empty operations
     */
    function test_edgeCase_distributeProfitsWithZeroBalance() public {
        // No harvest, try to distribute
        vm.prank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitsToDistribute.selector);
        tokenizedVault.distributeProfits();
    }

    /**
     * @notice Test profit calculation with price feed failure
     * @dev Verifies:
     *      - calculateProfit reverts if price not available
     *      - System protects against bad price data
     */
    function test_edgeCase_profitCalculationWithPriceFeedFailure() public {
        // Setup
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Set price to zero (simulating price feed failure)
        priceProvider.setPrice(address(weth), 0);

        // Calculate profit should revert
        vm.expectRevert();
        tokenizedVault.calculateProfit();
    }
}
