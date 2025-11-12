// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title KingVaultIntegrationTest
 * @notice Comprehensive integration tests for KingVault contract
 * @dev Tests full workflows and multi-component interactions
 */
contract KingVaultIntegrationTest is Test {
    KingVaultHarness public implementation;
    KingVaultHarness public vault;
    MockPriceProvider public priceProvider;

    address public owner;
    address public kingVault;

    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;

    function setUp() public {
        // Setup test accounts
        owner = address(this);
        kingVault = address(0x1);

        // Deploy price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH

        // Deploy mock tokens with different decimals
        token1 = new MockERC20("Token1", "TK1", 18);
        token2 = new MockERC20("Token2", "TK2", 6);
        token3 = new MockERC20("Token3", "TK3", 8);

        // Set prices
        priceProvider.setPrice(address(token1), 1e18); // 1 token = 1 ETH
        priceProvider.setPrice(address(token2), 0.5e18); // 1 token = 0.5 ETH
        priceProvider.setPrice(address(token3), 2e18); // 1 token = 2 ETH

        // Deploy implementation
        implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Setup token balances for kingVault
        token1.mint(kingVault, 10000e18);
        token2.mint(kingVault, 10000e6);
        token3.mint(kingVault, 10000e8);

        // Approve vault to spend kingVault's tokens
        vm.startPrank(kingVault);
        token1.approve(address(vault), type(uint256).max);
        token2.approve(address(vault), type(uint256).max);
        token3.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================
    // Integration Test 1: Full Flow
    // ============================================

    function test_Integration_FullFlow_RegisterDepositWithdraw() public {
        // Step 1: Register tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token3);

        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        vault.registerAssets(tokens, accepted);

        // Verify tokens are registered
        address[] memory registeredAssets = vault.assets();
        assertEq(registeredAssets.length, 3);

        // Step 2: Deposit tokens
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18; // 100 TK1
        amounts[1] = 100e6; // 100 TK2
        amounts[2] = 100e8; // 100 TK3

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Verify deposits
        assertEq(vault.getDeposits(address(token1)), 100e18);
        assertEq(vault.getDeposits(address(token2)), 100e6);
        assertEq(vault.getDeposits(address(token3)), 100e8);

        // Step 3: Check TVL
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        // Expected: (100 * 1) + (100 * 0.5) + (100 * 2) = 350 ETH
        assertEq(ethValue, 350e18);
        // Expected: 350 ETH * $2000 = $700,000
        assertEq(usdValue, 700_000e18);

        // Step 4: Withdraw tokens
        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 50e18;
        withdrawAmounts[1] = 50e6;
        withdrawAmounts[2] = 50e8;

        vm.prank(kingVault);
        vault.withdraw(tokens, withdrawAmounts, kingVault);

        // Verify remaining deposits
        assertEq(vault.getDeposits(address(token1)), 50e18);
        assertEq(vault.getDeposits(address(token2)), 50e6);
        assertEq(vault.getDeposits(address(token3)), 50e8);

        // Verify TVL decreased
        (ethValue, usdValue) = vault.tvl();
        assertEq(ethValue, 175e18); // 350 / 2
        assertEq(usdValue, 350_000e18);
    }

    // ============================================
    // Integration Test 2: Emergency Flow
    // ============================================

    function test_Integration_DepositPauseEmergencyWithdraw() public {
        // Setup: Register and deposit
        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        vault.registerAssets(tokens, accepted);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 100e6;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Pause vault
        vault.pause();

        assertTrue(vault.paused());

        // Attempt normal withdraw (should fail)
        vm.expectRevert();
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);

        // Emergency withdraw (should work even when paused)
        uint256 beforeBalance1 = token1.balanceOf(kingVault);
        uint256 beforeBalance2 = token2.balanceOf(kingVault);

        vault.emergencyWithdraw();

        // Verify all tokens returned to kingVault
        assertEq(token1.balanceOf(kingVault), beforeBalance1 + 100e18);
        assertEq(token2.balanceOf(kingVault), beforeBalance2 + 100e6);

        // Verify deposits reset
        assertEq(vault.getDeposits(address(token1)), 0);
        assertEq(vault.getDeposits(address(token2)), 0);

        // Verify TVL is zero
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 0);
        assertEq(usdValue, 0);
    }

    // ============================================
    // Integration Test 3: Multi-Vault
    // ============================================

    function test_Integration_MultipleVaults() public {
        // Deploy second vault instance
        bytes memory initData = abi.encodeWithSelector(
            KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider)
        );

        ERC1967Proxy proxy2 = new ERC1967Proxy(address(implementation), initData);
        KingVaultHarness vault2 = KingVaultHarness(address(proxy2));

        // Approve vault2
        vm.prank(kingVault);
        token1.approve(address(vault2), type(uint256).max);

        // Register token in both vaults
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);
        vault2.registerAssets(tokens, accepted);

        // Deposit to both vaults
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        amounts[0] = 200e18;
        vm.prank(kingVault);
        vault2.deposit(tokens, amounts);

        // Verify independent tracking
        assertEq(vault.getDeposits(address(token1)), 100e18);
        assertEq(vault2.getDeposits(address(token1)), 200e18);

        // Verify TVL calculations
        (uint256 ethValue1,) = vault.tvl();
        (uint256 ethValue2,) = vault2.tvl();

        assertEq(ethValue1, 100e18);
        assertEq(ethValue2, 200e18);
    }

    // ============================================
    // Integration Test 4: TVL Tracking
    // ============================================

    function test_Integration_TVL_AfterDepositWithdraw() public {
        // Register tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token3);

        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        vault.registerAssets(tokens, accepted);

        // Initial TVL should be zero
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 0);
        assertEq(usdValue, 0);

        // Deposit token1
        address[] memory token1Array = new address[](1);
        token1Array[0] = address(token1);
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(token1Array, amounts1);

        (ethValue, usdValue) = vault.tvl();
        assertEq(ethValue, 100e18); // 100 * 1 ETH
        assertEq(usdValue, 200_000e18); // 100 ETH * $2000

        // Deposit token2
        address[] memory token2Array = new address[](1);
        token2Array[0] = address(token2);
        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = 100e6;

        vm.prank(kingVault);
        vault.deposit(token2Array, amounts2);

        (ethValue, usdValue) = vault.tvl();
        assertEq(ethValue, 150e18); // 100 + (100 * 0.5)
        assertEq(usdValue, 300_000e18);

        // Withdraw some token1
        amounts1[0] = 50e18;
        vm.prank(kingVault);
        vault.withdraw(token1Array, amounts1, kingVault);

        (ethValue, usdValue) = vault.tvl();
        assertEq(ethValue, 100e18); // 50 + (100 * 0.5)
        assertEq(usdValue, 200_000e18);
    }

    // ============================================
    // Integration Test 5: Registration Flow
    // ============================================

    function test_Integration_RegisterThenDeposit() public {
        // Initially no tokens registered
        address[] memory assets = vault.assets();
        assertEq(assets.length, 0);

        // Register token1
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // Verify token registered
        assets = vault.assets();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(token1));

        // Deposit should work
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        assertEq(vault.getDeposits(address(token1)), 100e18);

        // Register token2
        tokens[0] = address(token2);
        vault.registerAssets(tokens, accepted);

        // Deposit both tokens
        address[] memory bothTokens = new address[](2);
        bothTokens[0] = address(token1);
        bothTokens[1] = address(token2);

        uint256[] memory bothAmounts = new uint256[](2);
        bothAmounts[0] = 50e18;
        bothAmounts[1] = 100e6;

        vm.prank(kingVault);
        vault.deposit(bothTokens, bothAmounts);

        assertEq(vault.getDeposits(address(token1)), 150e18);
        assertEq(vault.getDeposits(address(token2)), 100e6);
    }

    // ============================================
    // Integration Test 6: Upgradeability
    // ============================================

    function test_Integration_Upgradeability() public {
        // Register and deposit
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Record state before upgrade
        uint256 depositsBefore = vault.getDeposits(address(token1));
        address kingVaultBefore = vault.kingVault();
        address priceProviderBefore = vault.priceProvider();
        address ownerBefore = vault.owner();
        (uint256 ethValueBefore, uint256 usdValueBefore) = vault.tvl();

        // Deploy new implementation
        KingVaultHarness newImplementation = new KingVaultHarness();

        // Upgrade (using UUPS upgradeToAndCall)
        vault.upgradeToAndCall(address(newImplementation), "");

        // Verify storage preserved after upgrade
        assertEq(vault.getDeposits(address(token1)), depositsBefore, "Deposits not preserved");
        assertEq(vault.kingVault(), kingVaultBefore, "kingVault not preserved");
        assertEq(vault.priceProvider(), priceProviderBefore, "priceProvider not preserved");
        assertEq(vault.owner(), ownerBefore, "owner not preserved");

        (uint256 ethValueAfter, uint256 usdValueAfter) = vault.tvl();
        assertEq(ethValueAfter, ethValueBefore, "ETH value not preserved");
        assertEq(usdValueAfter, usdValueBefore, "USD value not preserved");

        // Verify functionality still works
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        assertEq(vault.getDeposits(address(token1)), 200e18);
    }
}
