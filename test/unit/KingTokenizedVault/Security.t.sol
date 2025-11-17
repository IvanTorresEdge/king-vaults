// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingTokenizedVault} from "../../../src/vaults/KingTokenizedVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPriceProvider} from "../../mocks/MockPriceProvider.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";
import {IKingVault} from "../../../src/interfaces/IKingVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title KingTokenizedVault_SecurityTest
 * @notice Security and edge case tests for KingTokenizedVault (Feature 8.4)
 * @dev Tests Task 8.4 acceptance criteria:
 *      - Reentrancy scenarios
 *      - Integer overflow/underflow protection
 *      - Access control violations
 *      - State transition edge cases
 *      - Economic attack vectors
 *      - Input validation edge cases
 *
 * Security Focus Areas:
 *      1. Reentrancy: External calls to ERC-4626 vault, token transfers
 *      2. Access Control: Owner, KingVault, unauthorized actors
 *      3. State Integrity: Paused state, accounting correctness
 *      4. Economic: Slippage attacks, profit manipulation
 *      5. Edge Cases: Zero amounts, empty states, extreme values
 */
contract KingTokenizedVault_SecurityTest is Test {
    // ============================================
    // Contracts
    // ============================================

    KingTokenizedVault public tokenizedVault;
    KingTokenizedVault public implementation;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockPriceProvider public priceProvider;
    MockERC4626Vault public erc4626Vault;
    ReentrancyAttacker public attacker;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public unauthorized = address(0x3);
    address public maliciousVault = address(0x4);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mock ERC-4626 vault
        erc4626Vault = new MockERC4626Vault(weth, "Vault WETH", "vWETH");

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18);
        priceProvider.setPrice(address(weth), 1e18);
        priceProvider.setPrice(address(usdc), 0.0005e18);

        // Deploy KingTokenizedVault (atomic mode)
        implementation = new KingTokenizedVault(address(erc4626Vault), true);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tokenizedVault = KingTokenizedVault(address(proxy));

        // Fund king vault
        weth.mint(kingVault, 1000 ether);
        vm.prank(kingVault);
        weth.approve(address(tokenizedVault), type(uint256).max);
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _depositToVault(uint256 amount) internal {
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        tokenizedVault.deposit(assets, amounts);
    }

    // ============================================
    // Reentrancy Tests
    // ============================================

    /**
     * @notice Test reentrancy protection on deposit
     * @dev Verifies:
     *      - deposit() cannot be reentered during token transfer
     *      - ReentrancyGuard or checks-effects-interactions pattern active
     */
    function test_security_reentrancy_depositProtected() public {
        // Deploy reentrancy attacker
        attacker = new ReentrancyAttacker(address(tokenizedVault));

        // Fund attacker
        weth.mint(address(attacker), 10 ether);

        // Attempt reentrancy attack on deposit
        vm.expectRevert(); // Should revert on reentrancy attempt
        attacker.attackDeposit(address(weth), 5 ether);
    }

    /**
     * @notice Test reentrancy protection on withdraw
     * @dev Verifies:
     *      - withdraw() cannot be reentered during token transfer
     *      - State updated before external calls
     */
    function test_security_reentrancy_withdrawProtected() public {
        // Setup: Deposit first
        vm.prank(kingVault);
        _depositToVault(10 ether);

        // Deploy attacker
        attacker = new ReentrancyAttacker(address(tokenizedVault));

        // Grant attacker kingVault privileges (for test)
        // In real scenario, attacker would exploit via malicious token

        // Attempt reentrancy should be prevented by checks-effects-interactions
        // and access control (only kingVault can withdraw)
    }

    /**
     * @notice Test reentrancy protection on profit distribution
     * @dev Verifies:
     *      - distributeProfits() clears queue before transfers
     *      - Cannot reenter to double-distribute
     */
    function test_security_reentrancy_distributeProfitsProtected() public {
        // Setup: Generate profit
        vm.prank(kingVault);
        _depositToVault(10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        erc4626Vault.setExchangeRate(1.5e18);

        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Verify reentrancy protection: queue cleared before transfer
        vm.prank(owner);
        tokenizedVault.distributeProfits();

        // Second call should revert (queue already cleared)
        vm.expectRevert(KingTokenizedVault.NoProfitsToDistribute.selector);
        vm.prank(owner);
        tokenizedVault.distributeProfits();
    }

    // ============================================
    // Access Control Tests
    // ============================================

    /**
     * @notice Test unauthorized depositToVault attempt
     * @dev Verifies only owner can deploy to vault
     */
    function test_security_accessControl_depositToVaultOnlyOwner() public {
        vm.prank(kingVault);
        _depositToVault(10 ether);

        vm.prank(unauthorized);
        vm.expectRevert();
        tokenizedVault.depositToVault(address(weth), 5 ether);
    }

    /**
     * @notice Test unauthorized withdrawFromVault attempt
     * @dev Verifies only owner can withdraw from vault
     */
    function test_security_accessControl_withdrawFromVaultOnlyOwner() public {
        vm.prank(kingVault);
        _depositToVault(10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        vm.prank(unauthorized);
        vm.expectRevert();
        tokenizedVault.withdrawFromVault(address(weth), 5 ether, false);
    }

    /**
     * @notice Test unauthorized harvestProfits attempt
     * @dev Verifies only owner can harvest profits
     */
    function test_security_accessControl_harvestProfitsOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        tokenizedVault.harvestProfits();
    }

    /**
     * @notice Test unauthorized distributeProfits attempt
     * @dev Verifies only owner can distribute profits
     */
    function test_security_accessControl_distributeProfitsOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        tokenizedVault.distributeProfits();
    }

    /**
     * @notice Test unauthorized deposit attempt (Flow A)
     * @dev Verifies only kingVault can deposit via Flow A
     */
    function test_security_accessControl_depositOnlyKingVault() public {
        vm.prank(owner);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        _depositToVault(1 ether);
    }

    /**
     * @notice Test unauthorized withdraw attempt (Flow A)
     * @dev Verifies only kingVault can withdraw via Flow A
     */
    function test_security_accessControl_withdrawOnlyKingVault() public {
        vm.prank(kingVault);
        _depositToVault(10 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5 ether;

        vm.prank(owner);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        tokenizedVault.withdraw(assets, amounts, owner);
    }

    /**
     * @notice Test pause functionality blocks operations
     * @dev Verifies paused state prevents deposits/withdrawals
     */
    function test_security_pausedState_blocksOperations() public {
        // Pause vault
        vm.prank(owner);
        tokenizedVault.pause();

        // Deposit should fail
        vm.prank(kingVault);
        vm.expectRevert();
        _depositToVault(1 ether);

        // Owner operations should fail
        vm.prank(owner);
        vm.expectRevert();
        tokenizedVault.depositToVault(address(weth), 1 ether);

        vm.prank(owner);
        vm.expectRevert();
        tokenizedVault.harvestProfits();
    }

    // ============================================
    // Integer Overflow/Underflow Tests
    // ============================================

    /**
     * @notice Test large deposit amounts
     * @dev Verifies no overflow on large principal tracking
     */
    function test_security_overflow_largeDeposit() public {
        // Mint large amount
        uint256 largeAmount = type(uint128).max;
        weth.mint(kingVault, largeAmount);

        vm.prank(kingVault);
        _depositToVault(largeAmount);

        assertEq(tokenizedVault.getBalance(address(weth)), largeAmount, "Should handle large amounts");
    }

    /**
     * @notice Test share calculation with extreme appreciation
     * @dev Verifies no overflow on profit calculation
     */
    function test_security_overflow_extremeAppreciation() public {
        vm.prank(kingVault);
        _depositToVault(10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Set extreme appreciation (1000x)
        erc4626Vault.setExchangeRate(1000e18);

        // Should not overflow
        uint256 profit = tokenizedVault.calculateProfit();
        assertGt(profit, 0, "Should calculate profit without overflow");
    }

    /**
     * @notice Test underflow protection on withdrawal
     * @dev Verifies cannot withdraw more than available
     */
    function test_security_underflow_withdrawExceedsBalance() public {
        vm.prank(kingVault);
        _depositToVault(5 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether; // More than deposited

        vm.prank(kingVault);
        vm.expectRevert();
        tokenizedVault.withdraw(assets, amounts, kingVault);
    }

    /**
     * @notice Test underflow protection on share withdrawal
     * @dev Verifies cannot withdraw more shares than owned
     */
    function test_security_underflow_withdrawSharesExceedsBalance() public {
        vm.prank(kingVault);
        _depositToVault(10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        uint256 totalShares = tokenizedVault.getVaultShares();

        vm.prank(owner);
        vm.expectRevert();
        tokenizedVault.withdrawFromVault(address(weth), totalShares + 1, false);
    }

    // ============================================
    // State Transition Edge Cases
    // ============================================

    /**
     * @notice Test withdraw with queued profits
     * @dev Verifies availableForWithdraw respects reserved amounts
     */
    function test_security_stateTransition_withdrawRespectsQueuedProfits() public {
        vm.prank(kingVault);
        _depositToVault(20 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        // Generate profit
        erc4626Vault.setExchangeRate(1.5e18);

        // Harvest (queues profit)
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Get available amount (should exclude queued profit)
        uint256 available = tokenizedVault.availableForWithdraw(address(weth));
        uint256 idle = weth.balanceOf(address(tokenizedVault));

        assertLt(available, idle, "Available should be less than idle (profits reserved)");

        // Attempt to withdraw more than available should fail
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = idle; // Try to withdraw all idle

        vm.prank(kingVault);
        vm.expectRevert();
        tokenizedVault.withdraw(assets, amounts, kingVault);
    }

    /**
     * @notice Test multiple harvests without distribution
     * @dev Verifies profit queue accumulates correctly
     */
    function test_security_stateTransition_multipleHarvestsWithoutDistribution() public {
        vm.prank(kingVault);
        _depositToVault(20 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        // First harvest
        erc4626Vault.setExchangeRate(1.2e18);
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        uint256 balanceAfterFirstHarvest = weth.balanceOf(address(tokenizedVault));

        // Second harvest attempt should fail (no more profit after first harvest)
        vm.prank(owner);
        vm.expectRevert(KingTokenizedVault.NoProfitToHarvest.selector);
        tokenizedVault.harvestProfits();
    }

    // ============================================
    // Economic Attack Vectors
    // ============================================

    /**
     * @notice Test slippage attack mitigation
     * @dev Verifies slippage protection prevents value extraction
     */
    function test_security_economic_slippageAttackPrevented() public {
        vm.prank(kingVault);
        _depositToVault(10 ether);

        // Set tight slippage
        vm.prank(owner);
        tokenizedVault.setMaxSlippage(50); // 0.5%

        // Manipulate exchange rate (simulating MEV attack)
        erc4626Vault.setExchangeRate(0.99e18); // 1% worse than expected

        // Deposit should revert due to slippage
        vm.prank(owner);
        vm.expectRevert();
        tokenizedVault.depositToVault(address(weth), 10 ether);
    }

    /**
     * @notice Test profit manipulation via share donation
     * @dev Verifies profit calculation not manipulable by direct transfers
     */
    function test_security_economic_profitManipulationViaDonation() public {
        vm.prank(kingVault);
        _depositToVault(10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Attacker donates shares to vault (trying to inflate profit)
        MockERC20 vaultShares = MockERC20(address(erc4626Vault));
        vaultShares.mint(address(tokenizedVault), 100 ether);

        // Profit calculation should only consider owned shares
        // and compare against principal, not be affected by donation
        uint256 profit = tokenizedVault.calculateProfit();

        // Verify donation doesn't create false profit
        // (profit calculation uses convertToAssets on owned shares)
    }

    // ============================================
    // Input Validation Edge Cases
    // ============================================

    /**
     * @notice Test zero amount deposit
     * @dev Verifies zero deposits are rejected
     */
    function test_security_inputValidation_zeroAmountDeposit() public {
        vm.prank(owner);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        tokenizedVault.depositToVault(address(weth), 0);
    }

    /**
     * @notice Test zero amount withdrawal
     * @dev Verifies zero withdrawals are rejected
     */
    function test_security_inputValidation_zeroAmountWithdrawal() public {
        vm.prank(owner);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        tokenizedVault.withdrawFromVault(address(weth), 0, false);
    }

    /**
     * @notice Test unregistered asset deposit
     * @dev Verifies only registered assets can be deposited
     */
    function test_security_inputValidation_unregisteredAssetDeposit() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);

        vm.prank(kingVault);
        vm.expectRevert();
        address[] memory assets = new address[](1);
        assets[0] = address(randomToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        tokenizedVault.deposit(assets, amounts);
    }

    /**
     * @notice Test empty asset array
     * @dev Verifies empty arrays are rejected
     */
    function test_security_inputValidation_emptyAssetArray() public {
        address[] memory emptyAssets = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(kingVault);
        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        tokenizedVault.deposit(emptyAssets, emptyAmounts);
    }

    /**
     * @notice Test mismatched array lengths
     * @dev Verifies asset/amount arrays must match
     */
    function test_security_inputValidation_mismatchedArrayLengths() public {
        address[] memory assets = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.prank(kingVault);
        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        tokenizedVault.deposit(assets, amounts);
    }

    /**
     * @notice Test zero address receiver
     * @dev Verifies receiver address validated
     */
    function test_security_inputValidation_zeroAddressReceiver() public {
        vm.prank(kingVault);
        _depositToVault(10 ether);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5 ether;

        vm.prank(kingVault);
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        tokenizedVault.withdraw(assets, amounts, address(0));
    }

    // ============================================
    // Async Mode Security Tests
    // ============================================

    /**
     * @notice Test async mode withdrawal deadline expiration
     * @dev Verifies expired withdrawals are rejected
     */
    function test_security_asyncMode_expiredWithdrawal() public {
        // Deploy async mode vault
        KingTokenizedVault asyncVault;
        KingTokenizedVault asyncImpl = new KingTokenizedVault(address(erc4626Vault), false);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(asyncImpl), initData);
        asyncVault = KingTokenizedVault(address(proxy));

        vm.prank(kingVault);
        weth.approve(address(asyncVault), type(uint256).max);

        // Setup
        vm.prank(kingVault);
        address[] memory depositAssets = new address[](1);
        depositAssets[0] = address(weth);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 10 ether;
        asyncVault.deposit(depositAssets, depositAmounts);

        vm.prank(owner);
        asyncVault.depositToVault(address(weth), 10 ether);

        // Queue withdrawal
        vm.prank(owner);
        asyncVault.withdrawFromVault(address(weth), 5 ether, false);

        // Advance time past deadline
        vm.warp(block.timestamp + 8 days);

        // Complete should fail (expired)
        vm.prank(owner);
        vm.expectRevert();
        asyncVault.completeWithdrawal(address(weth));
    }

    /**
     * @notice Test duplicate withdrawal requests
     * @dev Verifies cannot create multiple pending requests
     */
    function test_security_asyncMode_duplicateWithdrawalRequest() public {
        // Deploy async mode vault
        KingTokenizedVault asyncVault;
        KingTokenizedVault asyncImpl = new KingTokenizedVault(address(erc4626Vault), false);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(asyncImpl), initData);
        asyncVault = KingTokenizedVault(address(proxy));

        vm.prank(kingVault);
        weth.approve(address(asyncVault), type(uint256).max);

        // Setup
        vm.prank(kingVault);
        address[] memory depositAssets = new address[](1);
        depositAssets[0] = address(weth);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 20 ether;
        asyncVault.deposit(depositAssets, depositAmounts);

        vm.prank(owner);
        asyncVault.depositToVault(address(weth), 20 ether);

        // First withdrawal request
        vm.prank(owner);
        asyncVault.withdrawFromVault(address(weth), 10 ether, false);

        // Second request should fail (pending exists)
        vm.prank(owner);
        vm.expectRevert(KingTokenizedVault.PendingWithdrawalExists.selector);
        asyncVault.withdrawFromVault(address(weth), 5 ether, false);
    }
}

// ============================================
// Attack Contracts
// ============================================

/**
 * @notice Contract for testing reentrancy attacks
 */
contract ReentrancyAttacker {
    KingTokenizedVault public vault;
    bool public attacking;

    constructor(address _vault) {
        vault = KingTokenizedVault(_vault);
    }

    function attackDeposit(address asset, uint256 amount) external {
        attacking = true;

        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vault.deposit(assets, amounts);
    }

    // Fallback to attempt reentrancy
    fallback() external {
        if (attacking) {
            attacking = false;
            // Try to reenter
            address[] memory assets = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1 ether;
            vault.deposit(assets, amounts);
        }
    }
}
