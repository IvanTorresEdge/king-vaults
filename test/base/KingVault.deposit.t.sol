// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultDepositTest
 * @notice Comprehensive tests for deposit() function (Task 2.3)
 */
contract KingVaultDepositTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;

    MockERC20 public usdc;  // 6 decimals
    MockERC20 public weth;  // 18 decimals
    MockERC20 public dai;   // 18 decimals

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public priceProvider = address(0x3);
    address public unauthorized = address(0x4);

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
        usdc.mint(kingVault, 1_000_000e6);  // 1M USDC
        weth.mint(kingVault, 1000e18);       // 1000 WETH
        dai.mint(kingVault, 1_000_000e18);   // 1M DAI

        // Approve vault to spend tokens
        vm.startPrank(kingVault);
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        dai.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================
    // Happy Path Tests
    // ============================================

    function test_Deposit_SingleToken() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000e6; // 10k USDC

        // Assert initial state
        assertEq(vault.getDeposits(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        // Act
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Assert final state
        assertEq(vault.getDeposits(address(usdc)), 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
        assertEq(usdc.balanceOf(kingVault), 1_000_000e6 - 10_000e6);
    }

    function test_Deposit_MultiToken() public {
        // Arrange
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(dai);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 50_000e6;   // 50k USDC
        amounts[1] = 10e18;      // 10 WETH
        amounts[2] = 100_000e18; // 100k DAI

        // Assert initial state
        assertEq(vault.getDeposits(address(usdc)), 0);
        assertEq(vault.getDeposits(address(weth)), 0);
        assertEq(vault.getDeposits(address(dai)), 0);

        // Act
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Assert final state
        assertEq(vault.getDeposits(address(usdc)), 50_000e6);
        assertEq(vault.getDeposits(address(weth)), 10e18);
        assertEq(vault.getDeposits(address(dai)), 100_000e18);

        assertEq(usdc.balanceOf(address(vault)), 50_000e6);
        assertEq(weth.balanceOf(address(vault)), 10e18);
        assertEq(dai.balanceOf(address(vault)), 100_000e18);
    }

    // ============================================
    // Access Control Tests
    // ============================================

    function test_Deposit_RevertsForUnauthorizedCaller() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        // Act & Assert
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        vault.deposit(tokens, amounts);
    }

    function test_Deposit_RevertsForOwner() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        // Act & Assert
        vm.prank(owner);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        vault.deposit(tokens, amounts);
    }

    // ============================================
    // Pause Mechanism Tests
    // ============================================

    function test_Deposit_RevertsWhenPaused() public {
        // Arrange
        vm.prank(owner);
        vault.pause();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(tokens, amounts);
    }

    // ============================================
    // Token Validation Tests
    // ============================================

    function test_Deposit_RevertsForUnacceptedToken() public {
        // Arrange
        MockERC20 unacceptedToken = new MockERC20("Unaccepted", "UNAC", 18);
        unacceptedToken.mint(kingVault, 1000e18);

        vm.prank(kingVault);
        unacceptedToken.approve(address(vault), type(uint256).max);

        address[] memory tokens = new address[](1);
        tokens[0] = address(unacceptedToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(abi.encodeWithSelector(IKingVault.AssetNotAccepted.selector, address(unacceptedToken)));
        vault.deposit(tokens, amounts);
    }

    // ============================================
    // Amount Validation Tests
    // ============================================

    function test_Deposit_RevertsForZeroAmount() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        vault.deposit(tokens, amounts);
    }

    function test_Deposit_RevertsForZeroAmountInMultiToken() public {
        // Arrange - second token has zero amount
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e6;
        amounts[1] = 0; // Zero amount

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        vault.deposit(tokens, amounts);
    }

    // ============================================
    // Array Validation Tests
    // ============================================

    function test_Deposit_RevertsForEmptyArrays() public {
        // Arrange
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        vault.deposit(tokens, amounts);
    }

    function test_Deposit_RevertsForMismatchedArrays() public {
        // Arrange
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        uint256[] memory amounts = new uint256[](1); // Mismatched length
        amounts[0] = 1000e6;

        // Act & Assert
        vm.prank(kingVault);
        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        vault.deposit(tokens, amounts);
    }

    // ============================================
    // Event Emission Tests
    // ============================================

    function test_Deposit_EmitsEvent() public {
        // Arrange
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5000e6;

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit IKingVault.Deposited(tokens, amounts, block.timestamp);

        // Act
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
    }

    function test_Deposit_EmitsEventForMultiToken() public {
        // Arrange
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(dai);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10_000e6;
        amounts[1] = 5e18;
        amounts[2] = 20_000e18;

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit IKingVault.Deposited(tokens, amounts, block.timestamp);

        // Act
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
    }
}
