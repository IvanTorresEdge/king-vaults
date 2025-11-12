// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockPriceProvider.sol";
import "./KingVaultHarness.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title KingVaultRegisterAssetsTest
 * @notice Tests for registerAssets() function and token management
 */
contract KingVaultRegisterAssetsTest is Test {
    KingVaultHarness public vault;
    MockPriceProvider public priceProvider;
    MockERC20 public usdc;
    MockERC20 public weth;

    address public owner = address(this);
    address public kingVault = address(0x1);
    address public unauthorized = address(0x999);

    function setUp() public {
        // Deploy mocks
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        priceProvider = new MockPriceProvider(2000e18); // $2000 ETH

        // Set prices for tokens
        priceProvider.setPrice(address(usdc), 0.0005e18); // $1 = 0.0005 ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH

        // Deploy vault implementation
        KingVaultHarness implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            KingVaultHarness.initialize.selector,
            owner,
            kingVault,
            address(priceProvider)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));
    }

    // ============================================
    // Safety Check Tests
    // ============================================

    function test_RegisterAssets_CannotDisableTokenWithDeposits() public {
        // Register USDC as accepted
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // Deposit some USDC
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory depositTokens = new address[](1);
        depositTokens[0] = address(usdc);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(depositTokens, depositAmounts);

        // Verify deposits exist
        assertEq(vault.getDeposits(address(usdc)), 1000e6);

        // Try to disable USDC - should revert
        accepted[0] = false;

        vm.expectRevert(
            abi.encodeWithSignature(
                "CannotDisableTokenWithDeposits(address,uint256)",
                address(usdc),
                1000e6
            )
        );
        vault.registerAssets(tokens, accepted);

        // Verify token is still enabled
        assertTrue(vault.isTokenRegistered(address(usdc)));
    }

    function test_RegisterAssets_CanDisableTokenAfterWithdrawal() public {
        // Register USDC as accepted
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // Deposit some USDC
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory depositTokens = new address[](1);
        depositTokens[0] = address(usdc);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(depositTokens, depositAmounts);

        // Withdraw all USDC
        vm.prank(kingVault);
        vault.withdraw(depositTokens, depositAmounts, kingVault);

        // Verify deposits are zero
        assertEq(vault.getDeposits(address(usdc)), 0);

        // Now disabling should succeed
        accepted[0] = false;
        vault.registerAssets(tokens, accepted);

        // Verify token is now disabled
        assertFalse(vault.isTokenRegistered(address(usdc)));
    }

    function test_RegisterAssets_CanDisableTokenWithNoDeposits() public {
        // Register USDC as accepted
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vault.registerAssets(tokens, accepted);

        // No deposits made

        // Disabling should succeed since no deposits exist
        accepted[0] = false;
        vault.registerAssets(tokens, accepted);

        // Verify token is now disabled
        assertFalse(vault.isTokenRegistered(address(usdc)));
    }

    function test_RegisterAssets_MultipleTokensPartialDisable() public {
        // Register both tokens as accepted
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        vault.registerAssets(tokens, accepted);

        // Deposit only USDC (not WETH)
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory depositTokens = new address[](1);
        depositTokens[0] = address(usdc);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(depositTokens, depositAmounts);

        // Try to disable both - USDC should fail, WETH should succeed
        accepted[0] = false;
        accepted[1] = false;

        // Should revert because USDC has deposits
        vm.expectRevert(
            abi.encodeWithSignature(
                "CannotDisableTokenWithDeposits(address,uint256)",
                address(usdc),
                1000e6
            )
        );
        vault.registerAssets(tokens, accepted);

        // Disable only WETH (no deposits)
        address[] memory wethOnly = new address[](1);
        wethOnly[0] = address(weth);
        bool[] memory wethAccepted = new bool[](1);
        wethAccepted[0] = false;

        vault.registerAssets(wethOnly, wethAccepted);

        // Verify WETH is disabled but USDC is still enabled
        assertFalse(vault.isTokenRegistered(address(weth)));
        assertTrue(vault.isTokenRegistered(address(usdc)));
    }

    // ============================================
    // Access Control Tests
    // ============================================

    function test_RegisterAssets_OnlyOwner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vm.prank(unauthorized);
        vm.expectRevert();
        vault.registerAssets(tokens, accepted);
    }

    function test_RegisterAssets_KingVaultCannotRegister() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        vm.prank(kingVault);
        vm.expectRevert();
        vault.registerAssets(tokens, accepted);
    }
}
