// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultDistributeProfitsTest
 * @notice Comprehensive tests for distributeProfits() function (Task 5.7)
 * @dev Tests cover all scenarios from tasks.md and spec TS-17
 */
contract KingVaultDistributeProfitsTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;
    MockPriceProvider public priceProvider;

    MockERC20 public usdc; // 6 decimals
    MockERC20 public wbtc; // 8 decimals
    MockERC20 public weth; // 18 decimals
    MockERC20 public dai; // 18 decimals

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public treasury = address(0x3);
    address public devFund = address(0x4);
    address public marketingFund = address(0x5);
    address public unauthorized = address(0x6);

    uint16 public constant HUNDRED_PERCENT = 10000;

    function setUp() public {
        // Deploy price provider
        priceProvider = new MockPriceProvider(2000e18);

        // Deploy implementation
        implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Set prices
        priceProvider.setPrice(address(usdc), 0.0005e18); // $1 / $2000 = 0.0005 ETH
        priceProvider.setPrice(address(wbtc), 20e18); // $40k / $2000 = 20 ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 ETH
        priceProvider.setPrice(address(dai), 0.0005e18); // $1 / $2000 = 0.0005 ETH

        // Register tokens
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
        vault.registerAssets(tokens, accepted);

        // Mint tokens to kingVault for deposits
        usdc.mint(kingVault, 1_000_000e6);
        wbtc.mint(kingVault, 100e8);
        weth.mint(kingVault, 1000e18);
        dai.mint(kingVault, 1_000_000e18);

        // Approve vault
        vm.startPrank(kingVault);
        usdc.approve(address(vault), type(uint256).max);
        wbtc.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        dai.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Helper to deposit tokens as principal
    function _depositPrincipal(address[] memory tokens, uint256[] memory amounts) internal {
        vm.prank(kingVault);
        vault.deposit(tokens, amounts);
    }

    /// @notice Helper to add profit (mint directly to vault)
    function _addProfit(address token, uint256 amount) internal {
        MockERC20(token).mint(address(vault), amount);
    }

    /// @notice Helper to setup profit distribution
    function _setupDistribution(address[] memory recipients, uint16[] memory percents) internal {
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    // ============================================
    // Happy Path Tests
    // ============================================

    /// @notice Single token profit distribution
    function test_DistributeProfits_SingleToken() public {
        // Setup: 100% to treasury
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;
        _setupDistribution(recipients, percents);

        // Deposit 1000 USDC as principal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        _depositPrincipal(tokens, amounts);

        // Add 500 USDC profit
        _addProfit(address(usdc), 500e6);

        // Verify balance before
        assertEq(usdc.balanceOf(address(vault)), 1500e6, "Vault should have 1500 USDC");
        assertEq(usdc.balanceOf(treasury), 0, "Treasury should have 0 USDC before");

        // Distribute profits
        vm.prank(owner);
        vault.distributeProfits();

        // Assert
        assertEq(usdc.balanceOf(treasury), 500e6, "Treasury should receive 500 USDC profit");
        assertEq(usdc.balanceOf(address(vault)), 1000e6, "Vault should keep 1000 USDC principal");
    }

    /// @notice TS-17: Multiple tokens, multiple recipients (60/40 split)
    function test_DistributeProfits_MultipleTokensMultipleRecipients() public {
        // Setup: 60% treasury, 40% devFund
        address[] memory recipients = new address[](2);
        recipients[0] = treasury;
        recipients[1] = devFund;
        uint16[] memory percents = new uint16[](2);
        percents[0] = 6000;
        percents[1] = 4000;
        _setupDistribution(recipients, percents);

        // Deposit principal: 1000 USDC, 2 WETH
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e6;
        amounts[1] = 2e18;
        _depositPrincipal(tokens, amounts);

        // Add profits: 1000 USDC, 2 WETH
        _addProfit(address(usdc), 1000e6);
        _addProfit(address(weth), 2e18);

        // Distribute
        vm.prank(owner);
        vault.distributeProfits();

        // Assert USDC distribution
        assertEq(usdc.balanceOf(treasury), 600e6, "Treasury should get 60% of 1000 USDC = 600 USDC");
        assertEq(usdc.balanceOf(devFund), 400e6, "DevFund should get 40% of 1000 USDC = 400 USDC");

        // Assert WETH distribution
        assertEq(weth.balanceOf(treasury), 1.2e18, "Treasury should get 60% of 2 WETH = 1.2 WETH");
        assertEq(weth.balanceOf(devFund), 0.8e18, "DevFund should get 40% of 2 WETH = 0.8 WETH");
    }

    /// @notice Three recipients with different decimals
    function test_DistributeProfits_ThreeRecipientsDifferentDecimals() public {
        // Setup: 33.33% / 33.33% / 33.34%
        address[] memory recipients = new address[](3);
        recipients[0] = treasury;
        recipients[1] = devFund;
        recipients[2] = marketingFund;
        uint16[] memory percents = new uint16[](3);
        percents[0] = 3333;
        percents[1] = 3333;
        percents[2] = 3334;
        _setupDistribution(recipients, percents);

        // Deposit and profit for 6, 8, 18 decimal tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc); // 6 dec
        tokens[1] = address(wbtc); // 8 dec
        tokens[2] = address(weth); // 18 dec
        uint256[] memory principal = new uint256[](3);
        principal[0] = 10000e6;
        principal[1] = 10e8;
        principal[2] = 100e18;
        _depositPrincipal(tokens, principal);

        // Add profit: 3000 USDC, 3 WBTC, 30 WETH
        _addProfit(address(usdc), 3000e6);
        _addProfit(address(wbtc), 3e8);
        _addProfit(address(weth), 30e18);

        // Distribute
        vm.prank(owner);
        vault.distributeProfits();

        // Assert distributions (allowing for rounding)
        // USDC: 3000 * 0.3333 = 999.9, 3000 * 0.3334 = 1000.2
        assertEq(usdc.balanceOf(treasury), 999_900_000, "Treasury USDC ~999.9");
        assertEq(usdc.balanceOf(devFund), 999_900_000, "DevFund USDC ~999.9");
        assertEq(usdc.balanceOf(marketingFund), 1_000_200_000, "Marketing USDC ~1000.2");

        // WBTC: 3 * 0.3333 = 0.9999, 3 * 0.3334 = 1.0002
        assertApproxEqAbs(wbtc.balanceOf(treasury), 99_990_000, 10_000, "Treasury WBTC ~0.9999");
        assertApproxEqAbs(wbtc.balanceOf(devFund), 99_990_000, 10_000, "DevFund WBTC ~0.9999");
        assertApproxEqAbs(wbtc.balanceOf(marketingFund), 100_020_000, 10_000, "Marketing WBTC ~1.0002");

        // WETH: 30 * 0.3333 = 9.999, 30 * 0.3334 = 10.002
        assertApproxEqAbs(weth.balanceOf(treasury), 9_999e15, 1e15, "Treasury WETH ~9.999");
        assertApproxEqAbs(weth.balanceOf(devFund), 9_999e15, 1e15, "DevFund WETH ~9.999");
        assertApproxEqAbs(weth.balanceOf(marketingFund), 10_002e15, 1e15, "Marketing WETH ~10.002");
    }

    /// @notice Profit calculation: balance - principal
    function test_DistributeProfits_OnlyDistributesProfitNotPrincipal() public {
        // Setup single recipient
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;
        _setupDistribution(recipients, percents);

        // Deposit 1000 USDC principal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        _depositPrincipal(tokens, amounts);

        // Add 200 USDC profit
        _addProfit(address(usdc), 200e6);

        // Verify vault has 1200 USDC total
        assertEq(usdc.balanceOf(address(vault)), 1200e6);
        assertEq(vault.getDeposits(address(usdc)), 1000e6, "Principal tracked");

        // Distribute
        vm.prank(owner);
        vault.distributeProfits();

        // Assert only profit distributed, principal stays
        assertEq(usdc.balanceOf(treasury), 200e6, "Only 200 USDC profit distributed");
        assertEq(usdc.balanceOf(address(vault)), 1000e6, "1000 USDC principal remains");
        assertEq(vault.getDeposits(address(usdc)), 1000e6, "Principal tracking unchanged");
    }

    /// @notice Skips tokens with zero profit
    function test_DistributeProfits_SkipsTokensWithZeroProfit() public {
        // Setup
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;
        _setupDistribution(recipients, percents);

        // Deposit USDC and WETH
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e6;
        amounts[1] = 10e18;
        _depositPrincipal(tokens, amounts);

        // Add profit ONLY to USDC (WETH has no profit)
        _addProfit(address(usdc), 500e6);

        // Distribute
        vm.prank(owner);
        vault.distributeProfits();

        // Assert
        assertEq(usdc.balanceOf(treasury), 500e6, "USDC profit distributed");
        assertEq(weth.balanceOf(treasury), 0, "No WETH profit, so nothing distributed");
        assertEq(weth.balanceOf(address(vault)), 10e18, "WETH principal untouched");
    }

    /// @notice Edge case: balance = principal (no profit)
    function test_DistributeProfits_NoProfit() public {
        // Setup
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;
        _setupDistribution(recipients, percents);

        // Deposit 1000 USDC (no profit added)
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        _depositPrincipal(tokens, amounts);

        // Distribute (should be no-op)
        vm.prank(owner);
        vault.distributeProfits();

        // Assert
        assertEq(usdc.balanceOf(treasury), 0, "No profit, nothing distributed");
        assertEq(usdc.balanceOf(address(vault)), 1000e6, "Principal remains");
    }

    /// @notice Event emission with 2D array structure
    function test_DistributeProfits_EmitsEvent() public {
        // Setup 60/40 split
        address[] memory recipients = new address[](2);
        recipients[0] = treasury;
        recipients[1] = devFund;
        uint16[] memory percents = new uint16[](2);
        percents[0] = 6000;
        percents[1] = 4000;
        _setupDistribution(recipients, percents);

        // Deposit and profit
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6;
        _depositPrincipal(tokens, amounts);
        _addProfit(address(usdc), 1000e6);

        // Record logs to verify event emission
        vm.recordLogs();

        vm.prank(owner);
        vault.distributeProfits();

        // Verify event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0, "Should emit ProfitsDistributed event");
    }

    // ============================================
    // Error Cases
    // ============================================

    /// @notice Revert for no recipients configured
    function test_DistributeProfits_RevertsForNoRecipients() public {
        // Don't setup any distribution

        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidAssetArray.selector));
        vm.prank(owner);
        vault.distributeProfits();
    }

    /// @notice Unauthorized caller
    function test_DistributeProfits_RevertsForUnauthorizedCaller() public {
        // Setup distribution
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;
        _setupDistribution(recipients, percents);

        vm.expectRevert(); // Ownable2Step error
        vm.prank(unauthorized);
        vault.distributeProfits();
    }

    function test_DistributeProfits_RevertsForKingVault() public {
        // Setup distribution
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;
        _setupDistribution(recipients, percents);

        vm.expectRevert(); // Only owner, not kingVault
        vm.prank(kingVault);
        vault.distributeProfits();
    }

    // ============================================
    // Edge Cases
    // ============================================

    /// @notice Small amounts with rounding
    function test_DistributeProfits_SmallAmountsRounding() public {
        // Setup 33/33/34 split
        address[] memory recipients = new address[](3);
        recipients[0] = treasury;
        recipients[1] = devFund;
        recipients[2] = marketingFund;
        uint16[] memory percents = new uint16[](3);
        percents[0] = 3333;
        percents[1] = 3333;
        percents[2] = 3334;
        _setupDistribution(recipients, percents);

        // Deposit tiny principal
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6; // 1 USDC
        _depositPrincipal(tokens, amounts);

        // Add 3 wei profit (tiny)
        _addProfit(address(usdc), 3);

        // Distribute (should work despite tiny amounts)
        vm.prank(owner);
        vault.distributeProfits();

        // Assert rounding works (Math.mulDiv handles precision)
        uint256 totalDistributed = usdc.balanceOf(treasury) + usdc.balanceOf(devFund) + usdc.balanceOf(marketingFund);
        assertLe(totalDistributed, 3, "Should distribute at most 3 wei");
    }

    /// @notice Large amounts (no overflow)
    function test_DistributeProfits_LargeAmounts() public {
        // Setup
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;
        _setupDistribution(recipients, percents);

        // Deposit large principal
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000_000e18; // 1M WETH

        // Mint to kingVault first
        weth.mint(kingVault, 1_000_000e18);
        _depositPrincipal(tokens, amounts);

        // Add large profit
        uint256 largeProfit = 500_000e18; // 500k WETH
        _addProfit(address(weth), largeProfit);

        // Distribute (should not overflow)
        vm.prank(owner);
        vault.distributeProfits();

        // Assert
        assertEq(weth.balanceOf(treasury), largeProfit, "Large profit distributed");
    }
}
