// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultEmergencyWithdrawTest
 * @notice Comprehensive tests for emergencyWithdraw() function (Task 3.4)
 */
contract KingVaultEmergencyWithdrawTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;

    MockERC20 public usdc; // 6 decimals
    MockERC20 public weth; // 18 decimals
    MockERC20 public dai; // 18 decimals

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public priceProvider = address(0x3);
    address public unauthorized = address(0x4);

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

        // Deposit tokens to vault for emergency withdrawal tests
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

    function test_EmergencyWithdraw_ReturnsAllIdleBalances() public {
        // Assert initial state
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(weth.balanceOf(address(vault)), 10e18);
        assertEq(dai.balanceOf(address(vault)), 10_000e18);
        assertEq(vault.getDeposits(address(usdc)), 10_000e6);
        assertEq(vault.getDeposits(address(weth)), 10e18);
        assertEq(vault.getDeposits(address(dai)), 10_000e18);

        uint256 kingVaultUsdcBefore = usdc.balanceOf(kingVault);
        uint256 kingVaultWethBefore = weth.balanceOf(kingVault);
        uint256 kingVaultDaiBefore = dai.balanceOf(kingVault);

        // Act
        vm.prank(owner);
        vault.emergencyWithdraw();

        // Assert all balances returned to kingVault
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault USDC should be 0");
        assertEq(weth.balanceOf(address(vault)), 0, "Vault WETH should be 0");
        assertEq(dai.balanceOf(address(vault)), 0, "Vault DAI should be 0");

        assertEq(usdc.balanceOf(kingVault), kingVaultUsdcBefore + 10_000e6, "KingVault should receive USDC");
        assertEq(weth.balanceOf(kingVault), kingVaultWethBefore + 10e18, "KingVault should receive WETH");
        assertEq(dai.balanceOf(kingVault), kingVaultDaiBefore + 10_000e18, "KingVault should receive DAI");
    }

    function test_EmergencyWithdraw_ResetsDepositedAmounts() public {
        // Assert initial state
        assertEq(vault.getDeposits(address(usdc)), 10_000e6);
        assertEq(vault.getDeposits(address(weth)), 10e18);
        assertEq(vault.getDeposits(address(dai)), 10_000e18);

        // Act
        vm.prank(owner);
        vault.emergencyWithdraw();

        // Assert deposits reset to 0
        assertEq(vault.getDeposits(address(usdc)), 0, "USDC deposits should be reset");
        assertEq(vault.getDeposits(address(weth)), 0, "WETH deposits should be reset");
        assertEq(vault.getDeposits(address(dai)), 0, "DAI deposits should be reset");
    }

    function test_EmergencyWithdraw_WorksWhenPaused() public {
        // Arrange - pause the vault
        vm.prank(owner);
        vault.pause();

        // Assert paused
        assertTrue(vault.paused(), "Vault should be paused");

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 kingVaultUsdcBefore = usdc.balanceOf(kingVault);

        // Act - emergency withdraw should work even when paused
        vm.prank(owner);
        vault.emergencyWithdraw();

        // Assert emergency withdraw succeeded despite pause
        assertEq(usdc.balanceOf(address(vault)), 0, "Emergency withdraw worked while paused");
        assertEq(usdc.balanceOf(kingVault), kingVaultUsdcBefore + vaultUsdcBefore, "Tokens transferred");
    }

    function test_EmergencyWithdraw_EmitsEvent() public {
        // Arrange - prepare expected event data
        address[] memory expectedTokens = new address[](3);
        expectedTokens[0] = address(usdc);
        expectedTokens[1] = address(weth);
        expectedTokens[2] = address(dai);
        uint256[] memory expectedAmounts = new uint256[](3);
        expectedAmounts[0] = 10_000e6;
        expectedAmounts[1] = 10e18;
        expectedAmounts[2] = 10_000e18;

        // Assert event emission
        vm.expectEmit(true, true, true, true);
        emit IKingVault.EmergencyWithdraw(expectedTokens, expectedAmounts, block.timestamp);

        // Act
        vm.prank(owner);
        vault.emergencyWithdraw();
    }

    // ============================================
    // Access Control Tests
    // ============================================

    function test_EmergencyWithdraw_CallableByOwner() public {
        // Act - owner can call
        vm.prank(owner);
        vault.emergencyWithdraw();

        // Assert
        assertEq(usdc.balanceOf(address(vault)), 0, "Owner successfully called emergency withdraw");
        assertEq(usdc.balanceOf(kingVault) > 0, true, "Tokens transferred to kingVault");
    }

    function test_EmergencyWithdraw_CallableByKingVault() public {
        // Act - kingVault can call
        vm.prank(kingVault);
        vault.emergencyWithdraw();

        // Assert
        assertEq(usdc.balanceOf(address(vault)), 0, "KingVault successfully called emergency withdraw");
    }

    function test_EmergencyWithdraw_RevertsForUnauthorizedCaller() public {
        // Act & Assert
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        vault.emergencyWithdraw();
    }

    // ============================================
    // Edge Case Tests
    // ============================================

    function test_EmergencyWithdraw_WithSomeZeroBalances() public {
        // Arrange - withdraw some tokens to create zero balances
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10_000e6; // Withdraw all USDC
        amounts[1] = 10e18; // Withdraw all WETH

        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);

        // Assert state before emergency withdraw
        assertEq(usdc.balanceOf(address(vault)), 0, "USDC balance is 0");
        assertEq(weth.balanceOf(address(vault)), 0, "WETH balance is 0");
        assertEq(dai.balanceOf(address(vault)), 10_000e18, "DAI balance remains");

        uint256 kingVaultDaiBefore = dai.balanceOf(kingVault);

        // Act - emergency withdraw with some zero balances
        vm.prank(owner);
        vault.emergencyWithdraw();

        // Assert only DAI was transferred (USDC and WETH skipped)
        assertEq(dai.balanceOf(address(vault)), 0, "DAI transferred");
        assertEq(dai.balanceOf(kingVault), kingVaultDaiBefore + 10_000e18, "KingVault received DAI");
        assertEq(vault.getDeposits(address(dai)), 0, "DAI deposits reset");
    }
}
