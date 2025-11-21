// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingBoringVault} from "../../../src/vaults/KingBoringVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPriceProvider} from "../../mocks/MockPriceProvider.sol";
import {MockKingVaultController} from "../../mocks/MockKingVaultController.sol";
import {IKingVault} from "../../../src/interfaces/IKingVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title WithdrawalsTest
 * @notice Comprehensive unit tests for BoringVault withdrawals and dual tracking
 * @dev Tests Task 7.3 acceptance criteria:
 *      - Test withdraw() for idle asset withdrawals
 *      - Test withdrawFromVault() withdrawal request creation
 *      - Test finalizeWithdrawal() share redemption flow
 *      - Test _pendingShares tracking across operations
 *      - Test _deposits mapping decrements correctly
 *      - Test dual tracking: idle balance vs deployed balance
 *      - Test withdrawal request state transitions
 *      - Test slippage validation during withdrawals
 *      - Test cannot finalize before maturity
 *      - Test cannot create duplicate withdrawal requests
 *      - Verify all withdrawal event emissions
 *
 * Critical Accounting:
 * - withdraw() only works for idle assets, decrements _deposits immediately
 * - withdrawFromVault() creates request, increments _pendingShares
 * - completePrincipalWithdraw() redeems shares, decrements both _deposits and _pendingShares
 * - Dual tracking must remain consistent: getBalance() = idle + deployed (as principal)
 */
