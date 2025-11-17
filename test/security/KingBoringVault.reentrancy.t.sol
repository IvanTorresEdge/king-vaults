// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingBoringVault} from "../../src/vaults/KingBoringVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";
import {IAtomicQueue} from "../../src/interfaces/external/IAtomicQueue.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Import mock contracts from the security test file
import {MockTeller, MockAccountant, MockAtomicQueue} from "./KingBoringVault.security.t.sol";

/**
 * @title KingBoringVaultReentrancyTest
 * @notice Comprehensive reentrancy attack simulation tests for Task 4.1
 * @dev Tests CEI pattern fixes in cancelProfitsHarvest, cancelWithdrawFromVault, withdrawFromVault, and withdraw
 */
contract KingBoringVaultReentrancyTest is Test {
    // ============================================
    // Test Contracts
    // ============================================

    KingBoringVault public boringVault;
    KingBoringVault public implementation;
    MockERC20 public weth;
    MockERC20 public vaultToken;
    MockTeller public teller;
    MockAccountant public accountant;
    MaliciousAtomicQueue public maliciousQueue;
    MaliciousERC20 public maliciousToken;
    MaliciousTeller public maliciousTeller;
    MockPriceProvider public priceProvider;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public attacker = address(0x3);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        // Deploy standard tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vaultToken = new MockERC20("Boring Vault Shares", "bvWETH", 18);

        // Deploy price provider
        priceProvider = new MockPriceProvider(2000e18);
        priceProvider.setPrice(address(weth), 1e18);

        // Deploy mock Veda contracts
        teller = new MockTeller(address(vaultToken));
        accountant = new MockAccountant(address(weth), address(vaultToken));
        teller.setAccountant(address(accountant));
        accountant.setRate(1.0e18);

        // Deploy implementation
        implementation = new KingBoringVault(address(vaultToken), address(teller), address(accountant));

        // Deploy malicious contracts (will be set later)
        maliciousQueue = new MaliciousAtomicQueue(address(0)); // Set target later

        // Deploy proxy with standard atomic queue first
        MockAtomicQueue standardQueue = new MockAtomicQueue();
        boringVault = _deployKingBoringVault(owner, kingVault, address(priceProvider), address(standardQueue));

        // Update malicious queue target
        maliciousQueue = new MaliciousAtomicQueue(address(boringVault));

        // Setup profit distribution
        _setupProfitDistribution();
    }

    function _deployKingBoringVault(address _owner, address _kingVault, address _priceProvider, address _atomicQueue)
        internal
        returns (KingBoringVault)
    {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector, _owner, _kingVault, _priceProvider, _atomicQueue, tokens, accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return KingBoringVault(address(proxy));
    }

    function _setupProfitDistribution() internal {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x99);
        uint16[] memory percentsBPS = new uint16[](1);
        percentsBPS[0] = 10000;

        vm.prank(owner);
        boringVault.setProfitsDistribution(recipients, percentsBPS);
    }

    function _depositFromKingVault(address asset, uint256 amount) internal {
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

    // ============================================
    // Test 1: Reentrancy Attack on cancelProfitsHarvest
    // ============================================

    /**
     * @notice Test that reentrancy attack on cancelProfitsHarvest fails
     * @dev Attack vector: Malicious AtomicQueue reenters during updateAtomicRequest call
     * @dev Expected: CEI pattern prevents state corruption, attack fails gracefully
     */
    function test_ReentrancyAttack_CancelProfitsHarvest_Fails() public {
        // Setup: Deposit, deploy, create profit, harvest
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Create profit via share appreciation
        accountant.setRate(1.2e18);

        // Switch to malicious queue BEFORE harvest
        vm.prank(owner);
        boringVault.setAtomicQueue(address(maliciousQueue));

        // Harvest profits to queue withdrawal
        vm.prank(owner);
        boringVault.harvestProfits();

        // Configure attack
        maliciousQueue.setAttackType(1, address(weth)); // Type 1 = cancelProfitsHarvest

        // Get state before attack
        uint256 pendingSharesBefore = boringVault.getPendingShares();
        assertTrue(pendingSharesBefore > 0, "Should have pending shares before attack");

        // Execute cancellation (triggers reentrancy attempt in malicious queue)
        vm.prank(owner);
        boringVault.cancelProfitsHarvest(address(weth));

        // Verify state is consistent after attack
        uint256 pendingSharesAfter = boringVault.getPendingShares();
        assertEq(pendingSharesAfter, 0, "Pending shares should be cleared");

        // Verify attack was attempted but failed
        assertTrue(maliciousQueue.attackExecuted(), "Attack should have been attempted");

        // Verify withdrawal request was cleared
        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertEq(request.deadline, 0, "Withdrawal request should be cleared");
    }

    // ============================================
    // Test 2: Reentrancy Attack on cancelWithdrawFromVault
    // ============================================

    /**
     * @notice Test that reentrancy attack on cancelWithdrawFromVault fails
     * @dev Attack vector: Malicious AtomicQueue reenters during updateAtomicRequest call
     * @dev Expected: CEI pattern prevents double-cancellation, state remains consistent
     */
    function test_ReentrancyAttack_CancelWithdrawFromVault_Fails() public {
        // Setup: Deposit, deploy, queue withdrawal
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        uint256 shares = vaultToken.balanceOf(address(boringVault));

        // Switch to malicious queue BEFORE withdrawal
        vm.prank(owner);
        boringVault.setAtomicQueue(address(maliciousQueue));

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares, 0);

        // Configure attack
        maliciousQueue.setAttackType(2, address(weth)); // Type 2 = cancelWithdrawFromVault

        // Get deposits before
        uint256 depositsBefore = boringVault.getBalance(address(weth));

        // Execute cancellation (triggers reentrancy attempt)
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        // Verify state is consistent
        uint256 depositsAfter = boringVault.getBalance(address(weth));
        assertTrue(depositsAfter > depositsBefore, "Deposits should be restored");
        assertEq(boringVault.getPendingShares(), 0, "Pending shares should be cleared");

        // Verify attack was attempted
        assertTrue(maliciousQueue.attackExecuted(), "Attack should have been attempted");
    }

    // ============================================
    // Test 3: Reentrancy Attack on withdrawFromVault
    // ============================================

    /**
     * @notice Test that reentrancy attack on withdrawFromVault fails
     * @dev Attack vector: Malicious AtomicQueue reenters during updateAtomicRequest call
     * @dev Expected: CEI pattern prevents double-queuing, only one withdrawal request succeeds
     */
    function test_ReentrancyAttack_WithdrawFromVault_Fails() public {
        // Setup: Deposit and deploy
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Switch to malicious queue
        vm.prank(owner);
        boringVault.setAtomicQueue(address(maliciousQueue));

        // Configure attack
        maliciousQueue.setAttackType(3, address(weth)); // Type 3 = withdrawFromVault

        uint256 shares = vaultToken.balanceOf(address(boringVault));
        uint256 shareAmount = shares / 2;

        // Execute withdrawal (triggers reentrancy attempt)
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shareAmount, 0);

        // Verify only one withdrawal request exists
        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertTrue(request.deadline > 0, "Withdrawal request should exist");
        assertEq(request.want, shareAmount, "Should queue exactly the requested amount");

        // Verify pending shares match (not doubled)
        assertEq(boringVault.getPendingShares(), shareAmount, "Pending shares should match request");

        // Verify attack was attempted
        assertTrue(maliciousQueue.attackExecuted(), "Attack should have been attempted");
    }

    // ============================================
    // Test 4: Reentrancy Attack on withdraw() via Malicious ERC20
    // ============================================

    /**
     * @notice Test that reentrancy attack via malicious ERC20 token fails
     * @dev Attack vector: Malicious token reenters during safeTransfer callback
     * @dev Expected: CEI pattern updates deposits before transfer, preventing corruption
     */
    function test_ReentrancyAttack_WithdrawViaMaliciousToken_Fails() public {
        // Deploy malicious token
        maliciousToken = new MaliciousERC20("Malicious Token", "MAL");

        // Register malicious token
        priceProvider.setPrice(address(maliciousToken), 1e18);
        address[] memory tokens = new address[](1);
        tokens[0] = address(maliciousToken);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vm.prank(owner);
        boringVault.registerAssets(tokens, accepted);

        // Setup malicious token
        maliciousToken.setTarget(address(boringVault));
        maliciousToken.setAttackType(1); // Attack during transfer

        // Deposit malicious tokens
        maliciousToken.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        maliciousToken.approve(address(boringVault), 1000e18);

        address[] memory depositTokens = new address[](1);
        depositTokens[0] = address(maliciousToken);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1000e18;

        vm.prank(kingVault);
        boringVault.deposit(depositTokens, depositAmounts);

        // Get balance before withdrawal
        uint256 balanceBefore = boringVault.getBalance(address(maliciousToken));
        assertEq(balanceBefore, 1000e18, "Should have 1000 deposited");

        // Attempt withdrawal (triggers reentrancy in token transfer)
        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(maliciousToken);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = 500e18;

        vm.prank(kingVault);
        boringVault.withdraw(withdrawTokens, withdrawAmounts, kingVault);

        // Verify state is consistent (only one withdrawal succeeded)
        uint256 balanceAfter = boringVault.getBalance(address(maliciousToken));
        assertEq(balanceAfter, 500e18, "Should have 500 remaining");

        // Verify token transfer succeeded
        assertEq(maliciousToken.balanceOf(kingVault), 500e18, "KingVault should receive 500");

        // Verify attack was attempted but failed
        assertTrue(maliciousToken.attackExecuted(), "Attack should have been attempted");
    }

    // ============================================
    // Test 5: Cross-Function Reentrancy Attack
    // ============================================

    /**
     * @notice Test that cross-function reentrancy attack fails
     * @dev Attack vector: Enter via cancelProfitsHarvest, try to call withdrawFromVault
     * @dev Expected: Both functions protected by CEI pattern, attack fails
     */
    function test_ReentrancyAttack_CrossFunction_CancelToWithdraw_Fails() public {
        // Setup: Create profit and harvest
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        accountant.setRate(1.2e18);

        // Switch to malicious queue BEFORE harvest
        vm.prank(owner);
        boringVault.setAtomicQueue(address(maliciousQueue));

        vm.prank(owner);
        boringVault.harvestProfits();

        // Configure attack: try to call withdrawFromVault during cancelProfitsHarvest
        maliciousQueue.setAttackType(3, address(weth)); // Type 3 = withdrawFromVault

        // Execute cancellation (triggers cross-function reentrancy attempt)
        vm.prank(owner);
        boringVault.cancelProfitsHarvest(address(weth));

        // Verify state is consistent
        assertEq(boringVault.getPendingShares(), 0, "No pending shares after cancel");

        // Verify no new withdrawal request was created by attack
        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertEq(request.deadline, 0, "No withdrawal request should exist");

        assertTrue(maliciousQueue.attackExecuted(), "Attack should have been attempted");
    }

    // ============================================
    // Test 6: Double-Spend Attack via Reentrancy on withdrawFromVault
    // ============================================

    /**
     * @notice Test that double-spend attack via reentrancy fails
     * @dev Attack vector: Try to queue same shares twice during withdrawFromVault
     * @dev Expected: CEI pattern updates pending shares before external call, preventing double-spend
     */
    function test_ReentrancyAttack_DoubleSpend_WithdrawFromVault_Fails() public {
        // Setup
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        uint256 totalShares = vaultToken.balanceOf(address(boringVault));
        uint256 halfShares = totalShares / 2;

        // Switch to malicious queue
        vm.prank(owner);
        boringVault.setAtomicQueue(address(maliciousQueue));

        // Configure attack: try to withdraw again during withdrawFromVault
        maliciousQueue.setAttackType(3, address(weth));

        // Record shares before
        uint256 sharesBefore = totalShares;

        // Execute withdrawal (attack attempts to queue shares twice)
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), halfShares, 0);

        // Verify only half shares are pending (not doubled)
        assertEq(boringVault.getPendingShares(), halfShares, "Should queue exactly half shares");

        // Verify shares still in contract (not transferred yet)
        assertEq(vaultToken.balanceOf(address(boringVault)), sharesBefore, "Shares still in contract");

        assertTrue(maliciousQueue.attackExecuted(), "Attack should have been attempted");
    }

    // ============================================
    // Test 7: Double-Queue Attack via Reentrancy on Profit Harvest
    // ============================================

    /**
     * @notice Test that double-queue attack on profit harvest fails
     * @dev Attack vector: Try to harvest profits twice in one transaction
     * @dev Expected: State prevents second harvest attempt (no profit left)
     */
    function test_ReentrancyAttack_DoubleQueue_ProfitHarvest_Fails() public {
        // Setup: Create profit
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        accountant.setRate(1.2e18);

        // Switch to malicious queue before harvest
        vm.prank(owner);
        boringVault.setAtomicQueue(address(maliciousQueue));

        // Configure attack: try to harvest again during harvest
        maliciousQueue.setAttackType(1, address(weth)); // Will try cancelProfitsHarvest (closest to re-harvest)

        // Get profit before
        uint256 profitBefore = boringVault.calculateProfit();
        assertTrue(profitBefore > 0, "Should have profit");

        // Execute harvest (triggers reentrancy attempt)
        vm.prank(owner);
        boringVault.harvestProfits();

        // Verify only one harvest succeeded
        uint256 pendingShares = boringVault.getPendingShares();
        assertTrue(pendingShares > 0, "Should have pending shares from harvest");

        // Cancel to check queued amount
        vm.prank(owner);
        boringVault.cancelProfitsHarvest(address(weth));

        // Verify state is consistent
        assertEq(boringVault.getPendingShares(), 0, "Should be cleared after cancel");
    }

    // ============================================
    // Test 8: Multiple Simultaneous Reentrancy Vectors
    // ============================================

    /**
     * @notice Test that multiple reentrancy vectors all fail when tried sequentially
     * @dev Attack vector: Try withdrawFromVault, cancel, then try cancelWithdrawFromVault
     * @dev Expected: All attacks fail, state remains consistent throughout
     */
    function test_ReentrancyAttack_MultipleVectors_AllFail() public {
        // Setup: deposit and deploy
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        uint256 shares = vaultToken.balanceOf(address(boringVault));

        vm.prank(owner);
        boringVault.setAtomicQueue(address(maliciousQueue));

        // Attack 1: withdrawFromVault with reentrancy attempt
        maliciousQueue.setAttackType(3, address(weth));
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares / 4, 0);
        assertTrue(maliciousQueue.attackExecuted(), "Attack 1 attempted");

        // Verify only one withdrawal request created
        assertEq(boringVault.getPendingShares(), shares / 4, "Only queued shares/4");

        // Attack 2: cancelWithdrawFromVault with reentrancy attempt
        maliciousQueue.setAttackType(2, address(weth));
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        // Verify state clean after cancel with reentrancy attempt
        assertEq(boringVault.getPendingShares(), 0, "No pending shares after cancel");

        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertEq(request.deadline, 0, "No withdrawal request after cancel");

        // Attack 3: Try another withdrawal-cancel cycle with different attack vector
        maliciousQueue.setAttackType(4, address(weth)); // Type 4 = depositToVault
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares / 4, 0);

        // Cancel again
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        // Verify final state is consistent after all attacks
        assertEq(boringVault.getPendingShares(), 0, "No pending shares after all attacks");

        request = boringVault.getWithdrawalRequest(address(weth));
        assertEq(request.deadline, 0, "No withdrawal request after all attacks");

        // Verify shares still in vault (never stolen)
        uint256 finalShares = vaultToken.balanceOf(address(boringVault));
        assertEq(finalShares, shares, "All shares still in vault");
    }

    // ============================================
    // Test 9: State Consistency After Failed Reentrancy
    // ============================================

    /**
     * @notice Test that state remains consistent after failed reentrancy attack
     * @dev Verifies all state variables are correct after attack attempt
     */
    function test_ReentrancyAttack_StateConsistency_AfterFailedAttack() public {
        // Setup
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        uint256 initialDeposits = boringVault.getBalance(address(weth));
        uint256 shares = vaultToken.balanceOf(address(boringVault));

        vm.prank(owner);
        boringVault.setAtomicQueue(address(maliciousQueue));

        // Configure attack
        maliciousQueue.setAttackType(3, address(weth));

        // Execute operation that triggers attack
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares / 2, 0);

        // Verify state consistency
        assertEq(boringVault.getBalance(address(weth)), initialDeposits, "Deposits unchanged");
        assertEq(boringVault.getPendingShares(), shares / 2, "Pending shares correct");
        assertEq(vaultToken.balanceOf(address(boringVault)), shares, "Share balance unchanged");

        KingBoringVault.WithdrawalRequest memory request = boringVault.getWithdrawalRequest(address(weth));
        assertTrue(request.deadline > 0, "Request exists");
        assertEq(request.want, shares / 2, "Request amount correct");

        // Cancel and verify state cleanup
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        // After cancel, deposits should be restored
        uint256 depositsAfterCancel = boringVault.getBalance(address(weth));
        assertTrue(depositsAfterCancel > initialDeposits, "Deposits restored");
        assertEq(boringVault.getPendingShares(), 0, "Pending shares cleared");
    }

    // ============================================
    // Test 10: Reentrancy via Malicious Teller on Deposit
    // ============================================

    /**
     * @notice Test that reentrancy via malicious Teller fails
     * @dev Attack vector: Malicious Teller reenters during depositToVault
     * @dev Expected: Insufficient balance or state prevents double deposit
     */
    function test_ReentrancyAttack_MaliciousTeller_DepositToVault_Fails() public {
        // Deploy vault with malicious teller
        maliciousTeller = new MaliciousTeller(address(vaultToken));

        KingBoringVault testVault =
            new KingBoringVault(address(vaultToken), address(maliciousTeller), address(accountant));

        MockAtomicQueue queue = new MockAtomicQueue();

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector,
            owner,
            kingVault,
            address(priceProvider),
            address(queue),
            tokens,
            accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(testVault), initData);
        KingBoringVault vaultWithMaliciousTeller = KingBoringVault(address(proxy));

        // Setup profit distribution
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x99);
        uint16[] memory percentsBPS = new uint16[](1);
        percentsBPS[0] = 10000;

        vm.prank(owner);
        vaultWithMaliciousTeller.setProfitsDistribution(recipients, percentsBPS);

        // Configure malicious teller
        maliciousTeller.setTarget(address(vaultWithMaliciousTeller));

        // Deposit to vault
        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(vaultWithMaliciousTeller), 1000e18);

        address[] memory depositTokens = new address[](1);
        depositTokens[0] = address(weth);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1000e18;

        vm.prank(kingVault);
        vaultWithMaliciousTeller.deposit(depositTokens, depositAmounts);

        // Give malicious teller approval to transfer WETH (so attack can be attempted)
        uint256 idle = weth.balanceOf(address(vaultWithMaliciousTeller));
        vm.prank(address(vaultWithMaliciousTeller));
        weth.approve(address(maliciousTeller), idle);

        // Now try to deploy to malicious teller (triggers reentrancy)
        vm.prank(owner);
        vaultWithMaliciousTeller.depositToVault(address(weth), idle);

        // Verify attack was attempted
        assertTrue(maliciousTeller.attackExecuted(), "Attack should have been attempted");

        // Verify state is consistent (only one deposit succeeded)
        // The reentrancy attempt should fail due to insufficient balance
        assertEq(weth.balanceOf(address(vaultWithMaliciousTeller)), 0, "All WETH should be deployed");
    }
}

