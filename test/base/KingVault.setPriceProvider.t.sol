// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title KingVaultSetPriceProviderTest
 * @notice Comprehensive test suite for setPriceProvider() function
 */
contract KingVaultSetPriceProviderTest is Test {
    KingVaultHarness public vault;
    MockPriceProvider public priceProvider1;
    MockPriceProvider public priceProvider2;
    MockERC20 public token;

    address public owner;
    address public kingVault;
    address public unauthorized;

    event PriceProviderUpdated(address oldPriceProvider, address newPriceProvider);

    function setUp() public {
        // Setup test accounts
        owner = address(this);
        kingVault = address(0x1);
        unauthorized = address(0x2);

        // Deploy price providers with different ETH/USD prices
        priceProvider1 = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider2 = new MockPriceProvider(2100e18); // $2100 per ETH

        // Deploy test token
        token = new MockERC20("Test Token", "TEST", 18);

        // Set price for token in first provider
        priceProvider1.setPrice(address(token), 1e18); // 1 token = 1 ETH

        // Deploy vault implementation
        KingVaultHarness implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider1));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Register token
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        vault.registerAssets(tokens, accepted);
    }

    // ============================================
    // Positive Tests
    // ============================================

    function test_SetPriceProvider_UpdatesAddress() public {
        // Verify initial state
        assertEq(vault.priceProvider(), address(priceProvider1));

        // Update price provider
        vault.setPriceProvider(address(priceProvider2));

        // Verify updated
        assertEq(vault.priceProvider(), address(priceProvider2));
    }

    function test_SetPriceProvider_EmitsEvent() public {
        // Expect event with old and new addresses
        vm.expectEmit(true, true, false, false);
        emit PriceProviderUpdated(address(priceProvider1), address(priceProvider2));

        vault.setPriceProvider(address(priceProvider2));
    }

    function test_SetPriceProvider_AllowsMultipleUpdates() public {
        // First update
        vault.setPriceProvider(address(priceProvider2));
        assertEq(vault.priceProvider(), address(priceProvider2));

        // Second update back to original
        vault.setPriceProvider(address(priceProvider1));
        assertEq(vault.priceProvider(), address(priceProvider1));

        // Third update
        vault.setPriceProvider(address(priceProvider2));
        assertEq(vault.priceProvider(), address(priceProvider2));
    }

    function test_SetPriceProvider_TVLUsesNewProvider() public {
        // Deposit some tokens
        token.mint(kingVault, 100e18);
        vm.prank(kingVault);
        token.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Get TVL with first provider (ETH price = $2000)
        (uint256 ethValue1, uint256 usdValue1) = vault.tvl();

        // Update to second provider (ETH price = $2100)
        vault.setPriceProvider(address(priceProvider2));

        // Set price in new provider
        priceProvider2.setPrice(address(token), 1e18); // Same token price in ETH

        // Get TVL with second provider
        (uint256 ethValue2, uint256 usdValue2) = vault.tvl();

        // ETH value should be same (token price in ETH unchanged)
        assertEq(ethValue1, ethValue2, "ETH value should be same");

        // USD value should be different (ETH/USD price changed from 2000 to 2100)
        assertGt(usdValue2, usdValue1, "USD value should increase with higher ETH price");

        // Verify exact USD values
        assertEq(usdValue1, 200000e18, "Initial USD value should be 100 ETH * $2000"); // 100 tokens * 1 ETH/token * $2000/ETH
        assertEq(usdValue2, 210000e18, "Updated USD value should be 100 ETH * $2100"); // 100 tokens * 1 ETH/token * $2100/ETH
    }

    // ============================================
    // Negative Tests
    // ============================================

    function test_SetPriceProvider_RevertsForZeroAddress() public {
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        vault.setPriceProvider(address(0));
    }

    function test_SetPriceProvider_RevertsForUnauthorizedCaller() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // OwnableUpgradeable error
        vault.setPriceProvider(address(priceProvider2));
    }

    function test_SetPriceProvider_RevertsForKingVault() public {
        // kingVault is not the owner, so it cannot call setPriceProvider
        vm.prank(kingVault);
        vm.expectRevert(); // OwnableUpgradeable error
        vault.setPriceProvider(address(priceProvider2));
    }

    // ============================================
    // Immutability Tests
    // ============================================

    function test_KingVault_ImmutableAfterInitialization() public {
        // Verify kingVault is set correctly
        assertEq(vault.kingVault(), kingVault, "King vault should be set");

        // There is NO function to change kingVault - it's immutable by design (Decision 11)
        // This test documents the immutability requirement

        // Verify only priceProvider can be changed, not kingVault
        vault.setPriceProvider(address(priceProvider2));

        // kingVault remains unchanged
        assertEq(vault.kingVault(), kingVault, "King vault should remain unchanged");
    }

    function test_SetPriceProvider_DoesNotAffectKingVault() public {
        address originalKingVault = vault.kingVault();

        // Update price provider
        vault.setPriceProvider(address(priceProvider2));

        // Verify kingVault is unchanged
        assertEq(vault.kingVault(), originalKingVault, "King vault should not change");
    }

    // ============================================
    // Edge Cases
    // ============================================

    function test_SetPriceProvider_SameAddress() public {
        // Setting to same address should work (no-op but valid)
        vm.expectEmit(true, true, false, false);
        emit PriceProviderUpdated(address(priceProvider1), address(priceProvider1));

        vault.setPriceProvider(address(priceProvider1));

        // Verify still set to same address
        assertEq(vault.priceProvider(), address(priceProvider1));
    }
}