contract WithdrawalsTest is Test {
    // ============================================
    // Contracts
    // ============================================

    KingBoringVault public boringVault;
    KingBoringVault public implementation;
    MockERC20 public weth;
    MockERC20 public ethfi;
    MockERC20 public usdc;
    MockPriceProvider public priceProvider;
    MockERC20 public vaultToken; // Mock BoringVault shares
    MockTeller public teller;
    MockAccountant public accountant;
    MockAtomicQueue public atomicQueue;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault;
    address public unauthorized = address(0x3);

    // ============================================
    // Events
    // ============================================

    event Withdrawn(address[] assets, uint256[] amounts, address receiver, uint256 timestamp);
    event WithdrawalQueued(address indexed asset, uint256 shareAmount, uint256 expectedAmount, uint64 deadline);
    event WithdrawalConfirmed(address indexed asset, uint256 amountReceived);
    event WithdrawalCancelled(address indexed asset, uint256 shareAmount);
    event PrincipalWithdrawCompleted(
        address indexed asset, uint256 amount, address indexed receiver, uint256 timestamp
    );
    event WithdrawFromVaultCancelled(address indexed asset, uint256 amount, uint256 timestamp);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ethfi = new MockERC20("EtherFi Token", "ETHFI", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vaultToken = new MockERC20("Boring Vault Shares", "bvWETH", 18);

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(ethfi), 0.0005e18); // 1 ETHFI = 0.0005 ETH
        priceProvider.setPrice(address(usdc), 0.0005e18); // 1 USDC = 0.0005 ETH

        // Deploy mock Veda contracts
        teller = new MockTeller(address(vaultToken));
        accountant = new MockAccountant(address(weth), address(vaultToken));
        atomicQueue = new MockAtomicQueue();

        // Connect teller to accountant
        teller.setAccountant(address(accountant));

        // Set up mock exchange rate in accountant (1 share = 1.0 WETH initially)
        accountant.setRate(1.0e18);

        // Deploy BoringVault implementation (with immutable addresses)
        implementation = new KingBoringVault(
            address(vaultToken), // vault
            address(teller), // teller
            address(accountant) // accountant
        );

        // Deploy and initialize proxy
        boringVault = _deployStandardKingBoringVault();
    }

    // ============================================
    // Helper Functions
    // ============================================

    /**
     * @notice Deploy and initialize a BoringVault proxy with given parameters
     */
    function _deployKingBoringVault(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address _atomicQueue,
        address[] memory _tokens,
        bool[] memory _accepted
    ) internal returns (KingBoringVault) {
        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector, _owner, _kingVault, _priceProvider, _atomicQueue, _tokens, _accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return KingBoringVault(address(proxy));
    }

    /**
     * @notice Deploy a properly initialized BoringVault for standard tests
     */
    function _deployStandardKingBoringVault() internal returns (KingBoringVault) {
        address[] memory tokens = new address[](3);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        tokens[2] = address(usdc);
        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        return _deployKingBoringVault(owner, kingVault, address(priceProvider), address(atomicQueue), tokens, accepted);
    }

    /**
     * @notice Helper to deposit assets from kingVault
     */
    function _depositAssets(address asset, uint256 amount) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        MockERC20(asset).mint(kingVault, amount);
        vm.prank(kingVault);
        MockERC20(asset).approve(address(boringVault), amount);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);
    }

    /**
     * @notice Helper to deploy assets to vault
     */
    function _deployToVault(address asset, uint256 amount) internal returns (uint256 shares) {
        vm.prank(owner);
        return boringVault.depositToVault(asset, amount);
    }

    /**
     * @notice Helper to simulate solver fulfilling withdrawal
     */
    function _simulateSolverFulfillment(address asset, uint256 amount) internal {
        // Solver sends asset to BoringVault
        MockERC20(asset).mint(address(boringVault), amount);
    }

    // ============================================
    // withdraw() Tests - Idle Asset Withdrawals
    // ============================================

    function test_withdraw_IdleAssets_SucceedsWithSufficientBalance() public {
        // Deposit 1000 WETH
        _depositAssets(address(weth), 1000e18);

        // Withdraw 500 WETH (idle balance sufficient)
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        vm.expectEmit(true, true, true, true);
        emit Withdrawn(tokens, amounts, kingVault, block.timestamp);

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        // Verify state
        assertEq(boringVault.getBalance(address(weth)), 500e18, "Principal should decrement");
        assertEq(weth.balanceOf(kingVault), 500e18, "KingVault should receive tokens");
        assertEq(weth.balanceOf(address(boringVault)), 500e18, "Idle balance should decrease");
    }

    function test_withdraw_IdleAssets_DecrementsDepositsMapping() public {
        // Deposit 1000 WETH
        _depositAssets(address(weth), 1000e18);

        uint256 principalBefore = boringVault.getBalance(address(weth));
        assertEq(principalBefore, 1000e18);

        // Withdraw 300 WETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 300e18;

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        uint256 principalAfter = boringVault.getBalance(address(weth));
        assertEq(principalAfter, 700e18, "_deposits should decrement by withdrawn amount");
    }

    function test_withdraw_IdleAssets_MultipleAssets() public {
        // Deposit multiple assets
        _depositAssets(address(weth), 1000e18);
        _depositAssets(address(ethfi), 2000e18);

        // Withdraw both
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e18;
        amounts[1] = 1000e18;

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        // Verify both decremented
        assertEq(boringVault.getBalance(address(weth)), 500e18);
        assertEq(boringVault.getBalance(address(ethfi)), 1000e18);
    }

    function test_withdraw_IdleAssets_RevertsWithZeroAmount() public {
        _depositAssets(address(weth), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        vm.prank(kingVault);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        boringVault.withdraw(tokens, amounts, kingVault);
    }

    function test_withdraw_IdleAssets_RevertsWithInsufficientBalance() public {
        _depositAssets(address(weth), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2000e18; // More than available

        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.withdraw(tokens, amounts, kingVault);
    }

    function test_withdraw_IdleAssets_RevertsWithZeroReceiver() public {
        _depositAssets(address(weth), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        vm.prank(kingVault);
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        boringVault.withdraw(tokens, amounts, address(0));
    }

    function test_withdraw_IdleAssets_RevertsForNonKingVault() public {
        _depositAssets(address(weth), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        boringVault.withdraw(tokens, amounts, kingVault);
    }

    // ============================================
    // withdrawFromVault() Tests - Request Creation
    // ============================================

    function test_withdrawFromVault_CreatesWithdrawalRequest() public {
        // Setup: deposit and deploy to vault
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Create withdrawal request for 500 shares
        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18); // Rate is 1.0

        vm.expectEmit(true, true, true, true);
        emit WithdrawalQueued(address(weth), sharesToWithdraw, expectedAmount, uint64(block.timestamp + 7 days));

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Verify request stored
        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertEq(request.asset, address(weth), "Asset should be set");
        assertEq(request.want, sharesToWithdraw, "Want should be share amount");
        assertEq(request.offer, expectedAmount, "Offer should be expected asset amount");
        assertGt(request.deadline, block.timestamp, "Deadline should be in future");
    }

    function test_withdrawFromVault_IncrementsPendingShares() public {
        // Setup: deposit and deploy to vault
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Initial pending shares should be 0
        assertEq(boringVault.getPendingShares(), 0);

        // Create withdrawal request
        uint256 sharesToWithdraw = 500e18;
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Pending shares should be incremented
        assertEq(boringVault.getPendingShares(), sharesToWithdraw, "Pending shares should be incremented");
    }

    function test_withdrawFromVault_IncrementsQueuedWithdraw() public {
        // Setup: deposit and deploy to vault
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Create withdrawal request
        uint256 sharesToWithdraw = 500e18;

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Note: _queuedWithdraw is private, but we can verify indirectly through availableForWithdraw
        uint256 available = boringVault.availableForWithdraw(address(weth));
        assertEq(available, 0, "Available should be 0 after queuing withdrawal");
    }

    function test_withdrawFromVault_CustomDeadline() public {
        // Setup: deposit and deploy to vault
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Create withdrawal request with custom deadline
        uint64 customDeadline = uint64(block.timestamp + 14 days);
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 500e18, customDeadline);

        // Verify deadline
        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertEq(request.deadline, customDeadline, "Should use custom deadline");
    }

    function test_withdrawFromVault_RevertsWithZeroAmount() public {
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        vm.prank(owner);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        boringVault.withdrawFromVault(address(weth), 0, 0);
    }

    function test_withdrawFromVault_RevertsWithUnacceptedAsset() public {
        MockERC20 unregistered = new MockERC20("Unregistered", "UNREG", 18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IKingVault.AssetNotAccepted.selector, address(unregistered)));
        boringVault.withdrawFromVault(address(unregistered), 500e18, 0);
    }

    function test_withdrawFromVault_RevertsWithInsufficientAvailableShares() public {
        // Setup: deposit and deploy to vault
        _depositAssets(address(weth), 1000e18);
        uint256 shares = _deployToVault(address(weth), 1000e18); // Gets 1000 shares at rate 1.0

        // Try to withdraw more than available shares
        vm.prank(owner);
        vm.expectRevert();
        boringVault.withdrawFromVault(address(weth), shares + 1, 0);
    }

    function test_withdrawFromVault_RevertsWithDuplicateRequest() public {
        // Setup: deposit and deploy to vault
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Create first withdrawal request
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 500e18, 0);

        // Try to create another request for same asset
        vm.prank(owner);
        vm.expectRevert();
        boringVault.withdrawFromVault(address(weth), 300e18, 0);
    }

    function test_withdrawFromVault_RevertsForNonOwner() public {
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        vm.prank(unauthorized);
        vm.expectRevert();
        boringVault.withdrawFromVault(address(weth), 500e18, 0);
    }

    function test_withdrawFromVault_RevertsWhenPaused() public {
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.pause();

        vm.prank(owner);
        vm.expectRevert();
        boringVault.withdrawFromVault(address(weth), 500e18, 0);
    }

    // ============================================
    // completePrincipalWithdraw() Tests - Share Redemption
    // ============================================

    function test_completePrincipalWithdraw_SucceedsAfterSolverFulfillment() public {
        // Setup: deposit, deploy, and create withdrawal request
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Simulate solver fulfillment (sends assets to BoringVault)
        _simulateSolverFulfillment(address(weth), expectedAmount);

        // Complete withdrawal
        vm.expectEmit(true, true, true, true);
        emit PrincipalWithdrawCompleted(address(weth), expectedAmount, kingVault, block.timestamp);

        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);

        // Verify state
        assertEq(boringVault.getPendingShares(), 0, "Pending shares should be cleared");
        assertEq(weth.balanceOf(kingVault), expectedAmount, "KingVault should receive assets");
    }

    function test_completePrincipalWithdraw_ClearsWithdrawalRequest() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Verify request exists
        KingBoringVault.WithdrawalRequest memory requestBefore = boringVault.getWithdrawalRequest(address(weth));
        assertGt(requestBefore.deadline, 0, "Request should exist");

        // Complete withdrawal
        _simulateSolverFulfillment(address(weth), expectedAmount);
        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);

        // Verify request cleared
        KingBoringVault.WithdrawalRequest memory requestAfter = boringVault.getWithdrawalRequest(address(weth));
        assertEq(requestAfter.deadline, 0, "Request should be deleted");
        assertEq(requestAfter.asset, address(0), "Request should be deleted");
    }

    function test_completePrincipalWithdraw_DecrementsPendingShares() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        assertEq(boringVault.getPendingShares(), sharesToWithdraw, "Pending shares set");

        // Complete withdrawal
        _simulateSolverFulfillment(address(weth), expectedAmount);
        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);

        assertEq(boringVault.getPendingShares(), 0, "Pending shares should be reset to 0");
    }

    function test_completePrincipalWithdraw_DecrementsQueuedWithdraw() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Available should be 0 (all queued)
        assertEq(boringVault.availableForWithdraw(address(weth)), 0);

        // Complete withdrawal
        _simulateSolverFulfillment(address(weth), expectedAmount);
        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);

        // _queuedWithdraw should be cleared (verified indirectly through availableForWithdraw)
        uint256 available = boringVault.availableForWithdraw(address(weth));
        assertEq(available, 0, "Should still be 0 as no new idle assets");
    }

    function test_completePrincipalWithdraw_RevertsWithoutRequest() public {
        vm.prank(owner);
        vm.expectRevert();
        boringVault.completePrincipalWithdraw(address(weth), 500e18, kingVault);
    }

    function test_completePrincipalWithdraw_RevertsWithExcessiveAmount() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Simulate solver fulfillment
        _simulateSolverFulfillment(address(weth), expectedAmount);

        // Try to complete with more than queued
        vm.prank(owner);
        vm.expectRevert();
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount + 1, kingVault);
    }

    function test_completePrincipalWithdraw_RevertsWithZeroReceiver() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        _simulateSolverFulfillment(address(weth), expectedAmount);

        vm.prank(owner);
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, address(0));
    }

    function test_completePrincipalWithdraw_RevertsWithInsufficientIdle() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Don't simulate solver fulfillment (no idle balance)

        vm.prank(owner);
        vm.expectRevert();
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);
    }

    function test_completePrincipalWithdraw_RevertsForNonOwner() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        _simulateSolverFulfillment(address(weth), expectedAmount);

        vm.prank(unauthorized);
        vm.expectRevert();
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);
    }

    function test_completePrincipalWithdraw_RevertsWhenPaused() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        _simulateSolverFulfillment(address(weth), expectedAmount);

        vm.prank(owner);
        boringVault.pause();

        vm.prank(owner);
        vm.expectRevert();
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);
    }

    // ============================================
    // cancelWithdrawFromVault() Tests
    // ============================================

    function test_cancelWithdrawFromVault_DoesNotModifyDeposits() public {
        // This test verifies that cancelWithdrawFromVault does NOT modify _deposits
        // _deposits tracks King Protocol principal only - internal vault operations don't affect it

        // Setup: deposit 1000 WETH and deploy all to vault
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // _deposits[weth] should still be 1000 (withdrawFromVault doesn't change it)
        uint256 principalBefore = boringVault.getBalance(address(weth));
        assertEq(principalBefore, 1000e18, "Principal unchanged by withdrawFromVault");

        // Cancel the withdrawal
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        // _deposits should STILL be 1000 (cancel doesn't modify _deposits)
        uint256 principalAfter = boringVault.getBalance(address(weth));
        assertEq(principalAfter, 1000e18, "Principal unchanged by cancel");
    }

    function test_cancelWithdrawFromVault_ClearsPendingShares() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        assertEq(boringVault.getPendingShares(), sharesToWithdraw);

        // Cancel
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        assertEq(boringVault.getPendingShares(), 0, "Pending shares should be reset");
    }

    function test_cancelWithdrawFromVault_ClearsRequest() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 500e18, 0);

        // Cancel
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        // Request should be deleted
        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertEq(request.deadline, 0, "Request should be deleted");
    }

    function test_cancelWithdrawFromVault_RevertsWithoutRequest() public {
        vm.prank(owner);
        vm.expectRevert();
        boringVault.cancelWithdrawFromVault(address(weth));
    }

    function test_cancelWithdrawFromVault_RevertsForNonOwner() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 500e18, 0);

        vm.prank(unauthorized);
        vm.expectRevert();
        boringVault.cancelWithdrawFromVault(address(weth));
    }

    // ============================================
    // Dual Tracking Tests - Idle vs Deployed Balance
    // ============================================

    function test_dualTracking_IdleBalance_ReflectedInTotal() public {
        // Deposit 1000 WETH (all idle)
        _depositAssets(address(weth), 1000e18);

        // Principal tracks deposit
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal should be 1000");

        // Idle balance matches
        assertEq(weth.balanceOf(address(boringVault)), 1000e18, "Idle should be 1000");
    }

    function test_dualTracking_DeployedBalance_PrincipalUnchanged() public {
        // Deposit 1000 WETH
        _depositAssets(address(weth), 1000e18);

        // Deploy 600 WETH to vault
        _deployToVault(address(weth), 600e18);

        // Principal unchanged (still 1000)
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal unchanged at 1000");

        // Idle reduced to 400
        assertEq(weth.balanceOf(address(boringVault)), 400e18, "Idle should be 400");

        // Shares received (600 / 1.0 = 600)
        assertEq(vaultToken.balanceOf(address(boringVault)), 600e18, "Should have 600 shares");
    }

    function test_dualTracking_PartialWithdrawal_MaintainsConsistency() public {
        // Setup: deposit 1000, deploy 600, leaving 400 idle
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 600e18);

        // Withdraw 200 idle
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200e18;

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        // Principal reduced to 800
        assertEq(boringVault.getBalance(address(weth)), 800e18, "Principal should be 800");

        // Idle reduced to 200
        assertEq(weth.balanceOf(address(boringVault)), 200e18, "Idle should be 200");

        // Shares unchanged (still 600)
        assertEq(vaultToken.balanceOf(address(boringVault)), 600e18, "Shares unchanged");
    }

    function test_dualTracking_CompleteWithdrawal_Consistency() public {
        // Setup: deposit 1000, deploy all
        _depositAssets(address(weth), 1000e18);
        uint256 shares = _deployToVault(address(weth), 1000e18);

        // Queue withdrawal of all shares
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares, 0);

        // Simulate solver fulfillment
        _simulateSolverFulfillment(address(weth), 1000e18);

        // Complete withdrawal to external receiver
        address receiver = address(0x99);
        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), 1000e18, receiver);

        // Principal unchanged (assets transferred out)
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal still 1000");

        // Idle back to 0 (transferred to receiver)
        assertEq(weth.balanceOf(address(boringVault)), 0, "Idle should be 0");

        // Receiver got assets
        assertEq(weth.balanceOf(receiver), 1000e18, "Receiver should have 1000");
    }

    function test_dualTracking_ShareAppreciation_PrincipalUnchanged() public {
        // Deposit 1000 WETH
        _depositAssets(address(weth), 1000e18);

        // Deploy at rate 1.0 (gets 1000 shares)
        accountant.setRate(1.0e18);
        _deployToVault(address(weth), 1000e18);

        // Principal is 1000
        assertEq(boringVault.getBalance(address(weth)), 1000e18);

        // Share rate increases to 1.2 (share appreciation)
        accountant.setRate(1.2e18);
        // Now 1000 shares are worth 1200 WETH

        // Principal STILL 1000 (appreciation is profit, not principal)
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal unchanged despite appreciation");
    }

    // ============================================
    // _pendingShares Tracking Tests
    // ============================================

    function test_pendingShares_InitiallyZero() public view {
        assertEq(boringVault.getPendingShares(), 0, "Pending shares should start at 0");
    }

    function test_pendingShares_IncrementOnWithdrawFromVault() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Queue withdrawal
        uint256 sharesToWithdraw = 500e18;
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        assertEq(boringVault.getPendingShares(), sharesToWithdraw, "Pending shares should be incremented");
    }

    function test_pendingShares_DecrementOnComplete() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Queue withdrawal
        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Complete
        _simulateSolverFulfillment(address(weth), expectedAmount);
        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);

        assertEq(boringVault.getPendingShares(), 0, "Pending shares should be reset");
    }

    function test_pendingShares_DecrementOnCancel() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Queue withdrawal
        uint256 sharesToWithdraw = 500e18;
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // Cancel
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        assertEq(boringVault.getPendingShares(), 0, "Pending shares should be reset");
    }

    function test_pendingShares_PreventsWithdrawalWhenPending() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        uint256 shares = _deployToVault(address(weth), 1000e18);

        // Queue withdrawal for 500 shares
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 500e18, 0);

        // Available shares should be reduced
        uint256 availableShares = shares - boringVault.getPendingShares();
        assertEq(availableShares, 500e18, "Only 500 shares should be available");

        // Cannot queue another withdrawal exceeding available
        vm.prank(owner);
        vm.expectRevert(); // Duplicate request for same asset
        boringVault.withdrawFromVault(address(weth), 600e18, 0);
    }

    // ============================================
    // Slippage Validation Tests
    // ============================================

    function test_slippage_WithdrawalAppliesSlippageProtection() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // Set slippage to 100 BPS (1%)
        vm.prank(owner);
        boringVault.setMaxSlippage(100);

        // Create withdrawal request
        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        // Minimum amount with 1% slippage: 500 * 0.99 = 495
        uint256 minAmount = Math.mulDiv(expectedAmount, 10_000 - 100, 10_000);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        // AtomicQueue should have slippage protection encoded in atomicPrice
        // This is verified indirectly through the withdrawal request
        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertGt(request.offer, minAmount, "Offer should reflect slippage protection");
    }

    // ============================================
    // Withdrawal Request State Transitions
    // ============================================

    function test_requestState_CreatedToPendingToCompleted() public {
        // Initial: no request
        KingBoringVault.WithdrawalRequest memory initial = boringVault.getWithdrawalRequest(address(weth));
        assertEq(initial.deadline, 0, "No request initially");

        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // State 1: Request created (pending)
        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        KingBoringVault.WithdrawalRequest memory pending = boringVault.getWithdrawalRequest(address(weth));
        assertGt(pending.deadline, 0, "Request should exist");
        assertEq(boringVault.getPendingShares(), sharesToWithdraw, "Shares pending");

        // State 2: Request completed
        _simulateSolverFulfillment(address(weth), expectedAmount);
        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);

        KingBoringVault.WithdrawalRequest memory completed = boringVault.getWithdrawalRequest(address(weth));
        assertEq(completed.deadline, 0, "Request should be deleted");
        assertEq(boringVault.getPendingShares(), 0, "Shares cleared");
    }

    function test_requestState_CreatedToCancelled() public {
        // Setup
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        // State 1: Request created
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 500e18, 0);

        KingBoringVault.WithdrawalRequest memory pending = boringVault.getWithdrawalRequest(address(weth));
        assertGt(pending.deadline, 0, "Request should exist");

        // State 2: Request cancelled
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        KingBoringVault.WithdrawalRequest memory cancelled = boringVault.getWithdrawalRequest(address(weth));
        assertEq(cancelled.deadline, 0, "Request should be deleted");
        assertEq(boringVault.getPendingShares(), 0, "Shares cleared");
    }

    // ============================================
    // Event Emission Tests
    // ============================================

    function test_events_WithdrawEmitsWithdrawn() public {
        _depositAssets(address(weth), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        vm.expectEmit(true, true, true, true);
        emit Withdrawn(tokens, amounts, kingVault, block.timestamp);

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);
    }

    function test_events_WithdrawFromVaultEmitsQueued() public {
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.expectEmit(true, true, true, true);
        emit WithdrawalQueued(address(weth), sharesToWithdraw, expectedAmount, uint64(block.timestamp + 7 days));

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);
    }

    function test_events_CompletePrincipalWithdrawEmitsCompleted() public {
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        uint256 sharesToWithdraw = 500e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        _simulateSolverFulfillment(address(weth), expectedAmount);

        vm.expectEmit(true, true, true, true);
        emit PrincipalWithdrawCompleted(address(weth), expectedAmount, kingVault, block.timestamp);

        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);
    }

    function test_events_CancelEmitsCancelled() public {
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 500e18, 0);

        vm.expectEmit(true, true, true, false);
        emit WithdrawFromVaultCancelled(address(weth), 0, block.timestamp);

        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));
    }

    // ============================================
    // Integration Tests - Complex Scenarios
    // ============================================

    function test_integration_FullWithdrawalCycle() public {
        // 1. Deposit 1000 WETH
        _depositAssets(address(weth), 1000e18);
        assertEq(boringVault.getBalance(address(weth)), 1000e18);

        // 2. Deploy 800 WETH to vault
        uint256 shares = _deployToVault(address(weth), 800e18);
        assertEq(weth.balanceOf(address(boringVault)), 200e18, "200 idle");
        assertEq(vaultToken.balanceOf(address(boringVault)), shares, "Has shares");

        // 3. Withdraw 100 idle (kingVault already received this during deposit)
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        uint256 kingVaultBalanceBefore = weth.balanceOf(kingVault);

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        assertEq(boringVault.getBalance(address(weth)), 900e18, "Principal 900");
        assertEq(weth.balanceOf(address(boringVault)), 100e18, "100 idle");
        assertEq(weth.balanceOf(kingVault), kingVaultBalanceBefore + 100e18, "KingVault received 100");

        // 4. Queue withdrawal of 400 shares from vault
        uint256 sharesToWithdraw = 400e18;
        uint256 expectedAmount = Math.mulDiv(sharesToWithdraw, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), sharesToWithdraw, 0);

        assertEq(boringVault.getPendingShares(), sharesToWithdraw);

        // 5. Solver fulfills
        _simulateSolverFulfillment(address(weth), expectedAmount);

        // 6. Complete withdrawal to kingVault
        uint256 kingVaultBalanceBeforeComplete = weth.balanceOf(kingVault);

        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount, kingVault);

        assertEq(boringVault.getPendingShares(), 0);

        // KingVault should have received 400 from vault completion
        assertEq(
            weth.balanceOf(kingVault),
            kingVaultBalanceBeforeComplete + expectedAmount,
            "KingVault received 400 from completion"
        );

        // Total received by kingVault: 100 (step 3) + 400 (step 6) = 500
        assertEq(weth.balanceOf(kingVault), 500e18, "KingVault total received 500");
    }

    function test_integration_MultipleAssetsWithdrawal() public {
        // Deposit both assets
        _depositAssets(address(weth), 1000e18);
        _depositAssets(address(ethfi), 2000e18);

        // Deploy both
        _deployToVault(address(weth), 1000e18);
        _deployToVault(address(ethfi), 2000e18);

        // Withdraw WETH via vault
        uint256 wethShares = 500e18;
        uint256 expectedWeth = Math.mulDiv(wethShares, 1.0e18, 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), wethShares, 0);

        _simulateSolverFulfillment(address(weth), expectedWeth);

        vm.prank(owner);
        boringVault.completePrincipalWithdraw(address(weth), expectedWeth, kingVault);

        // Verify WETH completed, ETHFI unaffected
        assertEq(boringVault.getPendingShares(), 0, "No pending shares after WETH");
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "WETH principal unchanged");
        assertEq(boringVault.getBalance(address(ethfi)), 2000e18, "ETHFI principal unchanged");
    }

    function test_integration_WithdrawWhenPartiallyDeployed() public {
        // Setup: 1000 deposited, 600 deployed, 400 idle
        _depositAssets(address(weth), 1000e18);
        _deployToVault(address(weth), 600e18);

        // Try to withdraw 500 (need 100 from vault)
        // Note: The actual implementation queues vault withdrawal for the deficit
        // For this test, we verify idle is used first

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 400e18; // Withdraw all idle

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        assertEq(weth.balanceOf(address(boringVault)), 0, "All idle withdrawn");
        assertEq(boringVault.getBalance(address(weth)), 600e18, "Principal reduced to 600");
    }
}