// ============================================
// Malicious Contracts for Reentrancy Attack Tests
// ============================================

/**
 * @notice Malicious AtomicQueue contract that attempts reentrancy during updateAtomicRequest()
 * @dev Simulates a compromised or malicious AtomicQueue trying to reenter vulnerable functions
 */
contract MaliciousAtomicQueue {
    address public targetVault;
    bool public attackExecuted;
    uint8 public attackType; // 1=cancelProfitsHarvest, 2=cancelWithdrawFromVault, 3=withdrawFromVault, 4=depositToVault
    address public attackAsset;

    // Track request for getUserAtomicRequest
    mapping(address => mapping(address => mapping(address => IAtomicQueue.AtomicRequest))) public requests;

    constructor(address _targetVault) {
        targetVault = _targetVault;
    }

    function setAttackType(uint8 _type, address _asset) external {
        attackType = _type;
        attackAsset = _asset;
        attackExecuted = false;
    }

    /**
     * @notice Malicious updateAtomicRequest that attempts reentrancy
     * @dev This is where the reentrancy attack happens during cancellation/withdrawal
     */
    function updateAtomicRequest(MockERC20 offer, MockERC20 want, IAtomicQueue.AtomicRequest calldata request)
        external
    {
        // Store the request for getUserAtomicRequest queries
        requests[msg.sender][address(offer)][address(want)] = request;

        // Attempt reentrancy if not already executed
        if (!attackExecuted && attackType > 0) {
            attackExecuted = true;

            if (attackType == 1) {
                // Attack 1: Reenter cancelProfitsHarvest during its external call
                try KingBoringVault(targetVault).cancelProfitsHarvest(attackAsset) {
                    // Should fail due to CEI pattern
                } catch {}
            } else if (attackType == 2) {
                // Attack 2: Reenter cancelWithdrawFromVault during its external call
                try KingBoringVault(targetVault).cancelWithdrawFromVault(attackAsset) {
                    // Should fail due to CEI pattern
                } catch {}
            } else if (attackType == 3) {
                // Attack 3: Reenter withdrawFromVault during its external call
                try KingBoringVault(targetVault).withdrawFromVault(attackAsset, 100e18, 0) {
                    // Should fail due to CEI pattern
                } catch {}
            } else if (attackType == 4) {
                // Attack 4: Reenter depositToVault during external call
                try KingBoringVault(targetVault).depositToVault(attackAsset, 100e18) {
                    // Should fail due to CEI pattern
                } catch {}
            }
        }
    }

    function getUserAtomicRequest(address user, MockERC20 offer, MockERC20 want)
        external
        view
        returns (IAtomicQueue.AtomicRequest memory)
    {
        return requests[user][address(offer)][address(want)];
    }
}

