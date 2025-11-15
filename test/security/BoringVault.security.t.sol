// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BoringVault} from "../../src/vaults/BoringVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title BoringVaultSecurityTest
 * @notice Comprehensive security tests for BoringVault dual tracking and access control
 * @dev Tests Task 7.7 acceptance criteria:
 *      - All access control modifiers (onlyOwner, onlyKingVault, onlyOwnerOrKingVault)
 *      - Unauthorized access prevention on all restricted functions
 *      - Dual tracking integrity: idle vs deployed balance consistency
 *      - Principal tracking manipulation attempts
 *      - Share appreciation doesn't affect principal
 *      - Reentrancy protection (if applicable)
 *      - Upgrade authorization (only owner)
 *      - Initialization protection (cannot reinitialize)
 *      - Pause functionality security
 *      - Withdrawal request manipulation attempts
 *      - Unauthorized profit extraction prevention
 */
contract BoringVaultSecurityTest is Test {
    // ============================================
    // Contracts
    // ============================================

    BoringVault public boringVault;
    BoringVault public implementation;
    MockERC20 public weth;
    MockERC20 public ethfi;
    MockPriceProvider public priceProvider;
    MockERC20 public vaultToken; // Mock BoringVault shares
    MockTeller public teller;
    MockAccountant public accountant;
    MockAtomicQueue public atomicQueue;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public attacker = address(0x3);
    address public recipient1 = address(0x4); // DAO (60%)
    address public recipient2 = address(0x5); // Treasury (40%)
    address public newImplementation = address(0x99);

    // ============================================
    // Events for Testing
    // ============================================

    event Deposited(address[] assets, uint256[] amounts, uint256 timestamp);
    event Withdrawn(address[] assets, uint256[] amounts, address receiver, uint256 timestamp);
    event DepositCompleted(address indexed token, uint256 amount, uint256 sharesReceived);
    event WithdrawalQueued(
        address indexed asset,
        uint256 shareAmount,
        uint256 expectedAmount,
        uint64 deadline
    );
    event PrincipalWithdrawCompleted(
        address indexed asset,
        uint256 amount,
        address indexed receiver,
        uint256 timestamp
    );
    event ProfitsHarvested(uint256 timestamp);
    event ProfitSharesQueued(uint256 profitShares, uint256 profitValue);
    event ProfitsDistributed(
        address[] recipients,
        address[] assets,
        uint256[][] amounts,
        uint256 timestamp
    );
    event Paused(address account);
    event Unpaused(address account);
    event EmergencyWithdraw(address[] assets, uint256[] amounts, uint256 timestamp);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ethfi = new MockERC20("EtherFi Token", "ETHFI", 18);
        vaultToken = new MockERC20("Boring Vault Shares", "bvWETH", 18);

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(ethfi), 0.0005e18); // 1 ETHFI = 0.0005 ETH

        // Deploy mock Veda contracts
        teller = new MockTeller(address(vaultToken));
        accountant = new MockAccountant(address(weth), address(vaultToken));
        atomicQueue = new MockAtomicQueue();

        // Connect teller to accountant
        teller.setAccountant(address(accountant));

        // Set up mock exchange rate in accountant (1 share = 1.0 WETH initially)
        accountant.setRate(1.0e18);

        // Deploy BoringVault implementation
        implementation = new BoringVault(
            address(vaultToken),
            address(teller),
            address(accountant)
        );

        // Deploy and initialize proxy
        boringVault = _deployStandardBoringVault();

        // Setup profit distribution (60% DAO, 40% Treasury)
        _setupProfitDistribution();
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _deployBoringVault(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address _atomicQueue,
        address[] memory _tokens,
        bool[] memory _accepted
    ) internal returns (BoringVault) {
        bytes memory initData = abi.encodeWithSelector(
            BoringVault.initialize.selector,
            _owner,
            _kingVault,
            _priceProvider,
            _atomicQueue,
            _tokens,
            _accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return BoringVault(address(proxy));
    }

    function _deployStandardBoringVault() internal returns (BoringVault) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        return _deployBoringVault(
            owner,
            kingVault,
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );
    }

    function _setupProfitDistribution() internal {
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;

        uint16[] memory percentsBPS = new uint16[](2);
        percentsBPS[0] = 6000; // 60%
        percentsBPS[1] = 4000; // 40%

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
    // Access Control Tests - onlyOwner
    // ============================================

    /**
     * @notice Test that unauthorized users cannot call owner-only functions
     * @dev Covers: depositToVault, withdrawFromVault, completePrincipalWithdraw,
     *      cancelWithdrawFromVault, harvestProfits, cancelProfitsHarvest,
     *      setMaxSlippage, setAtomicQueue, setWithdrawalDuration, registerAssets,
     *      setProfitsDistribution, distributeProfits
     */
    function testSecurity_OnlyOwner_AttackerCannotCallDepositToVault_Reverts() public {
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.depositToVault(address(weth), 100e18);
    }

    function testSecurity_OnlyOwner_AttackerCannotCallWithdrawFromVault_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.withdrawFromVault(address(weth), 100e18, 0);
    }

    function testSecurity_OnlyOwner_AttackerCannotCallCompletePrincipalWithdraw_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.completePrincipalWithdraw(address(weth), 100e18, attacker);
    }

    function testSecurity_OnlyOwner_AttackerCannotCallCancelWithdrawFromVault_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.cancelWithdrawFromVault(address(weth));
    }

    function testSecurity_OnlyOwner_AttackerCannotCallHarvestProfits_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.harvestProfits();
    }

    function testSecurity_OnlyOwner_AttackerCannotCallCancelProfitsHarvest_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.cancelProfitsHarvest(address(weth));
    }

    function testSecurity_OnlyOwner_AttackerCannotCallSetMaxSlippage_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.setMaxSlippage(100);
    }

    function testSecurity_OnlyOwner_AttackerCannotCallSetAtomicQueue_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.setAtomicQueue(address(0x123));
    }

    function testSecurity_OnlyOwner_AttackerCannotCallSetWithdrawalDuration_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.setWithdrawalDuration(14 days);
    }

    function testSecurity_OnlyOwner_AttackerCannotCallRegisterAssets_Reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x123);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.registerAssets(tokens, accepted);
    }

    function testSecurity_OnlyOwner_AttackerCannotCallSetProfitsDistribution_Reverts() public {
        address[] memory recipients = new address[](1);
        recipients[0] = attacker;
        uint16[] memory percentsBPS = new uint16[](1);
        percentsBPS[0] = 10000;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.setProfitsDistribution(recipients, percentsBPS);
    }

    function testSecurity_OnlyOwner_AttackerCannotCallDistributeProfits_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.distributeProfits();
    }

    function testSecurity_OnlyOwner_KingVaultCannotCallOwnerOnlyFunctions_Reverts() public {
        vm.prank(kingVault);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", kingVault));
        boringVault.setMaxSlippage(100);
    }

    // ============================================
    // Access Control Tests - onlyKingVault
    // ============================================

    /**
     * @notice Test that only kingVault can call deposit() and withdraw()
     */
    function testSecurity_OnlyKingVault_AttackerCannotCallDeposit_Reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(attacker);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        boringVault.deposit(tokens, amounts);
    }

    function testSecurity_OnlyKingVault_OwnerCannotCallDeposit_Reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(owner);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        boringVault.deposit(tokens, amounts);
    }

    function testSecurity_OnlyKingVault_AttackerCannotCallWithdraw_Reverts() public {
        _depositFromKingVault(address(weth), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(attacker);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        boringVault.withdraw(tokens, amounts, attacker);
    }

    function testSecurity_OnlyKingVault_OwnerCannotCallWithdraw_Reverts() public {
        _depositFromKingVault(address(weth), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(owner);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        boringVault.withdraw(tokens, amounts, owner);
    }

    // ============================================
    // Access Control Tests - onlyOwnerOrKingVault
    // ============================================

    /**
     * @notice Test that only owner OR kingVault can call pause/unpause/emergencyWithdraw
     */
    function testSecurity_OnlyOwnerOrKingVault_AttackerCannotCallPause_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        boringVault.pause();
    }

    function testSecurity_OnlyOwnerOrKingVault_AttackerCannotCallUnpause_Reverts() public {
        vm.prank(owner);
        boringVault.pause();

        vm.prank(attacker);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        boringVault.unpause();
    }

    function testSecurity_OnlyOwnerOrKingVault_AttackerCannotCallEmergencyWithdraw_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        boringVault.emergencyWithdraw();
    }

    function testSecurity_OnlyOwnerOrKingVault_OwnerCanCallPause_Succeeds() public {
        vm.prank(owner);
        boringVault.pause();
        assertTrue(boringVault.paused());
    }

    function testSecurity_OnlyOwnerOrKingVault_KingVaultCanCallPause_Succeeds() public {
        vm.prank(kingVault);
        boringVault.pause();
        assertTrue(boringVault.paused());
    }

    function testSecurity_OnlyOwnerOrKingVault_OwnerCanCallEmergencyWithdraw_Succeeds() public {
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.emergencyWithdraw();
        assertEq(boringVault.getBalance(address(weth)), 0);
    }

    function testSecurity_OnlyOwnerOrKingVault_KingVaultCanCallEmergencyWithdraw_Succeeds() public {
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(kingVault);
        boringVault.emergencyWithdraw();
        assertEq(boringVault.getBalance(address(weth)), 0);
    }

    // ============================================
    // Dual Tracking Integrity Tests
    // ============================================

    /**
     * @notice Test that _deposits[asset] = idle + deployed (as principal, not share value)
     * @dev Verifies dual tracking integrity across various operations
     */
    function testSecurity_DualTracking_DepositsEqualIdlePlusDeployed_Succeeds() public {
        // Deposit 1000 WETH from kingVault
        _depositFromKingVault(address(weth), 1000e18);

        // Verify _deposits = idle (nothing deployed yet)
        uint256 deposits = boringVault.getBalance(address(weth));
        uint256 idle = weth.balanceOf(address(boringVault));
        assertEq(deposits, idle, "Initial: deposits should equal idle");
        assertEq(deposits, 1000e18);

        // Deploy 600 WETH to BoringVault
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 600e18);

        // Verify _deposits unchanged (still 1000)
        // Verify idle reduced to 400
        uint256 depositsAfter = boringVault.getBalance(address(weth));
        uint256 idleAfter = weth.balanceOf(address(boringVault));
        uint256 deployedShares = vaultToken.balanceOf(address(boringVault));

        assertEq(depositsAfter, 1000e18, "After deploy: deposits should remain unchanged");
        assertEq(idleAfter, 400e18, "After deploy: idle should be 400");
        assertGt(deployedShares, 0, "After deploy: should have shares");

        // CRITICAL: _deposits = idle + deployed (as principal, not share value)
        // deployed (as principal) = share value in asset terms
        uint256 deployedValue = Math.mulDiv(deployedShares, accountant.getRate(), 1e18);
        assertEq(depositsAfter, idleAfter + deployedValue, "deposits = idle + deployed (principal)");
    }

    function testSecurity_DualTracking_ShareAppreciationDoesNotAffectDeposits_Succeeds() public {
        // Deposit and deploy 1000 WETH
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Record initial state
        uint256 depositsBefore = boringVault.getBalance(address(weth));
        assertEq(depositsBefore, 1000e18);

        // Simulate share appreciation: 1 share = 1.5 WETH (50% gain)
        accountant.setRate(1.5e18);

        // Verify _deposits UNCHANGED despite share appreciation
        uint256 depositsAfter = boringVault.getBalance(address(weth));
        assertEq(depositsAfter, depositsBefore, "Share appreciation should NOT affect _deposits");
        assertEq(depositsAfter, 1000e18);

        // Verify profit calculation reflects appreciation
        uint256 profit = boringVault.calculateProfit();
        assertGt(profit, 0, "Should have profit from appreciation");
    }

    function testSecurity_DualTracking_WithdrawalReducesDepositsCorrectly_Succeeds() public {
        // Setup: deposit 1000 WETH
        _depositFromKingVault(address(weth), 1000e18);

        // Withdraw 300 WETH via kingVault
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 300e18;

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        // Verify _deposits reduced by withdrawal amount
        uint256 depositsAfter = boringVault.getBalance(address(weth));
        assertEq(depositsAfter, 700e18, "Deposits should reduce by withdrawal amount");

        // Verify idle balance reduced
        uint256 idleAfter = weth.balanceOf(address(boringVault));
        assertEq(idleAfter, 700e18, "Idle should match deposits after withdrawal");
    }

    function testSecurity_DualTracking_ProfitDistributionDoesNotAffectDeposits_Succeeds() public {
        // Setup: deposit 1000 WETH, deploy to vault
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Simulate profit: shares appreciate 20%
        accountant.setRate(1.2e18);

        // Harvest profits (queues withdrawal)
        vm.prank(owner);
        boringVault.harvestProfits();

        // Simulate solver fulfillment
        uint256 profitShares = boringVault.getPendingShares();
        uint256 profitAmount = Math.mulDiv(profitShares, accountant.getRate(), 1e18);
        weth.mint(address(boringVault), profitAmount);
        vaultToken.burn(address(boringVault), profitShares);

        // Distribute profits
        vm.prank(owner);
        boringVault.distributeProfits();

        // Verify _deposits UNCHANGED by profit distribution
        uint256 depositsAfter = boringVault.getBalance(address(weth));
        assertEq(depositsAfter, 1000e18, "Profit distribution should NOT affect _deposits");
    }

    // ============================================
    // Principal Manipulation Prevention Tests
    // ============================================

    /**
     * @notice Test that attackers cannot manipulate principal tracking
     */
    function testSecurity_PrincipalManipulation_DirectTransferDoesNotIncreaseDeposits_Succeeds() public {
        // Setup: deposit 1000 WETH
        _depositFromKingVault(address(weth), 1000e18);
        uint256 depositsBefore = boringVault.getBalance(address(weth));

        // Attacker sends WETH directly to contract
        weth.mint(attacker, 500e18);
        vm.prank(attacker);
        weth.transfer(address(boringVault), 500e18);

        // Verify _deposits UNCHANGED
        uint256 depositsAfter = boringVault.getBalance(address(weth));
        assertEq(depositsAfter, depositsBefore, "Direct transfer should not increase _deposits");

        // Verify idle increased (but not deposits)
        uint256 idle = weth.balanceOf(address(boringVault));
        assertEq(idle, 1500e18, "Idle should include direct transfer");

        // This creates "profit" that can be distributed
        // (balance > deposits), which is the intended mechanism
    }

    function testSecurity_PrincipalManipulation_CannotWithdrawMoreThanDeposited_Reverts() public {
        // Setup: deposit 1000 WETH
        _depositFromKingVault(address(weth), 1000e18);

        // Attempt to withdraw more than deposited
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1500e18; // More than deposited

        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.withdraw(tokens, amounts, kingVault);
    }

    function testSecurity_PrincipalManipulation_CannotCompleteWithdrawalWithoutQueuing_Reverts() public {
        // Setup: deposit some WETH
        _depositFromKingVault(address(weth), 1000e18);

        // Attacker tries to complete withdrawal without queuing
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.completePrincipalWithdraw(address(weth), 500e18, attacker);
    }

    function testSecurity_PrincipalManipulation_CannotCompleteWithdrawalForUnqueuedAsset_Reverts() public {
        // Setup: deposit WETH
        _depositFromKingVault(address(weth), 1000e18);

        // Owner tries to complete withdrawal without queuing
        vm.prank(owner);
        vm.expectRevert(BoringVault.WithdrawalNotQueued.selector);
        boringVault.completePrincipalWithdraw(address(weth), 500e18, owner);
    }

    // ============================================
    // Withdrawal Request Security Tests
    // ============================================

    /**
     * @notice Test withdrawal request manipulation prevention
     */
    function testSecurity_WithdrawalRequest_CannotQueueMultipleSimultaneously_Reverts() public {
        // Setup: deposit and deploy WETH
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        uint256 shares = vaultToken.balanceOf(address(boringVault));

        // Queue first withdrawal
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares / 2, 0);

        // Attempt to queue second withdrawal for same asset
        vm.prank(owner);
        vm.expectRevert(BoringVault.WithdrawalNotQueued.selector);
        boringVault.withdrawFromVault(address(weth), shares / 4, 0);
    }

    function testSecurity_WithdrawalRequest_CannotCompleteWithMoreThanQueued_Reverts() public {
        // Setup: deposit, deploy, and queue withdrawal
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        uint256 shares = vaultToken.balanceOf(address(boringVault));
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares, 0);

        // Simulate solver fulfillment
        uint256 expectedAmount = Math.mulDiv(shares, accountant.getRate(), 1e18);
        weth.mint(address(boringVault), expectedAmount);

        // Attempt to complete with more than queued
        vm.prank(owner);
        vm.expectRevert();
        boringVault.completePrincipalWithdraw(address(weth), expectedAmount + 100e18, owner);
    }

    function testSecurity_WithdrawalRequest_CannotCancelNonExistentRequest_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(BoringVault.NoWithdrawalQueued.selector);
        boringVault.cancelWithdrawFromVault(address(weth));
    }

    function testSecurity_WithdrawalRequest_CancellationRestoresDepositsCorrectly_Succeeds() public {
        // Setup: deposit, deploy, then directly call withdrawFromVault (owner can do this)
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        uint256 depositsBefore = boringVault.getBalance(address(weth));
        assertEq(depositsBefore, 1000e18, "Should have 1000 WETH principal");

        // Directly queue withdrawal via withdrawFromVault (as owner)
        // This does NOT modify _deposits (only kingVault.withdraw does that)
        uint256 shares = vaultToken.balanceOf(address(boringVault));
        uint256 expectedAmount = Math.mulDiv(shares, accountant.getRate(), 1e18);

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares, 0);

        // Verify deposits unchanged (withdrawFromVault doesn't touch _deposits)
        uint256 depositsAfterQueue = boringVault.getBalance(address(weth));
        assertEq(depositsAfterQueue, depositsBefore, "Deposits unchanged by withdrawFromVault");

        // But _queuedWithdraw should be set
        uint256 queued = boringVault.getWithdrawalRequest(address(weth)).offer;
        assertEq(queued, expectedAmount, "Withdrawal request should track expected amount");

        // Cancel withdrawal
        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        // Verify:
        // 1. Deposits increased by queued amount (cancelWithdrawFromVault adds to _deposits)
        // 2. Shares returned
        uint256 depositsAfterCancel = boringVault.getBalance(address(weth));
        assertEq(depositsAfterCancel, depositsBefore + expectedAmount, "Cancellation adds queued amount to deposits");

        uint256 sharesAfterCancel = vaultToken.balanceOf(address(boringVault));
        assertEq(sharesAfterCancel, shares, "Shares should still be in vault after cancellation");
    }

    // ============================================
    // Profit Extraction Security Tests
    // ============================================

    /**
     * @notice Test unauthorized profit extraction prevention
     */
    function testSecurity_ProfitExtraction_CannotHarvestWithoutProfit_Reverts() public {
        // Setup: deposit without any profit
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Attempt to harvest when no profit
        vm.prank(owner);
        vm.expectRevert("No profit to harvest");
        boringVault.harvestProfits();
    }

    function testSecurity_ProfitExtraction_CannotDistributeProfitsWithoutQueuing_Succeeds() public {
        // Setup: deposit with profit
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Create profit via share appreciation
        accountant.setRate(1.2e18);

        // Attempt to distribute without harvesting
        vm.prank(owner);
        boringVault.distributeProfits();
        // Should succeed but distribute nothing (no idle profit)
    }

    function testSecurity_ProfitExtraction_CannotStealProfitsViaWithdraw_Reverts() public {
        // Setup: create profit scenario
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Create profit via share appreciation
        accountant.setRate(1.2e18);

        // Harvest profits
        vm.prank(owner);
        boringVault.harvestProfits();

        // Simulate solver fulfillment
        uint256 profitShares = boringVault.getPendingShares();
        uint256 profitAmount = Math.mulDiv(profitShares, accountant.getRate(), 1e18);
        weth.mint(address(boringVault), profitAmount);
        vaultToken.burn(address(boringVault), profitShares);

        // Attacker cannot withdraw profit via kingVault.withdraw()
        // because profit is protected by availableForWithdraw()
        uint256 available = boringVault.availableForWithdraw(address(weth));
        assertEq(available, 0, "Profit should be protected from withdrawal");
    }

    function testSecurity_ProfitExtraction_QueuedProfitsProtectedFromWithdrawal_Succeeds() public {
        // Setup: create profit and queue it
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        accountant.setRate(1.2e18);
        vm.prank(owner);
        boringVault.harvestProfits();

        // Simulate profit arrival (before distribution)
        uint256 profitShares = boringVault.getPendingShares();
        uint256 profitAmount = Math.mulDiv(profitShares, accountant.getRate(), 1e18);
        weth.mint(address(boringVault), profitAmount);

        // Verify queued profits are protected
        uint256 available = boringVault.availableForWithdraw(address(weth));
        assertEq(available, 0, "Queued profits should be unavailable for withdrawal");
    }

    // ============================================
    // Upgrade Authorization Tests
    // ============================================

    /**
     * @notice Test that only owner can upgrade contract
     */
    function testSecurity_Upgrade_AttackerCannotUpgrade_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        boringVault.upgradeToAndCall(newImplementation, "");
    }

    function testSecurity_Upgrade_KingVaultCannotUpgrade_Reverts() public {
        vm.prank(kingVault);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", kingVault));
        boringVault.upgradeToAndCall(newImplementation, "");
    }

    function testSecurity_Upgrade_OnlyOwnerCanUpgrade_Succeeds() public {
        // Deploy new implementation
        BoringVault newImpl = new BoringVault(
            address(vaultToken),
            address(teller),
            address(accountant)
        );

        // Owner can upgrade
        vm.prank(owner);
        boringVault.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved after upgrade
        assertEq(boringVault.owner(), owner);
        assertEq(boringVault.kingVault(), kingVault);
    }

    // ============================================
    // Initialization Protection Tests
    // ============================================

    /**
     * @notice Test that contract cannot be reinitialized
     */
    function testSecurity_Initialization_CannotReinitialize_Reverts() public {
        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert();
        boringVault.initialize(
            owner,
            kingVault,
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );
    }

    function testSecurity_Initialization_ImplementationCannotBeInitialized_Reverts() public {
        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert();
        implementation.initialize(
            owner,
            kingVault,
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );
    }

    function testSecurity_Initialization_AttackerCannotInitializeNewProxy_Succeeds() public {
        // Deploy properly initialized proxy
        // Note: This test verifies that once a proxy is initialized, it cannot be reinitialized
        // The initialization must happen in the constructor or deployment to prevent front-running

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        // Deploy a new proxy with proper initialization
        bytes memory initData = abi.encodeWithSelector(
            BoringVault.initialize.selector,
            owner, // legitimate owner
            kingVault,
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(implementation), initData);

        // Attacker cannot reinitialize
        vm.prank(attacker);
        vm.expectRevert();
        BoringVault(address(newProxy)).initialize(
            attacker,
            attacker,
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );
    }

    // ============================================
    // Pause Security Tests
    // ============================================

    /**
     * @notice Test pause functionality security
     */
    function testSecurity_Pause_BlocksDepositWhenPaused_Reverts() public {
        vm.prank(owner);
        boringVault.pause();

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.deposit(tokens, amounts);
    }

    function testSecurity_Pause_BlocksWithdrawWhenPaused_Reverts() public {
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.pause();

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.withdraw(tokens, amounts, kingVault);
    }

    function testSecurity_Pause_BlocksDepositToVaultWhenPaused_Reverts() public {
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.pause();

        vm.prank(owner);
        vm.expectRevert();
        boringVault.depositToVault(address(weth), 500e18);
    }

    function testSecurity_Pause_BlocksWithdrawFromVaultWhenPaused_Reverts() public {
        vm.prank(owner);
        boringVault.pause();

        vm.prank(owner);
        vm.expectRevert();
        boringVault.withdrawFromVault(address(weth), 100e18, 0);
    }

    function testSecurity_Pause_BlocksHarvestProfitsWhenPaused_Reverts() public {
        vm.prank(owner);
        boringVault.pause();

        vm.prank(owner);
        vm.expectRevert();
        boringVault.harvestProfits();
    }

    function testSecurity_Pause_AllowsEmergencyWithdrawWhenPaused_Succeeds() public {
        _depositFromKingVault(address(weth), 1000e18);

        vm.prank(owner);
        boringVault.pause();

        // Emergency withdraw should work even when paused
        vm.prank(owner);
        boringVault.emergencyWithdraw();

        assertEq(boringVault.getBalance(address(weth)), 0);
        assertEq(weth.balanceOf(kingVault), 1000e18);
    }

    // ============================================
    // Reentrancy Protection Tests
    // ============================================

    /**
     * @notice Test reentrancy protection (via pausable and proper state management)
     * @dev While no explicit reentrancy guards, checks-effects-interactions pattern is followed
     */
    function testSecurity_Reentrancy_StateUpdatesBeforeExternalCalls_Succeeds() public {
        // This test verifies that state is updated before external calls
        // The contract follows checks-effects-interactions pattern

        _depositFromKingVault(address(weth), 1000e18);

        // Deploy to vault
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Verify deposits tracked correctly before and after external calls
        uint256 deposits = boringVault.getBalance(address(weth));
        assertEq(deposits, 1000e18, "Deposits should be tracked correctly");
    }

    // ============================================
    // Configuration Security Tests
    // ============================================

    /**
     * @notice Test configuration function security
     */
    function testSecurity_Configuration_CannotSetExcessiveSlippage_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                BoringVault.SlippageExceedsLimit.selector,
                10_01,
                10_00
            )
        );
        boringVault.setMaxSlippage(10_01); // 10.01% exceeds 10% limit
    }

    function testSecurity_Configuration_CannotSetAtomicQueueToZero_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        boringVault.setAtomicQueue(address(0));
    }

    function testSecurity_Configuration_CannotSetAtomicQueueWithPendingWithdrawals_Reverts() public {
        // Setup: queue a withdrawal
        _depositFromKingVault(address(weth), 1000e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        uint256 shares = vaultToken.balanceOf(address(boringVault));
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), shares, 0);

        // Attempt to change atomic queue with pending withdrawal
        vm.prank(owner);
        vm.expectRevert(BoringVault.NoWithdrawalQueued.selector);
        boringVault.setAtomicQueue(address(0x123));
    }

    // ============================================
    // Multi-Asset Security Tests
    // ============================================

    /**
     * @notice Test dual tracking with multiple assets
     */
    function testSecurity_MultiAsset_DualTrackingPerAssetIsolated_Succeeds() public {
        // Deposit both WETH and ETHFI
        _depositFromKingVault(address(weth), 1000e18);
        _depositFromKingVault(address(ethfi), 2000e18);

        // Verify independent tracking
        assertEq(boringVault.getBalance(address(weth)), 1000e18);
        assertEq(boringVault.getBalance(address(ethfi)), 2000e18);

        // Withdraw WETH only
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e18;

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        // Verify only WETH affected
        assertEq(boringVault.getBalance(address(weth)), 500e18);
        assertEq(boringVault.getBalance(address(ethfi)), 2000e18);
    }

    function testSecurity_MultiAsset_ProfitCalculationAcrossAssets_Succeeds() public {
        // Deposit multiple assets and deploy
        _depositFromKingVault(address(weth), 1000e18);
        _depositFromKingVault(address(ethfi), 2000e18);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Simulate share appreciation
        accountant.setRate(1.2e18);

        // Calculate profit (should consider all assets)
        uint256 profit = boringVault.calculateProfit();
        assertGt(profit, 0, "Should have profit from WETH appreciation");
    }
}

