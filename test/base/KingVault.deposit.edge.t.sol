// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultDepositEdgeCaseTest
 * @notice Edge case tests for deposit() function (Task 2.4)
 */
contract KingVaultDepositEdgeCaseTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;

    MockERC20 public token6;   // 6 decimals (USDC-like)
    MockERC20 public token8;   // 8 decimals (WBTC-like)
    MockERC20 public token18;  // 18 decimals (WETH-like)

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public priceProvider = address(0x3);

    function setUp() public {
        // Deploy implementation
        implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            KingVaultHarness.initialize.selector,
            owner,
            kingVault,
            priceProvider
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Deploy mock tokens with different decimals
        token6 = new MockERC20("USDC", "USDC", 6);
        token8 = new MockERC20("WBTC", "WBTC", 8);
        token18 = new MockERC20("WETH", "WETH", 18);

        // Register tokens as accepted
        address[] memory tokens = new address[](3);
        tokens[0] = address(token6);
        tokens[1] = address(token8);
        tokens[2] = address(token18);
        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        vm.prank(owner);
        vault.registerTokens(tokens, accepted);

        // Mint large amounts to kingVault for edge case testing
        token6.mint(kingVault, type(uint128).max);   // Large but safe amount
        token8.mint(kingVault, type(uint128).max);
        token18.mint(kingVault, type(uint128).max);

        // Approve vault to spend tokens
        vm.startPrank(kingVault);
        token6.approve(address(vault), type(uint256).max);
        token8.approve(address(vault), type(uint256).max);
        token18.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================
    // Different Decimal Tests
    // ============================================

    function test_Deposit_DifferentDecimals() public {
        // Arrange - deposit tokens with 6, 8, and 18 decimals
        address[] memory tokens = new address[](3);
        tokens[0] = address(token6);
        tokens[1] = address(token8);
        tokens[2] = address(token18);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1_000_000e6;   // 1M USDC (6 decimals)
        amounts[1] = 50e8;          // 50 WBTC (8 decimals)
        amounts[2] = 100e18;        // 100 WETH (18 decimals)

        // Act
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Assert - each token tracks its amount in its native decimals
        assertEq(vault.getDeposits(address(token6)), 1_000_000e6);
        assertEq(vault.getDeposits(address(token8)), 50e8);
        assertEq(vault.getDeposits(address(token18)), 100e18);

        // Verify balances
        assertEq(token6.balanceOf(address(vault)), 1_000_000e6);
        assertEq(token8.balanceOf(address(vault)), 50e8);
        assertEq(token18.balanceOf(address(vault)), 100e18);
    }

    function test_Deposit_SmallAmountsWith6Decimals() public {
        // Arrange - test with very small amounts (1 unit = 0.000001 USDC)
        address[] memory tokens = new address[](1);
        tokens[0] = address(token6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1; // 1 smallest unit (0.000001 USDC)

        // Act
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Assert
        assertEq(vault.getDeposits(address(token6)), 1);
        assertEq(token6.balanceOf(address(vault)), 1);
    }

    // ============================================
    // Accumulation Tests
    // ============================================

    function test_Deposit_Accumulation() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        // First deposit
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
        assertEq(vault.getDeposits(address(token18)), 100e18);

        // Second deposit (should accumulate)
        amounts[0] = 50e18;
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
        assertEq(vault.getDeposits(address(token18)), 150e18);

        // Third deposit (should accumulate further)
        amounts[0] = 25e18;
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
        assertEq(vault.getDeposits(address(token18)), 175e18);

        // Verify total balance
        assertEq(token18.balanceOf(address(vault)), 175e18);
    }

    function test_Deposit_AccumulationMultiToken() public {
        // Arrange
        address[] memory tokens = new address[](2);
        tokens[0] = address(token6);
        tokens[1] = address(token18);
        uint256[] memory amounts = new uint256[](2);

        // First multi-token deposit
        amounts[0] = 1000e6;
        amounts[1] = 10e18;
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Second multi-token deposit (should accumulate both)
        amounts[0] = 500e6;
        amounts[1] = 5e18;
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Assert accumulation
        assertEq(vault.getDeposits(address(token6)), 1500e6);
        assertEq(vault.getDeposits(address(token18)), 15e18);
    }

    // ============================================
    // Large Value Tests (Overflow Protection)
    // ============================================

    function test_Deposit_LargeAmounts() public {
        // Arrange - use large but realistic amounts
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000_000_000e18; // 1 billion tokens

        // Act
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Assert
        assertEq(vault.getDeposits(address(token18)), 1_000_000_000e18);
    }

    function test_Deposit_AccumulationNoOverflow() public {
        // Arrange - test that accumulation works correctly up to practical limits
        // Note: Testing actual uint256.max overflow is impractical due to token minting limitations
        // Solidity 0.8+ provides built-in overflow protection, so we test accumulation behavior
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        uint256[] memory amounts = new uint256[](1);

        // First deposit: Large amount
        amounts[0] = 1_000_000_000_000e18; // 1 trillion tokens
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
        assertEq(vault.getDeposits(address(token18)), 1_000_000_000_000e18);

        // Second deposit: Accumulate more
        amounts[0] = 500_000_000_000e18; // 500 billion more
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Assert accumulation worked correctly
        assertEq(vault.getDeposits(address(token18)), 1_500_000_000_000e18);

        // Note: Solidity 0.8+ will automatically revert with Panic(0x11) if overflow occurs
        // This built-in protection ensures _deposits[token] += amount is safe
    }

    // ============================================
    // ERC20 Failure Tests
    // ============================================

    function test_Deposit_InsufficientApproval() public {
        // Arrange - create new token and mint but DON'T approve
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);
        newToken.mint(kingVault, 1000e18);

        // Register token
        address[] memory regTokens = new address[](1);
        regTokens[0] = address(newToken);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        vm.prank(owner);
        vault.registerTokens(regTokens, accepted);

        // Try to deposit without approval
        address[] memory tokens = new address[](1);
        tokens[0] = address(newToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        // Act & Assert - SafeERC20 will revert
        vm.prank(kingVault);
        vm.expectRevert();
        vault.deposit(tokens, amounts);
    }

    function test_Deposit_InsufficientBalance() public {
        // Arrange - try to deposit more than balance
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max; // More than minted

        // Act & Assert - SafeERC20 will revert due to insufficient balance
        vm.prank(kingVault);
        vm.expectRevert();
        vault.deposit(tokens, amounts);
    }

    function test_Deposit_PartialFailureInMultiToken() public {
        // Arrange - create scenario where second token transfer fails
        MockERC20 insufficientToken = new MockERC20("INSUF", "INSUF", 18);
        insufficientToken.mint(kingVault, 10e18); // Only 10 tokens

        // Register token
        address[] memory regTokens = new address[](1);
        regTokens[0] = address(insufficientToken);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        vm.prank(owner);
        vault.registerTokens(regTokens, accepted);

        vm.prank(kingVault);
        insufficientToken.approve(address(vault), type(uint256).max);

        // Try multi-token deposit where second token has insufficient balance
        address[] memory tokens = new address[](2);
        tokens[0] = address(token18);
        tokens[1] = address(insufficientToken);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;     // This should succeed
        amounts[1] = 100e18;     // This should fail (only 10 available)

        // Act & Assert - entire transaction should revert (atomicity)
        vm.prank(kingVault);
        vm.expectRevert();
        vault.deposit(tokens, amounts);

        // Verify NEITHER token was deposited (atomic revert)
        assertEq(vault.getDeposits(address(token18)), 0);
        assertEq(vault.getDeposits(address(insufficientToken)), 0);
    }
}
