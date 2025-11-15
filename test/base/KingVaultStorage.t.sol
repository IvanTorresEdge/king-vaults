// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingVaultStorageHarness} from "./KingVaultStorageHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

contract KingVaultStorageTest is Test {
    KingVaultStorageHarness public vault;
    KingVaultStorageHarness public implementation;

    MockERC20 public token6; // 6 decimals (USDC-like)
    MockERC20 public token8; // 8 decimals (WBTC-like)
    MockERC20 public token18; // 18 decimals (WETH-like)

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public priceProvider = address(0x3);
    address public unauthorized = address(0x4);
    address public recipient1 = address(0x10);
    address public recipient2 = address(0x11);
    address public recipient3 = address(0x12);

    function setUp() public {
        // Deploy implementation
        implementation = new KingVaultStorageHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultStorageHarness.initialize.selector, owner, kingVault, priceProvider);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultStorageHarness(address(proxy));

        // Deploy mock tokens with different decimals
        token6 = new MockERC20("USDC", "USDC", 6);
        token8 = new MockERC20("WBTC", "WBTC", 8);
        token18 = new MockERC20("WETH", "WETH", 18);
    }

    // ============================================
    // Initialization Tests
    // ============================================

    function test_Initialization() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.kingVault(), kingVault);
        assertEq(vault.priceProvider(), priceProvider);
        assertEq(vault.paused(), false);
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        vault.initialize(owner, kingVault, priceProvider);
    }

    // ============================================
    // Storage Mapping Tests
    // ============================================

    function test_RegisteredTokensMapping() public {
        // Initially false
        assertFalse(vault.isTokenRegistered(address(token6)));

        // Set to true
        vault.setTokenRegistered(address(token6), true);
        assertTrue(vault.isTokenRegistered(address(token6)));

        // Set back to false
        vault.setTokenRegistered(address(token6), false);
        assertFalse(vault.isTokenRegistered(address(token6)));
    }

    function test_DepositsMapping() public {
        // Initially zero
        assertEq(vault.getDeposits(address(token6)), 0);

        // Set amount
        vault.setDeposits(address(token6), 1000e6);
        assertEq(vault.getDeposits(address(token6)), 1000e6);

        // Update amount
        vault.setDeposits(address(token6), 2000e6);
        assertEq(vault.getDeposits(address(token6)), 2000e6);
    }

    function test_ProfitsDistributionMapping() public {
        // Initially zero
        assertEq(vault.getProfitsDistribution(recipient1), 0);

        // Set percentage
        vault.setProfitsDistribution(recipient1, 5000); // 50%
        assertEq(vault.getProfitsDistribution(recipient1), 5000);

        // Update percentage
        vault.setProfitsDistribution(recipient1, 7000); // 70%
        assertEq(vault.getProfitsDistribution(recipient1), 7000);
    }

    // ============================================
    // Helper Function Tests - _getDecimals
    // ============================================

    function test_GetDecimals_6Decimals() public view {
        assertEq(vault.exposed_getDecimals(address(token6)), 6);
    }

    function test_GetDecimals_8Decimals() public view {
        assertEq(vault.exposed_getDecimals(address(token8)), 8);
    }

    function test_GetDecimals_18Decimals() public view {
        assertEq(vault.exposed_getDecimals(address(token18)), 18);
    }

    // ============================================
    // Helper Function Tests - _addToAssets
    // ============================================

    function test_AddToAssets_AddsTokenWhenNotPresent() public {
        // Initially empty
        assertEq(vault.getAssets().length, 0);

        // Add token
        vault.exposed_addToAssets(address(token6));

        // Verify added
        address[] memory assets = vault.getAssets();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(token6));
    }

    function test_AddToAssets_DoesNotAddDuplicate() public {
        // Add token once
        vault.exposed_addToAssets(address(token6));
        assertEq(vault.getAssets().length, 1);

        // Try to add again
        vault.exposed_addToAssets(address(token6));

        // Still only one
        assertEq(vault.getAssets().length, 1);
    }

    function test_AddToAssets_MultipleTokens() public {
        // Add three different tokens
        vault.exposed_addToAssets(address(token6));
        vault.exposed_addToAssets(address(token8));
        vault.exposed_addToAssets(address(token18));

        // Verify all added
        address[] memory assets = vault.getAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(token6));
        assertEq(assets[1], address(token8));
        assertEq(assets[2], address(token18));
    }

    function test_AddToAssets_Idempotent() public {
        // Add same token multiple times
        vault.exposed_addToAssets(address(token6));
        vault.exposed_addToAssets(address(token6));
        vault.exposed_addToAssets(address(token6));

        // Should only appear once
        assertEq(vault.getAssets().length, 1);
    }

    // ============================================
    // Helper Function Tests - _addToProfitsRecipients
    // ============================================

    function test_AddToProfitsRecipients_AddsWhenNotPresent() public {
        // Initially empty
        assertEq(vault.getProfitsRecipients().length, 0);

        // Add recipient
        vault.exposed_addToProfitsRecipients(recipient1);

        // Verify added
        address[] memory recipients = vault.getProfitsRecipients();
        assertEq(recipients.length, 1);
        assertEq(recipients[0], recipient1);
    }

    function test_AddToProfitsRecipients_DoesNotAddDuplicate() public {
        // Add once
        vault.exposed_addToProfitsRecipients(recipient1);
        assertEq(vault.getProfitsRecipients().length, 1);

        // Try to add again
        vault.exposed_addToProfitsRecipients(recipient1);

        // Still only one
        assertEq(vault.getProfitsRecipients().length, 1);
    }

    function test_AddToProfitsRecipients_MultipleRecipients() public {
        // Add three recipients
        vault.exposed_addToProfitsRecipients(recipient1);
        vault.exposed_addToProfitsRecipients(recipient2);
        vault.exposed_addToProfitsRecipients(recipient3);

        // Verify all added
        address[] memory recipients = vault.getProfitsRecipients();
        assertEq(recipients.length, 3);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(recipients[2], recipient3);
    }

    // ============================================
    // Helper Function Tests - _removeFromProfitsRecipients
    // ============================================

    function test_RemoveFromProfitsRecipients_RemovesSuccessfully() public {
        // Add recipients
        vault.exposed_addToProfitsRecipients(recipient1);
        vault.exposed_addToProfitsRecipients(recipient2);
        vault.exposed_addToProfitsRecipients(recipient3);
        assertEq(vault.getProfitsRecipients().length, 3);

        // Remove middle one
        vault.exposed_removeFromProfitsRecipients(recipient2);

        // Verify removed (swap-and-pop means order may change)
        address[] memory recipients = vault.getProfitsRecipients();
        assertEq(recipients.length, 2);

        // Verify recipient2 is not in array
        bool found = false;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == recipient2) {
                found = true;
            }
        }
        assertFalse(found);
    }

    function test_RemoveFromProfitsRecipients_SwapAndPop() public {
        // Add three recipients
        vault.exposed_addToProfitsRecipients(recipient1);
        vault.exposed_addToProfitsRecipients(recipient2);
        vault.exposed_addToProfitsRecipients(recipient3);

        // Remove first one (should swap with last and pop)
        vault.exposed_removeFromProfitsRecipients(recipient1);

        // Verify length reduced
        address[] memory recipients = vault.getProfitsRecipients();
        assertEq(recipients.length, 2);
    }

    function test_RemoveFromProfitsRecipients_NonExistentRecipient() public {
        // Add some recipients
        vault.exposed_addToProfitsRecipients(recipient1);
        vault.exposed_addToProfitsRecipients(recipient2);

        // Try to remove one that doesn't exist (should be no-op)
        vault.exposed_removeFromProfitsRecipients(recipient3);

        // Length unchanged
        assertEq(vault.getProfitsRecipients().length, 2);
    }

    function test_RemoveFromProfitsRecipients_Idempotent() public {
        // Add recipient
        vault.exposed_addToProfitsRecipients(recipient1);

        // Remove twice
        vault.exposed_removeFromProfitsRecipients(recipient1);
        vault.exposed_removeFromProfitsRecipients(recipient1);

        // Should be empty
        assertEq(vault.getProfitsRecipients().length, 0);
    }

    // ============================================
    // Access Control Tests - _requireKingVault
    // ============================================

    function test_RequireKingVault_SucceedsForKingVault() public {
        vm.prank(kingVault);
        vault.exposed_requireKingVault();
        // Should not revert
    }

    function test_RequireKingVault_RevertsForUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        vault.exposed_requireKingVault();
    }

    function test_RequireKingVault_RevertsForOwner() public {
        vm.prank(owner);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        vault.exposed_requireKingVault();
    }

    // ============================================
    // Access Control Tests - _requireOwner
    // ============================================

    function test_RequireOwner_SucceedsForOwner() public {
        vm.prank(owner);
        vault.exposed_requireOwner();
        // Should not revert
    }

    function test_RequireOwner_RevertsForUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", unauthorized));
        vault.exposed_requireOwner();
    }

    function test_RequireOwner_RevertsForKingVault() public {
        vm.prank(kingVault);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", kingVault));
        vault.exposed_requireOwner();
    }

    // ============================================
    // Access Control Tests - _requireOwnerOrKingVault
    // ============================================

    function test_RequireOwnerOrKingVault_SucceedsForOwner() public {
        vm.prank(owner);
        vault.exposed_requireOwnerOrKingVault();
        // Should not revert
    }

    function test_RequireOwnerOrKingVault_SucceedsForKingVault() public {
        vm.prank(kingVault);
        vault.exposed_requireOwnerOrKingVault();
        // Should not revert
    }

    function test_RequireOwnerOrKingVault_RevertsForUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        vault.exposed_requireOwnerOrKingVault();
    }

    // ============================================
    // UUPS Upgrade Authorization Tests
    // ============================================

    function test_AuthorizeUpgrade_SucceedsForOwner() public {
        address newImpl = address(new KingVaultStorageHarness());

        vm.prank(owner);
        // Should not revert - owner can upgrade
        vault.upgradeToAndCall(newImpl, "");
    }

    function test_AuthorizeUpgrade_RevertsForNonOwner() public {
        address newImpl = address(new KingVaultStorageHarness());

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", unauthorized));
        vault.upgradeToAndCall(newImpl, "");
    }

    function test_AuthorizeUpgrade_RevertsForKingVault() public {
        address newImpl = address(new KingVaultStorageHarness());

        vm.prank(kingVault);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", kingVault));
        vault.upgradeToAndCall(newImpl, "");
    }

    // ============================================
    // View Function Tests - getProfitRecipientInfo
    // ============================================

    function test_GetProfitRecipientInfo_NonRecipient() public view {
        // Query address that was never added
        (bool isRecipient, uint16 percentage) = vault.getProfitRecipientInfo(recipient1);
        assertFalse(isRecipient);
        assertEq(percentage, 0);
    }

    function test_GetProfitRecipientInfo_ActiveRecipient() public {
        // Set up recipient with 50% distribution
        vault.setProfitsDistribution(recipient1, 5000);

        // Query the recipient
        (bool isRecipient, uint16 percentage) = vault.getProfitRecipientInfo(recipient1);
        assertTrue(isRecipient);
        assertEq(percentage, 5000);
    }

    function test_GetProfitRecipientInfo_MultipleRecipients() public {
        // Set up multiple recipients with different percentages
        vault.setProfitsDistribution(recipient1, 3000); // 30%
        vault.setProfitsDistribution(recipient2, 5000); // 50%
        vault.setProfitsDistribution(recipient3, 2000); // 20%

        // Query each recipient
        (bool isRecipient1, uint16 percentage1) = vault.getProfitRecipientInfo(recipient1);
        assertTrue(isRecipient1);
        assertEq(percentage1, 3000);

        (bool isRecipient2, uint16 percentage2) = vault.getProfitRecipientInfo(recipient2);
        assertTrue(isRecipient2);
        assertEq(percentage2, 5000);

        (bool isRecipient3, uint16 percentage3) = vault.getProfitRecipientInfo(recipient3);
        assertTrue(isRecipient3);
        assertEq(percentage3, 2000);
    }

    function test_GetProfitRecipientInfo_AfterRemoval() public {
        // Set up recipient
        vault.setProfitsDistribution(recipient1, 5000);

        // Verify they are a recipient
        (bool isRecipient, uint16 percentage) = vault.getProfitRecipientInfo(recipient1);
        assertTrue(isRecipient);
        assertEq(percentage, 5000);

        // Remove recipient by setting to 0
        vault.setProfitsDistribution(recipient1, 0);

        // Query again - should return false and 0
        (isRecipient, percentage) = vault.getProfitRecipientInfo(recipient1);
        assertFalse(isRecipient);
        assertEq(percentage, 0);
    }

    function test_GetProfitRecipientInfo_UpdatedPercentage() public {
        // Set up recipient with initial percentage
        vault.setProfitsDistribution(recipient1, 3000);

        // Update the percentage
        vault.setProfitsDistribution(recipient1, 7000);

        // Query should return updated percentage
        (bool isRecipient, uint16 percentage) = vault.getProfitRecipientInfo(recipient1);
        assertTrue(isRecipient);
        assertEq(percentage, 7000);
    }

    // ============================================
    // Constants Tests
    // ============================================

    function test_HundredPercentInBPS() public view {
        assertEq(vault.HUNDRED_PERCENT_IN_BPS(), 10_000);
    }
}