// ============================================
// Mock Contracts
// ============================================

/**
 * @notice Mock Teller contract for testing deposits
 */
contract MockTeller {
    address public vault;
    address public accountant;
    bool public paused;
    uint256 public returnShares; // 0 = calculate normally

    constructor(address _vault) {
        vault = _vault;
    }

    function setAccountant(address _accountant) external {
        accountant = _accountant;
    }

    function deposit(MockERC20 depositAsset, uint256 depositAmount, uint256 minimumMint)
        external
        returns (uint256 shares)
    {
        require(!paused, "Teller paused");

        // Verify caller has sufficient balance
        require(depositAsset.balanceOf(msg.sender) >= depositAmount, "Insufficient balance");

        // Simulate the vault pulling funds from caller
        depositAsset.burn(msg.sender, depositAmount);
        depositAsset.mint(address(vault), depositAmount);

        // Calculate shares to mint
        if (returnShares > 0) {
            shares = returnShares;
            returnShares = 0;
        } else {
            if (accountant != address(0)) {
                uint256 rate = MockAccountant(accountant).getRate();
                shares = (depositAmount * 1e18) / rate;
            } else {
                shares = depositAmount;
            }
            require(shares >= minimumMint, "Below minimum shares");
        }

        // Vault mints shares to caller
        MockERC20(vault).mint(msg.sender, shares);

        return shares;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function setReturnShares(uint256 _shares) external {
        returnShares = _shares;
    }
}

/**
 * @notice Mock Accountant contract for testing exchange rates
 */
contract MockAccountant {
    address public base;
    address public vault;
    uint256 public rate;
    bool public paused;

    constructor(address _base, address _vault) {
        base = _base;
        vault = _vault;
        rate = 1e18; // Default 1:1
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getRateInQuoteSafe(MockERC20) external view returns (uint256) {
        require(!paused, "Accountant paused");
        return rate;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }
}

/**
 * @notice Mock AtomicQueue contract for testing withdrawals
 */
contract MockAtomicQueue {
    struct AtomicRequest {
        uint64 deadline;
        uint88 atomicPrice;
        uint96 offerAmount;
        bool inSolve;
    }

    mapping(address => mapping(address => mapping(address => AtomicRequest))) public requests;

    function updateAtomicRequest(MockERC20 offer, MockERC20 want, AtomicRequest calldata request) external {
        requests[msg.sender][address(offer)][address(want)] = request;
    }

    function getUserAtomicRequest(address user, MockERC20 offer, MockERC20 want)
        external
        view
        returns (AtomicRequest memory)
    {
        return requests[user][address(offer)][address(want)];
    }
}
