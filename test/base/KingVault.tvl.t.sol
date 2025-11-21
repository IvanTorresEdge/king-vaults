// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockPriceProvider.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";
import "./KingVaultHarness.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title KingVaultTVLTest
 * @notice Tests for tvl() function and price provider integration
 */
contract KingVaultTVLTest is Test {
    KingVaultHarness public vault;
    MockPriceProvider public priceProvider;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockERC20 public dai;

    address public owner = address(this);
    address public kingVault;

    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Deploy mocks
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Deploy price provider with $2000 ETH
        priceProvider = new MockPriceProvider(2000e18);

        // Set prices
        priceProvider.setPrice(address(usdc), 0.0005e18); // $1 = 0.0005 ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(dai), 0.0005e18); // $1 = 0.0005 ETH

        // Deploy vault implementation
        KingVaultHarness implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Register tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(dai);
        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;
        vault.registerAssets(tokens, accepted);
    }

    // ============================================
    // Happy Path Tests
    // ============================================

    function test_TVL_EmptyVault() public view {
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 0);
        assertEq(usdValue, 0);
    }

    function test_TVL_SingleToken() public {
        // Deposit 1000 USDC ($1000)
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Calculate expected values
        // 1000 USDC * 0.0005 ETH = 0.5 ETH
        // 0.5 ETH * $2000 = $1000
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 0.5e18);
        assertEq(usdValue, 1000e18);
    }

    function test_TVL_MultipleTokens() public {
        // Deposit tokens
        usdc.mint(kingVault, 1000e6); // $1000
        weth.mint(kingVault, 2e18); // 2 ETH = $4000
        dai.mint(kingVault, 500e18); // $500

        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);
        vm.prank(kingVault);
        weth.approve(address(vault), 2e18);
        vm.prank(kingVault);
        dai.approve(address(vault), 500e18);

        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(dai);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e6;
        amounts[1] = 2e18;
        amounts[2] = 500e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Calculate expected values
        // USDC: 1000 * 0.0005 = 0.5 ETH
        // WETH: 2 * 1 = 2 ETH
        // DAI: 500 * 0.0005 = 0.25 ETH
        // Total: 2.75 ETH = $5500
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 2.75e18);
        assertEq(usdValue, 5500e18);
    }

    function test_TVL_IgnoresUnregisteredTokens() public {
        // Deposit USDC (registered)
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Disable WETH (simulate having some deposits but token is disabled)
        address[] memory disableTokens = new address[](1);
        disableTokens[0] = address(weth);
        bool[] memory disableAccepted = new bool[](1);
        disableAccepted[0] = false;
        vault.registerAssets(disableTokens, disableAccepted);

        // TVL should only count USDC
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 0.5e18);
        assertEq(usdValue, 1000e18);
    }

    function test_TVL_SkipsTokensWithZeroDeposits() public {
        // Deposit only USDC, not WETH or DAI
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // TVL should only count USDC (WETH and DAI have 0 deposits)
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 0.5e18);
        assertEq(usdValue, 1000e18);
    }

    // ============================================
    // Price Availability Tests - CRITICAL
    // ============================================

    function test_TVL_RevertsIfPriceNotAvailable() public {
        // Deposit USDC
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Remove price availability for USDC
        priceProvider.setPriceAvailability(address(usdc), false);

        // TVL should revert, not skip
        vm.expectRevert(abi.encodeWithSignature("PriceNotAvailable(address)", address(usdc)));
        vault.tvl();
    }

    function test_TVL_RevertsIfPriceIsZero() public {
        // Deposit USDC
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Set USDC price to zero
        priceProvider.setPrice(address(usdc), 0);

        // TVL should revert, not skip
        vm.expectRevert(abi.encodeWithSignature("PriceNotAvailable(address)", address(usdc)));
        vault.tvl();
    }

    function test_TVL_RevertsIfAnyTokenLacksPrice() public {
        // Deposit multiple tokens
        usdc.mint(kingVault, 1000e6);
        weth.mint(kingVault, 2e18);
        dai.mint(kingVault, 500e18);

        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);
        vm.prank(kingVault);
        weth.approve(address(vault), 2e18);
        vm.prank(kingVault);
        dai.approve(address(vault), 500e18);

        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(dai);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e6;
        amounts[1] = 2e18;
        amounts[2] = 500e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Remove price for middle token (WETH)
        priceProvider.setPriceAvailability(address(weth), false);

        // TVL should revert for the entire calculation
        vm.expectRevert(abi.encodeWithSignature("PriceNotAvailable(address)", address(weth)));
        vault.tvl();
    }

    function test_TVL_WorksAfterPriceRestored() public {
        // Deposit USDC
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Remove price
        priceProvider.setPriceAvailability(address(usdc), false);

        // Verify reverts
        vm.expectRevert(abi.encodeWithSignature("PriceNotAvailable(address)", address(usdc)));
        vault.tvl();

        // Restore price
        priceProvider.setPrice(address(usdc), 0.0005e18);

        // Now should work
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 0.5e18);
        assertEq(usdValue, 1000e18);
    }

    // ============================================
    // Decimal Handling Tests
    // ============================================

    function test_TVL_DifferentDecimals() public {
        // Deposit tokens with different decimals
        usdc.mint(kingVault, 1000e6); // 6 decimals
        weth.mint(kingVault, 2e18); // 18 decimals

        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);
        vm.prank(kingVault);
        weth.approve(address(vault), 2e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e6;
        amounts[1] = 2e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // USDC: 1000 * 0.0005 = 0.5 ETH
        // WETH: 2 * 1 = 2 ETH
        // Total: 2.5 ETH = $5000
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 2.5e18);
        assertEq(usdValue, 5000e18);
    }

    // ============================================
    // ETH Price Change Tests
    // ============================================

    function test_TVL_EthPriceChange() public {
        // Deposit 1000 USDC
        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(vault), 1000e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // At $2000 ETH: 0.5 ETH = $1000
        (uint256 ethValue1, uint256 usdValue1) = vault.tvl();
        assertEq(ethValue1, 0.5e18);
        assertEq(usdValue1, 1000e18);

        // Change ETH price to $3000
        priceProvider.setEthUsdPrice(3000e18);

        // ETH value stays same, USD value increases
        (uint256 ethValue2, uint256 usdValue2) = vault.tvl();
        assertEq(ethValue2, 0.5e18);
        assertEq(usdValue2, 1500e18); // 0.5 ETH * $3000
    }
}