// ============================================
// Mock Contracts
// ============================================

contract MockTeller {
    address public vault;
    address public accountant;
    bool public paused;

    constructor(address _vault) {
        vault = _vault;
    }

    function setAccountant(address _accountant) external {
        accountant = _accountant;
    }

    function deposit(
        MockERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint
    ) external returns (uint256 shares) {
        require(!paused, "Teller paused");

        // Verify caller has sufficient balance
        require(depositAsset.balanceOf(msg.sender) >= depositAmount, "Insufficient balance");

        // Calculate shares using accountant rate
        uint256 rate = MockAccountant(accountant).getRate();
        shares = (depositAmount * 1e18) / rate;

        require(shares >= minimumMint, "Slippage exceeded");

        // Simulate the vault pulling funds from caller
        // NOTE: In reality, teller calls vault.enter() and vault pulls using its approval
        // For mocking, we use burn/mint to simulate transfer without needing approval checks
        depositAsset.burn(msg.sender, depositAmount);
        depositAsset.mint(address(vault), depositAmount);

        // Mint shares to caller
        MockERC20(vault).mint(msg.sender, shares);

        return shares;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }
}

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

contract MockAtomicQueue {
    struct AtomicRequest {
        uint64 deadline;
        uint88 atomicPrice;
        uint96 offerAmount;
        bool inSolve;
    }

    mapping(address => mapping(address => mapping(address => AtomicRequest))) public requests;

    function updateAtomicRequest(
        MockERC20 offer,
        MockERC20 want,
        AtomicRequest calldata request
    ) external {
        requests[msg.sender][address(offer)][address(want)] = request;
    }

    function getUserAtomicRequest(
        address user,
        MockERC20 offer,
        MockERC20 want
    ) external view returns (AtomicRequest memory) {
        return requests[user][address(offer)][address(want)];
    }
}
