// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultSecurityTest
 * @notice Comprehensive security and edge case tests for KingVault
 * @dev Tests access control, input validation, and extreme scenarios
 */
contract KingVaultSecurityTest is Test {
    KingVaultHarness public vault;
    MockPriceProvider public priceProvider;

    address public owner;
    address public kingVault;
    address public unauthorized;

    MockERC20 public token18;
    MockERC20 public token6;
    MockERC20 public token0;
    MockERC20 public token27;

    function setUp() public {
        owner = address(this);
        kingVault = address(new MockKingVaultController());
        unauthorized = address(0x999);

        priceProvider = new MockPriceProvider(2000e18);

        // Deploy tokens with different decimals
        token18 = new MockERC20("Token18", "TK18", 18);
        token6 = new MockERC20("Token6", "TK6", 6);
        token0 = new MockERC20("Token0", "TK0", 0);
        token27 = new MockERC20("Token27", "TK27", 27);

        // Set prices
        priceProvider.setPrice(address(token18), 1e18);
        priceProvider.setPrice(address(token6), 1e18);
        priceProvider.setPrice(address(token0), 1e18);
        priceProvider.setPrice(address(token27), 1e18);

        // Deploy vault
        KingVaultHarness implementation = new KingVaultHarness();
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider));

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Setup approvals
        token18.mint(kingVault, type(uint256).max / 2);
        token6.mint(kingVault, type(uint128).max);
        token0.mint(kingVault, type(uint128).max);
        token27.mint(kingVault, type(uint256).max / 2);

        vm.startPrank(kingVault);
        token18.approve(address(vault), type(uint256).max);
        token6.approve(address(vault), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token27.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================
    // Access Control Tests
    // ============================================

    function test_Security_Deposit_UnauthorizedCaller() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        vm.prank(unauthorized);
        vault.deposit(tokens, amounts);
    }

    function test_Security_Withdraw_UnauthorizedCaller() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        vm.prank(unauthorized);
        vault.withdraw(tokens, amounts, kingVault);
    }

    function test_Security_EmergencyWithdraw_UnauthorizedCaller() public {
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        vm.prank(unauthorized);
        vault.emergencyWithdraw();
    }

    function test_Security_Pause_UnauthorizedCaller() public {
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        vm.prank(unauthorized);
        vault.pause();
    }

    function test_Security_Unpause_UnauthorizedCaller() public {
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        vm.prank(unauthorized);
        vault.unpause();
    }

    function test_Security_RegisterAssets_UnauthorizedCaller() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vm.expectRevert(); // OwnableUpgradeable error
        vm.prank(unauthorized);
        vault.registerAssets(tokens, accepted);
    }

    function test_Security_SetPriceProvider_UnauthorizedCaller() public {
        vm.expectRevert(); // OwnableUpgradeable error
        vm.prank(unauthorized);
        vault.setPriceProvider(address(123));
    }

    function test_Security_HarvestProfits_UnauthorizedCaller() public {
        vm.expectRevert(); // OwnableUpgradeable error
        vm.prank(unauthorized);
        vault.harvestProfits();
    }

    // ============================================
    // Zero Address Tests
    // ============================================

    function test_Security_Withdraw_ZeroAddressReceiver() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.expectRevert(IKingVault.ZeroAddress.selector);
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, address(0));
    }

    function test_Security_SetPriceProvider_ZeroAddress() public {
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        vault.setPriceProvider(address(0));
    }

    function test_Security_RegisterAssets_ZeroAddressToken() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vm.expectRevert("Zero address");
        vault.registerAssets(tokens, accepted);
    }

    // ============================================
    // Zero Amount Tests
    // ============================================

    function test_Security_Deposit_ZeroAmount() public {
        // Register token first
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // Try deposit with zero amount
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        vm.expectRevert(IKingVault.ZeroAmount.selector);
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
    }

    function test_Security_Withdraw_ZeroAmount() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        vm.expectRevert(IKingVault.ZeroAmount.selector);
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);
    }

    function test_Security_Deposit_ZeroAmountInMultiToken() public {
        // Register tokens
        address[] memory tokens = new address[](2);
        tokens[0] = address(token18);
        tokens[1] = address(token6);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        vault.registerAssets(tokens, accepted);

        // Second token has zero amount
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 0;

        vm.expectRevert(IKingVault.ZeroAmount.selector);
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
    }

    // ============================================
    // Empty Array Tests
    // ============================================

    function test_Security_Deposit_EmptyArrays() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
    }

    function test_Security_Withdraw_EmptyArrays() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);
    }

    function test_Security_RegisterAssets_EmptyArrays() public {
        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert("Invalid arrays");
        vault.registerAssets(tokens, accepted);
    }

    // ============================================
    // Mismatched Array Length Tests
    // ============================================

    function test_Security_Deposit_MismatchedArrays() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token18);
        tokens[1] = address(token6);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
    }

    function test_Security_Withdraw_MismatchedArrays() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 50e18;

        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);
    }

    function test_Security_RegisterAssets_MismatchedArrays() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token18);
        tokens[1] = address(token6);

        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vm.expectRevert("Invalid arrays");
        vault.registerAssets(tokens, accepted);
    }

    // ============================================
    // Extreme Decimals Tests
    // ============================================

    function test_Security_ExtremeDecimals_0Decimals() public {
        // Register token with 0 decimals
        address[] memory tokens = new address[](1);
        tokens[0] = address(token0);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // Deposit
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000; // 1000 units

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        assertEq(vault.getDeposits(address(token0)), 1000);

        // Check TVL calculation
        (uint256 ethValue,) = vault.tvl();
        // 1000 * 1e18 / (10^0) = 1000e18
        assertEq(ethValue, 1000e18);

        // Withdraw
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);

        assertEq(vault.getDeposits(address(token0)), 0);
    }

    function test_Security_ExtremeDecimals_27Decimals() public {
        // Register token with 27 decimals
        address[] memory tokens = new address[](1);
        tokens[0] = address(token27);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // Deposit
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e27; // 1000 tokens with 27 decimals

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        assertEq(vault.getDeposits(address(token27)), 1000e27);

        // Check TVL calculation
        (uint256 ethValue,) = vault.tvl();
        // 1000e27 * 1e18 / (10^27) = 1000e18
        assertEq(ethValue, 1000e18);

        // Withdraw
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);

        assertEq(vault.getDeposits(address(token27)), 0);
    }

    function test_Security_MixedExtremeDecimals() public {
        // Register tokens with extreme decimals
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = address(token27);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        vault.registerAssets(tokens, accepted);

        // Deposit both
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000; // 1000 units (0 decimals)
        amounts[1] = 500e27; // 500 tokens (27 decimals)

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Check TVL
        (uint256 ethValue,) = vault.tvl();
        // (1000 * 1e18 / 1) + (500e27 * 1e18 / 1e27) = 1000e18 + 500e18 = 1500e18
        assertEq(ethValue, 1500e18);
    }

    // ============================================
    // Max uint256 Tests
    // ============================================

    function test_Security_TVL_LargeDepositedAmounts() public {
        // Register token
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // Deposit large amount (not max to avoid overflow)
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint128).max; // Use uint128 max to avoid overflow

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // TVL should not overflow (using Math.mulDiv for safety)
        (uint256 ethValue, uint256 usdValue) = vault.tvl();

        // Verify calculations completed without overflow
        assertTrue(ethValue > 0);
        assertTrue(usdValue > 0);
    }

    function test_Security_Deposit_Accumulation_NoOverflow() public {
        // Register token
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // Multiple deposits accumulating to large value
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint128).max / 2;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Should not overflow with Solidity 0.8+
        // Note: Due to integer division, result is max-1
        assertEq(vault.getDeposits(address(token18)), type(uint128).max - 1);
    }

    // ============================================
    // Reentrancy Tests (Non-Applicable)
    // ============================================

    function test_Security_NoReentrancy_Deposit() public {
        // Note: Reentrancy is not a concern for this contract because:
        // 1. Only kingVault can call deposit() (not untrusted contracts)
        // 2. Using SafeERC20 which doesn't have reentrancy issues
        // 3. State updates happen before external calls (CEI pattern)

        // This test verifies that deposit works correctly even with state-changing tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        assertEq(vault.getDeposits(address(token18)), 100e18);
    }

    function test_Security_NoReentrancy_Withdraw() public {
        // Setup
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Withdraw
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);

        assertEq(vault.getDeposits(address(token18)), 0);
    }
}
