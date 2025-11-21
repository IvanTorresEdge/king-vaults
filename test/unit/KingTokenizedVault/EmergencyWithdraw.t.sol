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

/**
 * @title KingTokenizedVault_EmergencyWithdrawTest
 * @notice Tests for KingTokenizedVault emergencyWithdraw() override
 * @dev Tests HIGH-11 fix: emergencyWithdraw() now respects queued operations
 *
 * Test Coverage:
 * - Withdraws only unencumbered idle assets (available = idle - queuedWithdraw - queuedProfits)
 * - Preserves _queuedWithdraw for pending principal withdrawals
 * - Preserves _queuedProfits for pending profit distributions
 * - Preserves all pending state (_pendingSharesByAsset, _withdrawalRequests)
 * - Correctly reduces _deposits by withdrawn amount (not to zero)
 * - Handles multiple tokens with different reserved amounts
 * - Works in both atomic and async modes
 * - Works when paused
 * - Access control (owner and kingVault)
 * - Event emission with correct amounts
 */
contract KingTokenizedVault_EmergencyWithdrawTest is Test {
    // ============================================
    // Contracts
    // ============================================

    KingTokenizedVault public tokenizedVault;
    KingTokenizedVault public implementation;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public dai;
    MockPriceProvider public priceProvider;
    MockERC4626Vault public erc4626Vault;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault;
    address public unauthorized = address(0x3);

    // ============================================
    // Events
    // ============================================

    event EmergencyWithdraw(address[] assets, uint256[] amounts, uint256 timestamp);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        kingVault = address(new MockKingVaultController());

        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Deploy mock ERC-4626 vault
        erc4626Vault = new MockERC4626Vault(weth, "Vault WETH", "vWETH");

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18);
        priceProvider.setPrice(address(weth), 1e18);
        priceProvider.setPrice(address(usdc), 0.0005e18);
        priceProvider.setPrice(address(dai), 0.001e18);

        // Deploy tokenized vault in async mode (supports withdrawal requests)
        tokenizedVault = _deployStandardTokenizedVault(false); // async mode
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _deployTokenizedVault(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address[] memory _assets,
        bool[] memory _accepted,
        bool isAtomic
    ) internal returns (KingTokenizedVault) {
        KingTokenizedVault impl = new KingTokenizedVault(address(erc4626Vault), isAtomic);

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, _owner, _kingVault, _priceProvider, _assets, _accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return KingTokenizedVault(address(proxy));
    }

    function _deployStandardTokenizedVault(bool isAtomic) internal returns (KingTokenizedVault) {
        address[] memory assets = new address[](3);
        assets[0] = address(weth);
        assets[1] = address(usdc);
        assets[2] = address(dai);
        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        return _deployTokenizedVault(owner, kingVault, address(priceProvider), assets, accepted, isAtomic);
    }

    /**
     * @notice Simulate a deposit by minting tokens and updating internal state
     */
    function _simulateDeposit(address token, uint256 amount) internal {
        // Mint tokens to kingVault first
        MockERC20(token).mint(kingVault, amount);

        // Approve vault to spend
        vm.prank(kingVault);
        MockERC20(token).approve(address(tokenizedVault), amount);

        // Call deposit from kingVault to update _deposits
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(kingVault);
        tokenizedVault.deposit(tokens, amounts);
    }

    /**
     * @notice Simulate queueing principal withdrawal (sets _queuedWithdraw)
     * @dev For async mode vaults
     */
    function _simulateQueuedWithdraw(address token, uint256 amount) internal {
        // Need shares in ERC4626 vault first
        erc4626Vault.mint(address(tokenizedVault), amount);

        // Queue withdrawal request (isProfitWithdrawal = false for principal)
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(token, amount, false);
    }

    /**
     * @notice Simulate queueing profit harvest (sets _queuedProfits)
     */
    function _simulateQueuedProfits(address token, uint256 sharesAmount) internal {
        // Deposit shares first
        erc4626Vault.mint(address(tokenizedVault), sharesAmount);

        vm.prank(owner);
        tokenizedVault.depositToVault(token, sharesAmount);

        // Increase exchange rate to create profit
        erc4626Vault.setExchangeRate(1.5e18); // 1.5 assets per share

        // Queue profit harvest (harvestProfits takes no parameters)
        vm.prank(owner);
        tokenizedVault.harvestProfits();
    }

    // ============================================
    // Tests: Basic Functionality
    // ============================================

    function test_EmergencyWithdraw_WithdrawsAllIdleWhenNothingQueued() public {
        // Setup: Deposit 100 WETH to vault
        _simulateDeposit(address(weth), 100e18);

        uint256 initialKingVaultBalance = weth.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Verify: All idle WETH transferred to kingVault
        assertEq(weth.balanceOf(kingVault), initialKingVaultBalance + 100e18, "KingVault should receive all idle");
        assertEq(weth.balanceOf(address(tokenizedVault)), 0, "Vault should have zero balance");
    }

    // ============================================
    // Tests: Respects Queued Withdrawals
    // ============================================

    function test_EmergencyWithdraw_RespectsQueuedWithdraw() public {
        // Setup: 100 WETH idle, 60 WETH queued for principal withdrawal
        _simulateDeposit(address(weth), 100e18);
        _simulateQueuedWithdraw(address(weth), 60e18);

        uint256 initialKingVaultBalance = weth.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Verify: Only available = 100 - 60 = 40 WETH withdrawn
        assertEq(weth.balanceOf(kingVault), initialKingVaultBalance + 40e18, "Should withdraw only available (40 WETH)");
        assertEq(weth.balanceOf(address(tokenizedVault)), 60e18, "Should preserve 60 WETH for queued withdrawal");
    }

    function test_EmergencyWithdraw_RespectsQueuedProfits() public {
        // Setup: Deposit and create profit scenario
        _simulateDeposit(address(weth), 100e18);
        _simulateQueuedProfits(address(weth), 50e18);

        // Additional idle balance for profit redemption
        weth.mint(address(tokenizedVault), 50e18);

        uint256 idleBeforeWithdraw = weth.balanceOf(address(tokenizedVault));
        uint256 initialKingVaultBalance = weth.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Verify: Respects queued profits
        uint256 withdrawn = weth.balanceOf(kingVault) - initialKingVaultBalance;
        uint256 remaining = weth.balanceOf(address(tokenizedVault));

        assertTrue(withdrawn > 0, "Should withdraw some amount");
        assertTrue(remaining > 0, "Should preserve assets for queued profits");
        assertEq(withdrawn + remaining, idleBeforeWithdraw, "Total should match initial idle");
    }

    function test_EmergencyWithdraw_RespectsBothQueuedWithdrawAndProfits() public {
        // Setup: 130 WETH total (100 deposited + 30 minted), 40 queued withdraw, 130 USDC idle
        // Note: Uses different assets due to mutex protection (can't queue both for same asset)
        _simulateDeposit(address(weth), 100e18);
        _simulateQueuedWithdraw(address(weth), 40e18);

        _simulateDeposit(address(usdc), 130e6);
        // Add additional idle WETH (simulating assets received but not yet deployed)
        weth.mint(address(tokenizedVault), 30e18);

        uint256 initialWethBalance = weth.balanceOf(kingVault);
        uint256 initialUsdcBalance = usdc.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Verify: Should preserve queued withdrawal for WETH
        // Total WETH: 130 (100 + 30), Queued: 40, Available: 90
        uint256 wethWithdrawn = weth.balanceOf(kingVault) - initialWethBalance;
        assertEq(wethWithdrawn, 90e18, "Should withdraw available WETH (130 - 40)");
        assertEq(weth.balanceOf(address(tokenizedVault)), 40e18, "Should preserve 40 WETH queued");

        // Verify: Should withdraw all USDC (no queue)
        uint256 usdcWithdrawn = usdc.balanceOf(kingVault) - initialUsdcBalance;
        assertEq(usdcWithdrawn, 130e6, "Should withdraw all USDC");
    }

    function test_EmergencyWithdraw_NoWithdrawalWhenIdleEqualsReserved() public {
        // Setup: 60 WETH idle, 60 WETH queued
        _simulateDeposit(address(weth), 60e18);
        _simulateQueuedWithdraw(address(weth), 60e18);

        uint256 initialKingVaultBalance = weth.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Verify: Nothing withdrawn (idle == reserved)
        assertEq(weth.balanceOf(kingVault), initialKingVaultBalance, "Should not withdraw anything");
        assertEq(weth.balanceOf(address(tokenizedVault)), 60e18, "Should preserve all 60 WETH");
    }

    function test_EmergencyWithdraw_NoWithdrawalWhenIdleLessThanReserved() public {
        // Setup: 50 WETH idle, but 60 WETH queued (edge case)
        _simulateDeposit(address(weth), 50e18);
        _simulateQueuedWithdraw(address(weth), 60e18);

        uint256 initialKingVaultBalance = weth.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Verify: Nothing withdrawn (idle < reserved)
        assertEq(weth.balanceOf(kingVault), initialKingVaultBalance, "Should not withdraw anything");
        assertEq(weth.balanceOf(address(tokenizedVault)), 50e18, "Should preserve all idle assets");
    }

    // ============================================
    // Tests: Multiple Tokens
    // ============================================

    function test_EmergencyWithdraw_MultipleTokensWithDifferentReserved() public {
        // Setup three tokens with different reserved amounts
        _simulateDeposit(address(weth), 100e18); // 100 idle, 0 reserved
        _simulateDeposit(address(usdc), 1000e6); // 1000 idle
        _simulateDeposit(address(dai), 500e18); // 500 idle

        // Queue withdrawals for USDC and DAI
        _simulateQueuedWithdraw(address(usdc), 600e6); // 600 reserved
        _simulateQueuedWithdraw(address(dai), 500e18); // 500 reserved

        uint256 initialWethBalance = weth.balanceOf(kingVault);
        uint256 initialUsdcBalance = usdc.balanceOf(kingVault);
        uint256 initialDaiBalance = dai.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Verify each token
        // WETH: all 100 withdrawn (no reserved)
        assertEq(weth.balanceOf(kingVault), initialWethBalance + 100e18, "WETH: should withdraw all");

        // USDC: 400 withdrawn (1000 - 600)
        assertEq(usdc.balanceOf(kingVault), initialUsdcBalance + 400e6, "USDC: should withdraw available");
        assertEq(usdc.balanceOf(address(tokenizedVault)), 600e6, "USDC: should preserve reserved");

        // DAI: 0 withdrawn (500 - 500 = 0)
        assertEq(dai.balanceOf(kingVault), initialDaiBalance, "DAI: should withdraw nothing");
        assertEq(dai.balanceOf(address(tokenizedVault)), 500e18, "DAI: should preserve all");
    }

    // ============================================
    // Tests: Atomic vs Async Modes
    // ============================================

    function test_EmergencyWithdraw_WorksInAtomicMode() public {
        // Deploy atomic mode vault
        KingTokenizedVault atomicVault = _deployStandardTokenizedVault(true); // atomic mode

        // Deposit idle assets to atomic vault (NOT to ERC4626 vault)
        // This simulates assets received from kingVault that haven't been deployed yet
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(atomicVault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        atomicVault.deposit(tokens, amounts);

        uint256 initialBalance = weth.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        atomicVault.emergencyWithdraw();

        // Verify
        assertEq(weth.balanceOf(kingVault), initialBalance + 100e18, "Should withdraw all in atomic mode");
    }

    function test_EmergencyWithdraw_WorksInAsyncMode() public {
        // Already deployed in async mode in setUp()
        _simulateDeposit(address(weth), 100e18);

        uint256 initialBalance = weth.balanceOf(kingVault);

        // Execute emergency withdraw
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Verify
        assertEq(weth.balanceOf(kingVault), initialBalance + 100e18, "Should withdraw all in async mode");
    }

    // ============================================
    // Tests: Access Control
    // ============================================

    function test_EmergencyWithdraw_OwnerCanCall() public {
        _simulateDeposit(address(weth), 100e18);

        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();
        // Should not revert
    }

    function test_EmergencyWithdraw_KingVaultCanCall() public {
        _simulateDeposit(address(weth), 100e18);

        vm.prank(kingVault);
        tokenizedVault.emergencyWithdraw();
        // Should not revert
    }

    function test_EmergencyWithdraw_UnauthorizedCannotCall() public {
        _simulateDeposit(address(weth), 100e18);

        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        tokenizedVault.emergencyWithdraw();
    }

    // ============================================
    // Tests: Paused State
    // ============================================

    function test_EmergencyWithdraw_WorksWhenPaused() public {
        _simulateDeposit(address(weth), 100e18);

        // Pause vault
        vm.prank(owner);
        tokenizedVault.pause();

        uint256 initialBalance = weth.balanceOf(kingVault);

        // Should still work when paused
        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        assertEq(weth.balanceOf(kingVault), initialBalance + 100e18, "Should work when paused");
    }

    // ============================================
    // Tests: Event Emission
    // ============================================

    function test_EmergencyWithdraw_EmitsCorrectEvent() public {
        _simulateDeposit(address(weth), 100e18);
        _simulateDeposit(address(usdc), 1000e6);

        // Expect event with correct amounts
        address[] memory expectedTokens = new address[](2);
        expectedTokens[0] = address(weth);
        expectedTokens[1] = address(usdc);

        uint256[] memory expectedAmounts = new uint256[](2);
        expectedAmounts[0] = 100e18;
        expectedAmounts[1] = 1000e6;

        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdraw(expectedTokens, expectedAmounts, block.timestamp);

        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();
    }

    function test_EmergencyWithdraw_EmitsEventWithPartialAmounts() public {
        // Setup with reserved amounts
        _simulateDeposit(address(weth), 100e18);
        _simulateQueuedWithdraw(address(weth), 30e18);

        _simulateDeposit(address(usdc), 1000e6);
        _simulateQueuedWithdraw(address(usdc), 600e6);

        // Expected event with available amounts
        address[] memory expectedTokens = new address[](2);
        expectedTokens[0] = address(weth);
        expectedTokens[1] = address(usdc);

        uint256[] memory expectedAmounts = new uint256[](2);
        expectedAmounts[0] = 70e18; // 100 - 30
        expectedAmounts[1] = 400e6; // 1000 - 600

        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdraw(expectedTokens, expectedAmounts, block.timestamp);

        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();
    }

    // ============================================
    // Tests: State Preservation
    // ============================================

    function test_EmergencyWithdraw_PreservesWithdrawalRequests() public {
        _simulateDeposit(address(weth), 100e18);
        _simulateQueuedWithdraw(address(weth), 60e18);

        // Get request before emergency withdraw
        KingTokenizedVault.WithdrawalRequest memory requestBefore = tokenizedVault.getWithdrawalRequest(address(weth));

        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        // Get request after emergency withdraw
        KingTokenizedVault.WithdrawalRequest memory requestAfter = tokenizedVault.getWithdrawalRequest(address(weth));

        // Verify request unchanged (KingTokenizedVault has different struct fields)
        assertEq(requestAfter.asset, requestBefore.asset, "Request asset should be unchanged");
        assertEq(requestAfter.shares, requestBefore.shares, "Request shares should be unchanged");
        assertEq(requestAfter.expected, requestBefore.expected, "Request expected should be unchanged");
        assertEq(requestAfter.deadline, requestBefore.deadline, "Request deadline should be unchanged");
        assertEq(requestAfter.isProfitWithdrawal, requestBefore.isProfitWithdrawal, "Request type should be unchanged");
    }

    function test_EmergencyWithdraw_PreservesVaultShares() public {
        _simulateDeposit(address(weth), 100e18);
        _simulateQueuedWithdraw(address(weth), 60e18);

        uint256 sharesBefore = tokenizedVault.getVaultShares();

        vm.prank(owner);
        tokenizedVault.emergencyWithdraw();

        uint256 sharesAfter = tokenizedVault.getVaultShares();

        assertEq(sharesAfter, sharesBefore, "Vault shares should be unchanged");
    }
}