/**
 * @notice Malicious ERC20 token that attempts reentrancy during transfer callbacks
 * @dev Simulates a malicious token trying to exploit transfer operations
 */
contract MaliciousERC20 is MockERC20 {
    address public targetVault;
    bool public attackExecuted;
    uint8 public attackType;

    constructor(string memory name, string memory symbol) MockERC20(name, symbol, 18) {}

    function setTarget(address _targetVault) external {
        targetVault = _targetVault;
    }

    function setAttackType(uint8 _type) external {
        attackType = _type;
        attackExecuted = false;
    }

    /**
     * @notice Malicious transfer that attempts reentrancy
     * @dev Overrides transfer to inject attack logic
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Execute parent transfer first
        bool success = super.transfer(to, amount);

        // Attempt reentrancy if conditions met
        if (success && !attackExecuted && attackType > 0 && targetVault != address(0)) {
            attackExecuted = true;

            if (attackType == 1) {
                // Attack: Try to withdraw again during withdrawal
                address[] memory tokens = new address[](1);
                tokens[0] = address(this);
                uint256[] memory amounts = new uint256[](1);
                amounts[0] = 50e18;

                try KingBoringVault(targetVault).withdraw(tokens, amounts, msg.sender) {
                    // Should fail
                } catch {}
            } else if (attackType == 2) {
                // Attack: Try to deposit during withdrawal
                address[] memory tokens = new address[](1);
                tokens[0] = address(this);
                uint256[] memory amounts = new uint256[](1);
                amounts[0] = 50e18;

                try KingBoringVault(targetVault).deposit(tokens, amounts) {
                    // Should fail
                } catch {}
            }
        }

        return success;
    }

    /**
     * @notice Malicious transferFrom that attempts reentrancy
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);

        // Similar reentrancy logic as transfer
        if (success && !attackExecuted && attackType > 0 && targetVault != address(0)) {
            attackExecuted = true;

            if (attackType == 3) {
                // Attack: Try to emergency withdraw during deposit
                try KingBoringVault(targetVault).emergencyWithdraw() {
                    // Should fail if paused or access control works
                } catch {}
            }
        }

        return success;
    }
}

/**
 * @notice Malicious Teller contract that attempts reentrancy during deposit
 * @dev Simulates a compromised Teller trying to exploit depositToVault
 */
contract MaliciousTeller {
    address public vault;
    address public targetBoringVault;
    bool public attackExecuted;

    constructor(address _vault) {
        vault = _vault;
    }

    function setTarget(address _target) external {
        targetBoringVault = _target;
    }

    /**
     * @notice Malicious deposit that attempts reentrancy
     */
    function deposit(MockERC20 depositAsset, uint256 depositAmount, uint256) external returns (uint256 shares) {
        // Calculate shares (1:1 for simplicity)
        shares = depositAmount;

        // Transfer asset from caller
        depositAsset.transferFrom(msg.sender, address(this), depositAmount);

        // Mint shares to caller
        MockERC20(vault).mint(msg.sender, shares);

        // Attempt reentrancy during deposit operation
        if (!attackExecuted && targetBoringVault != address(0)) {
            attackExecuted = true;

            // Try to call depositToVault again (double-spend attack)
            try KingBoringVault(targetBoringVault).depositToVault(address(depositAsset), depositAmount / 2) {
                // Should fail due to insufficient balance or CEI pattern
            } catch {}
        }

        return shares;
    }

    function isPaused() external pure returns (bool) {
        return false;
    }
}
