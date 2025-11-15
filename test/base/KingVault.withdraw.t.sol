// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultWithdrawTest
 * @notice Comprehensive tests for withdraw() function (Task 3.3)
 */
contract KingVaultWithdrawTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;

    MockERC20 public usdc; // 6 decimals
    MockERC20 public weth; // 18 decimals
    MockERC20 public dai; // 18 decimals

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public priceProvider = address(0x3);
    address public unauthorized = address(0x4);
    address public receiver = address(0x5);

    function setUp() public {
        // Deploy implementation
        implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, priceProvider);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Register tokens as accepted
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(dai);
        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        vm.prank(owner);
        vault.registerTokens(tokens, accepted);

        // Mint tokens to kingVault
        usdc.mint(kingVault, 1_000_000e6); // 1M USDC
        weth.mint(kingVault, 1000e18); // 1000 WETH
        dai.mint(kingVault, 1_000_000e18); // 1M DAI

        // Approve vault to spend tokens
        vm.startPrank(kingVault);
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        dai.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        // Deposit tokens to vault for withdrawal tests
        address[] memory depositTokens = new address[](3);
        depositTokens[0] = address(usdc);
        depositTokens[1] = address(weth);
        depositTokens[2] = address(dai);
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 10_000e6; // 10k USDC
        depositAmounts[1] = 10e18; // 10 WETH
        depositAmounts[2] = 10_000e18; // 10k DAI

        vm.prank(kingVault);
        vault.deposit(depositTokens, depositAmounts);
    }

    // ============================================
    // Happy Path Tests
    // ============================================

    function test_Withdraw_SingleToken() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5_000e6; // 5k USDC (partial withdrawal)

        // Assert initial state
        assertEq(vault.getDeposits(address(usdc)), 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(usdc.balanceOf(receiver), 0);

        // Act
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, receiver);

        // Assert final state
        assertEq(vault.getDeposits(address(usdc)), 5_000e6, "Deposits should decrement by withdrawn amount");
        assertEq(usdc.balanceOf(address(vault)), 5_000e6, "Vault balance should decrease");
        assertEq(usdc.balanceOf(receiver), 5_000e6, "Receiver should receive tokens");
    }

    function test_Withdraw_MultiToken() public {
        // Arrange
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(dai);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 3_000e6; // 3k USDC
        amounts[1] = 2e18; // 2 WETH
        amounts[2] = 5_000e18; // 5k DAI

        // Assert initial state
        assertEq(usdc.balanceOf(receiver), 0);
        assertEq(weth.balanceOf(receiver), 0);
        assertEq(dai.balanceOf(receiver), 0);

        // Act
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, receiver);

        // Assert final state
        assertEq(vault.getDeposits(address(usdc)), 7_000e6, "USDC deposits should decrement");
        assertEq(vault.getDeposits(address(weth)), 8e18, "WETH deposits should decrement");
        assertEq(vault.getDeposits(address(dai)), 5_000e18, "DAI deposits should decrement");

        assertEq(usdc.balanceOf(receiver), 3_000e6, "Receiver should get USDC");
        assertEq(weth.balanceOf(receiver), 2e18, "Receiver should get WETH");
        assertEq(dai.balanceOf(receiver), 5_000e18, "Receiver should get DAI");
    }

    function test_Withdraw_EmitsEvent() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;

        // Assert event emission
        vm.expectEmit(true, true, true, true);
        emit IKingVault.Withdrawn(tokens, amounts, receiver, block.timestamp);

        // Act
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, receiver);
    }

    // ============================================
    // Access Control Tests
    // ============================================

    function test_Withdraw_RevertsForUnauthorizedCaller() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;

        // Act & Assert
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        vault.withdraw(tokens, amounts, receiver);
    }

    function test_Withdraw_RevertsForOwner() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;

        // Act & Assert - owner cannot withdraw, only kingVault
        vm.prank(owner);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        vault.withdraw(tokens, amounts, receiver);
    }

    // ============================================
    // Pause Tests
    // ============================================

    function test_Withdraw_RevertsWhenPaused() public {
        // Arrange
        vm.prank(owner);
        vault.pause();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(); // PausableUpgradeable reverts with EnforcedPause()
        vault.withdraw(tokens, amounts, receiver);
    }

    // ============================================
    // Validation Tests
    // ============================================

    function test_Withdraw_RevertsForZeroAddress() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        vault.withdraw(tokens, amounts, address(0));
    }

    function test_Withdraw_RevertsForZeroAmount() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        vault.withdraw(tokens, amounts, receiver);
    }

    function test_Withdraw_RevertsForInsufficientBalance() public {
        // Arrange - try to withdraw more than available
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 20_000e6; // Trying to withdraw 20k but only 10k deposited

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(
            abi.encodeWithSelector(IKingVault.InsufficientBalance.selector, address(usdc), 20_000e6, 10_000e6)
        );
        vault.withdraw(tokens, amounts, receiver);
    }

    function test_Withdraw_RevertsForEmptyArrays() public {
        // Arrange
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        vault.withdraw(tokens, amounts, receiver);
    }

    function test_Withdraw_RevertsForMismatchedArrays() public {
        // Arrange
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        vault.withdraw(tokens, amounts, receiver);
    }
}
