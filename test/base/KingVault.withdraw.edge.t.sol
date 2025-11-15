// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultWithdrawEdgeTest
 * @notice Edge case tests for withdrawal functions (Task 3.5)
 */
contract KingVaultWithdrawEdgeTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;

    MockERC20 public usdc; // 6 decimals
    MockERC20 public wbtc; // 8 decimals
    MockERC20 public weth; // 18 decimals
    MockERC20 public dai; // 18 decimals

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public priceProvider = address(0x3);
    address public receiver = address(0x5);

    function setUp() public {
        // Deploy implementation
        implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, priceProvider);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Deploy mock tokens with different decimals
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Register tokens as accepted
        address[] memory tokens = new address[](4);
        tokens[0] = address(usdc);
        tokens[1] = address(wbtc);
        tokens[2] = address(weth);
        tokens[3] = address(dai);
        bool[] memory accepted = new bool[](4);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;
        accepted[3] = true;

        vm.prank(owner);
        vault.registerTokens(tokens, accepted);

        // Mint tokens to kingVault
        usdc.mint(kingVault, 1_000_000e6); // 1M USDC
        wbtc.mint(kingVault, 100e8); // 100 WBTC
        weth.mint(kingVault, 1000e18); // 1000 WETH
        dai.mint(kingVault, 1_000_000e18); // 1M DAI

        // Approve vault to spend tokens
        vm.startPrank(kingVault);
        usdc.approve(address(vault), type(uint256).max);
        wbtc.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        dai.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================
    // Partial Withdrawal Tests
    // ============================================

    function test_Withdraw_PartialAmount() public {
        // Arrange - deposit tokens first
        address[] memory depositTokens = new address[](1);
        depositTokens[0] = address(usdc);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 10_000e6;

        vm.prank(kingVault);
        vault.deposit(depositTokens, depositAmounts);

        // Assert initial state
        assertEq(vault.getDeposits(address(usdc)), 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);

        // Act - withdraw partial amount (30%)
        address[] memory withdrawTokens = new address[](1);
        withdrawTokens[0] = address(usdc);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = 3_000e6; // 3k out of 10k

        vm.prank(kingVault);
        vault.withdraw(withdrawTokens, withdrawAmounts, receiver);

        // Assert partial withdrawal worked correctly
        assertEq(vault.getDeposits(address(usdc)), 7_000e6, "Deposits should be 7k (10k - 3k)");
        assertEq(usdc.balanceOf(address(vault)), 7_000e6, "Vault balance should be 7k");
        assertEq(usdc.balanceOf(receiver), 3_000e6, "Receiver should have 3k");

        // Act - withdraw another partial amount
        withdrawAmounts[0] = 2_000e6; // Another 2k
        vm.prank(kingVault);
        vault.withdraw(withdrawTokens, withdrawAmounts, receiver);

        // Assert second partial withdrawal
        assertEq(vault.getDeposits(address(usdc)), 5_000e6, "Deposits should be 5k (7k - 2k)");
        assertEq(usdc.balanceOf(address(vault)), 5_000e6, "Vault balance should be 5k");
        assertEq(usdc.balanceOf(receiver), 5_000e6, "Receiver should have 5k total");
    }

    function test_Withdraw_UpdatesDepositsCorrectly() public {
        // Arrange - deposit multiple tokens
        address[] memory depositTokens = new address[](3);
        depositTokens[0] = address(usdc);
        depositTokens[1] = address(weth);
        depositTokens[2] = address(dai);
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 50_000e6;
        depositAmounts[1] = 25e18;
        depositAmounts[2] = 100_000e18;

        vm.prank(kingVault);
        vault.deposit(depositTokens, depositAmounts);

        // Assert initial deposits
        assertEq(vault.getDeposits(address(usdc)), 50_000e6);
        assertEq(vault.getDeposits(address(weth)), 25e18);
        assertEq(vault.getDeposits(address(dai)), 100_000e18);

        // Act - withdraw varying amounts from each token
        address[] memory withdrawTokens = new address[](3);
        withdrawTokens[0] = address(usdc);
        withdrawTokens[1] = address(weth);
        withdrawTokens[2] = address(dai);
        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 10_000e6; // Withdraw 20% of USDC
        withdrawAmounts[1] = 15e18; // Withdraw 60% of WETH
        withdrawAmounts[2] = 75_000e18; // Withdraw 75% of DAI

        vm.prank(kingVault);
        vault.withdraw(withdrawTokens, withdrawAmounts, receiver);

        // Assert deposits updated correctly for each token
        assertEq(vault.getDeposits(address(usdc)), 40_000e6, "USDC deposits: 50k - 10k = 40k");
        assertEq(vault.getDeposits(address(weth)), 10e18, "WETH deposits: 25 - 15 = 10");
        assertEq(vault.getDeposits(address(dai)), 25_000e18, "DAI deposits: 100k - 75k = 25k");

        // Verify balances match deposits (no profit yet in these tests)
        assertEq(usdc.balanceOf(address(vault)), 40_000e6);
        assertEq(weth.balanceOf(address(vault)), 10e18);
        assertEq(dai.balanceOf(address(vault)), 25_000e18);
    }

    // ============================================
    // Different Token Decimals Tests
    // ============================================

    function test_Withdraw_DifferentDecimals() public {
        // Arrange - deposit tokens with different decimals
        address[] memory depositTokens = new address[](3);
        depositTokens[0] = address(usdc); // 6 decimals
        depositTokens[1] = address(wbtc); // 8 decimals
        depositTokens[2] = address(weth); // 18 decimals
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 10_000e6; // 10k USDC
        depositAmounts[1] = 5e8; // 5 WBTC
        depositAmounts[2] = 20e18; // 20 WETH

        vm.prank(kingVault);
        vault.deposit(depositTokens, depositAmounts);

        // Act - withdraw from all different decimal tokens
        address[] memory withdrawTokens = new address[](3);
        withdrawTokens[0] = address(usdc);
        withdrawTokens[1] = address(wbtc);
        withdrawTokens[2] = address(weth);
        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 3_000e6; // 3k USDC (6 decimals)
        withdrawAmounts[1] = 2e8; // 2 WBTC (8 decimals)
        withdrawAmounts[2] = 7e18; // 7 WETH (18 decimals)

        vm.prank(kingVault);
        vault.withdraw(withdrawTokens, withdrawAmounts, receiver);

        // Assert all decimal types handled correctly
        assertEq(vault.getDeposits(address(usdc)), 7_000e6, "6 decimal token: 10k - 3k = 7k");
        assertEq(vault.getDeposits(address(wbtc)), 3e8, "8 decimal token: 5 - 2 = 3");
        assertEq(vault.getDeposits(address(weth)), 13e18, "18 decimal token: 20 - 7 = 13");

        assertEq(usdc.balanceOf(receiver), 3_000e6, "Receiver got 3k USDC");
        assertEq(wbtc.balanceOf(receiver), 2e8, "Receiver got 2 WBTC");
        assertEq(weth.balanceOf(receiver), 7e18, "Receiver got 7 WETH");
    }

    // ============================================
    // Emergency Withdraw Edge Cases
    // ============================================

    function test_EmergencyWithdraw_WithSomeZeroBalances() public {
        // Arrange - deposit all tokens
        address[] memory depositTokens = new address[](4);
        depositTokens[0] = address(usdc);
        depositTokens[1] = address(wbtc);
        depositTokens[2] = address(weth);
        depositTokens[3] = address(dai);
        uint256[] memory depositAmounts = new uint256[](4);
        depositAmounts[0] = 10_000e6;
        depositAmounts[1] = 5e8;
        depositAmounts[2] = 20e18;
        depositAmounts[3] = 50_000e18;

        vm.prank(kingVault);
        vault.deposit(depositTokens, depositAmounts);

        // Act - withdraw some tokens completely (to create zero balances)
        address[] memory withdrawTokens = new address[](2);
        withdrawTokens[0] = address(usdc);
        withdrawTokens[1] = address(wbtc);
        uint256[] memory withdrawAmounts = new uint256[](2);
        withdrawAmounts[0] = 10_000e6; // Withdraw all USDC
        withdrawAmounts[1] = 5e8; // Withdraw all WBTC

        vm.prank(kingVault);
        vault.withdraw(withdrawTokens, withdrawAmounts, receiver);

        // Assert some tokens have zero balance
        assertEq(usdc.balanceOf(address(vault)), 0, "USDC balance is 0");
        assertEq(wbtc.balanceOf(address(vault)), 0, "WBTC balance is 0");
        assertEq(weth.balanceOf(address(vault)), 20e18, "WETH has balance");
        assertEq(dai.balanceOf(address(vault)), 50_000e18, "DAI has balance");

        uint256 kingVaultWethBefore = weth.balanceOf(kingVault);
        uint256 kingVaultDaiBefore = dai.balanceOf(kingVault);

        // Act - emergency withdraw (should only transfer tokens with balance > 0)
        vm.prank(owner);
        vault.emergencyWithdraw();

        // Assert only non-zero balance tokens transferred
        assertEq(usdc.balanceOf(address(vault)), 0, "USDC still 0");
        assertEq(wbtc.balanceOf(address(vault)), 0, "WBTC still 0");
        assertEq(weth.balanceOf(address(vault)), 0, "WETH transferred to kingVault");
        assertEq(dai.balanceOf(address(vault)), 0, "DAI transferred to kingVault");

        assertEq(weth.balanceOf(kingVault), kingVaultWethBefore + 20e18, "KingVault got WETH");
        assertEq(dai.balanceOf(kingVault), kingVaultDaiBefore + 50_000e18, "KingVault got DAI");

        // Assert all deposits reset (even zero balance tokens)
        assertEq(vault.getDeposits(address(usdc)), 0);
        assertEq(vault.getDeposits(address(wbtc)), 0);
        assertEq(vault.getDeposits(address(weth)), 0);
        assertEq(vault.getDeposits(address(dai)), 0);
    }
}
