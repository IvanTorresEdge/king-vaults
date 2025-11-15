// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title KingVaultPauseTest
 * @notice Comprehensive test suite for pause/unpause functionality
 */
contract KingVaultPauseTest is Test {
    KingVaultHarness public vault;
    MockPriceProvider public priceProvider;
    MockERC20 public token1;

    address public owner;
    address public kingVault;
    address public unauthorized;

    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        // Setup test accounts
        owner = address(this);
        kingVault = address(0x1);
        unauthorized = address(0x2);

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH

        // Deploy vault implementation
        KingVaultHarness implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Deploy and setup token
        token1 = new MockERC20("Token1", "TKN1", 18);
        priceProvider.setPrice(address(token1), 0.0005e18); // 1 token = 0.0005 ETH

        // Register token
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        vault.registerAssets(tokens, accepted);

        // Mint tokens to kingVault for deposits
        token1.mint(kingVault, 10000e18);
    }

    // ============================================
    // Test pause() function
    // ============================================

    function test_Pause_SetsPausedStatus() public {
        // Initially not paused
        assertFalse(vault.paused());

        // Owner pauses
        vault.pause();

        // Now paused
        assertTrue(vault.paused());
    }

    function test_Pause_EmitsEvent() public {
        // Expect Paused event with owner as caller
        vm.expectEmit(true, false, false, true);
        emit Paused(owner);

        vault.pause();
    }

    function test_Pause_CallableByOwner() public {
        // Owner can pause
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Pause_CallableByKingVault() public {
        // KingVault can pause
        vm.prank(kingVault);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Pause_RevertsForUnauthorizedCaller() public {
        // Unauthorized caller cannot pause
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        vault.pause();
    }

    function test_Pause_RevertsWhenAlreadyPaused() public {
        // Pause first time
        vault.pause();

        // Cannot pause again - reverts from OpenZeppelin's _pause()
        vm.expectRevert();
        vault.pause();
    }

    // ============================================
    // Test unpause() function
    // ============================================

    function test_Unpause_ResetsPausedStatus() public {
        // Pause first
        vault.pause();
        assertTrue(vault.paused());

        // Unpause
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_Unpause_EmitsEvent() public {
        // Pause first
        vault.pause();

        // Expect Unpaused event
        vm.expectEmit(true, false, false, true);
        emit Unpaused(owner);

        vault.unpause();
    }

    function test_Unpause_CallableByOwner() public {
        vault.pause();

        // Owner can unpause
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_Unpause_CallableByKingVault() public {
        vault.pause();

        // KingVault can unpause
        vm.prank(kingVault);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_Unpause_RevertsForUnauthorizedCaller() public {
        vault.pause();

        // Unauthorized caller cannot unpause
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        vault.unpause();
    }

    function test_Unpause_RevertsWhenNotPaused() public {
        // Cannot unpause when not paused - reverts from OpenZeppelin's _unpause()
        vm.expectRevert();
        vault.unpause();
    }

    // ============================================
    // Test deposit() blocked when paused
    // ============================================

    function test_Deposit_RevertsWhenPaused() public {
        // Prepare deposit
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Approve tokens
        vm.prank(kingVault);
        token1.approve(address(vault), 1000e18);

        // Pause vault
        vault.pause();

        // Deposit should revert
        vm.prank(kingVault);
        vm.expectRevert();
        vault.deposit(tokens, amounts);
    }

    function test_Deposit_WorksWhenNotPaused() public {
        // Prepare deposit
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Approve tokens
        vm.prank(kingVault);
        token1.approve(address(vault), 1000e18);

        // Deposit should succeed when not paused
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        assertEq(vault.getDeposits(address(token1)), 1000e18);
    }

    // ============================================
    // Test withdraw() blocked when paused
    // ============================================

    function test_Withdraw_RevertsWhenPaused() public {
        // First deposit some tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(kingVault);
        token1.approve(address(vault), 1000e18);
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Pause vault
        vault.pause();

        // Withdraw should revert
        amounts[0] = 500e18;
        vm.prank(kingVault);
        vm.expectRevert();
        vault.withdraw(tokens, amounts, kingVault);
    }

    function test_Withdraw_WorksWhenNotPaused() public {
        // Deposit tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(kingVault);
        token1.approve(address(vault), 1000e18);
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Withdraw should succeed when not paused
        amounts[0] = 500e18;
        vm.prank(kingVault);
        vault.withdraw(tokens, amounts, kingVault);

        assertEq(vault.getDeposits(address(token1)), 500e18);
    }

    // ============================================
    // Test emergencyWithdraw() works when paused
    // ============================================

    function test_EmergencyWithdraw_WorksWhenPaused() public {
        // Deposit tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(kingVault);
        token1.approve(address(vault), 1000e18);
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Pause vault
        vault.pause();

        // Emergency withdraw should work even when paused
        vault.emergencyWithdraw();

        // Verify all tokens withdrawn
        assertEq(vault.getDeposits(address(token1)), 0);
        assertEq(token1.balanceOf(kingVault), 10000e18); // All tokens returned
    }

    function test_EmergencyWithdraw_WorksWhenNotPaused() public {
        // Deposit tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(kingVault);
        token1.approve(address(vault), 1000e18);
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Emergency withdraw should work when not paused
        vault.emergencyWithdraw();

        assertEq(vault.getDeposits(address(token1)), 0);
    }

    // ============================================
    // Test pause cycle
    // ============================================

    function test_PauseUnpauseCycle() public {
        // Start unpaused
        assertFalse(vault.paused());

        // Pause
        vault.pause();
        assertTrue(vault.paused());

        // Unpause
        vault.unpause();
        assertFalse(vault.paused());

        // Can pause again
        vault.pause();
        assertTrue(vault.paused());
    }
}
