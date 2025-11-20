// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingTokenizedVault} from "../../../src/vaults/KingTokenizedVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPriceProvider} from "../../mocks/MockPriceProvider.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";
import {MockKingVaultController} from "../../mocks/MockKingVaultController.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title KingTokenizedVault_TVLTest
 * @notice Comprehensive test suite for KingTokenizedVault TVL calculation (Feature 6)
 * @dev Tests the tvl() function that calculates value based on deposited principal
 *
 * Test Coverage:
 * 1. Empty State - No deposits
 * 2. Single Asset - WETH only
 * 3. Multi-Asset Scenarios - Multiple tokens with different decimals
 * 4. Deployment Impact - TVL stays constant when deploying to ERC-4626
 * 5. Withdrawal Impact - TVL decreases when withdrawing back to kingVault
 * 6. Edge Cases - Zero values, price failures, small/large amounts
 * 7. Price Changes - Oracle price updates affect TVL
 *
 * Architecture Context:
 * - KingTokenizedVault extends KingVault which tracks principal in _deposits
 * - _deposits[asset] represents total principal deposited from kingVault
 * - TVL is based on deposited amounts, NOT current balances or share values
 * - Deployment to ERC-4626 vault does NOT change _deposits (principal stays constant)
 * - TVL does NOT include yield/appreciation from shares (only principal)
 *
 * TVL Formula (Simple):
 *   For each asset:
 *     assetValue = _deposits[asset] × oracle.getPriceInEth(asset)
 *   Total TVL (ETH) = sum of all assetValues
 *   Total TVL (USD) = ETH Value × ETH/USD Price
 *
 * Key Insight:
 * - TVL represents the value of deposited principal, not current asset value
 * - This provides stable TVL tracking regardless of deployment status
 * - Yield/profit is tracked separately via calculateProfit() function
 */
contract KingTokenizedVault_TVLTest is Test {
    // ============================================
    // Contracts
    // ============================================

    /// @dev The KingTokenizedVault proxy instance being tested
    KingTokenizedVault public tokenizedVault;

    /// @dev The implementation contract for UUPS proxy pattern
    KingTokenizedVault public implementation;

    /// @dev Mock WETH token (18 decimals) - used as ERC-4626 underlying asset
    MockERC20 public weth;

    /// @dev Mock USDC token (6 decimals) - used for multi-asset testing
    MockERC20 public usdc;

    /// @dev Mock USDT token (6 decimals) - used for multi-asset testing
    MockERC20 public usdt;

    /// @dev Mock price provider (converts assets to ETH for TVL calculation)
    MockPriceProvider public priceProvider;

    /// @dev Mock ERC-4626 vault with configurable exchange rate for testing share appreciation
    MockERC4626Vault public erc4626Vault;

    // ============================================
    // Test Addresses
    // ============================================

    /// @dev Contract owner - can call onlyOwner functions
    address public owner = address(0x1);

    /// @dev King Protocol main vault - authorized to deposit/withdraw assets
    address public kingVault;

    // ============================================
    // Constants
    // ============================================

    /// @dev Default slippage tolerance: 50 BPS = 0.5%
    uint16 public constant DEFAULT_SLIPPAGE_BPS = 50;

    /// @dev Default withdrawal request duration: 7 days (for async mode)
    uint64 public constant DEFAULT_WITHDRAWAL_DURATION = 7 days;

    /// @dev ETH price in USD for testing (e.g., $2000/ETH)
    uint256 public constant ETH_USD_PRICE = 2000e18;

    /// @dev WETH price in ETH (always 1:1)
    uint256 public constant WETH_ETH_PRICE = 1e18;

    /// @dev USDC price in ETH (example: $0.50 worth of ETH)
    uint256 public constant USDC_ETH_PRICE = 0.00025e18; // $0.50 / $2000 = 0.00025 ETH

    /// @dev USDT price in ETH (example: $0.50 worth of ETH)
    uint256 public constant USDT_ETH_PRICE = 0.00025e18; // $0.50 / $2000 = 0.00025 ETH

    // ============================================
    // Helpers
    // ============================================

    /**
     * @notice Helper to deposit assets to KingTokenizedVault
     * @dev Wraps single asset/amount into arrays for deposit() function
     * @param asset Token address to deposit
     * @param amount Token amount to deposit
     */
    function _depositToKingTokenizedVault(address asset, uint256 amount) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        tokenizedVault.deposit(assets, amounts);
    }

    // ============================================
    // Setup
    // ============================================

    /**
     * @notice Test setup - deploys contracts and configures initial state
     * @dev Sets up:
     *      - Mock tokens (WETH 18 decimals, USDC/USDT 6 decimals)
     *      - Mock ERC-4626 vault (accepts WETH)
     *      - Mock price provider with test prices
     *      - KingTokenizedVault in atomic mode
     *      - Registers WETH as accepted asset
     *      - Funds kingVault with tokens for deposits
     */
    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Deploy mock tokens with different decimals
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // Deploy mock ERC-4626 vault (WETH vault)
        erc4626Vault = new MockERC4626Vault(weth, "Vault WETH", "vWETH");

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(ETH_USD_PRICE);
        priceProvider.setPrice(address(weth), WETH_ETH_PRICE);
        priceProvider.setPrice(address(usdc), USDC_ETH_PRICE);
        priceProvider.setPrice(address(usdt), USDT_ETH_PRICE);

        // Deploy KingTokenizedVault implementation (atomic mode)
        implementation = new KingTokenizedVault(address(erc4626Vault), true);

        // Prepare initial assets
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tokenizedVault = KingTokenizedVault(address(proxy));

        // Fund king vault with tokens
        weth.mint(kingVault, 1000 ether);
        usdc.mint(kingVault, 1_000_000e6); // 1M USDC
        usdt.mint(kingVault, 1_000_000e6); // 1M USDT

        // Approve vault to spend tokens
        vm.startPrank(kingVault);
        weth.approve(address(tokenizedVault), type(uint256).max);
        usdc.approve(address(tokenizedVault), type(uint256).max);
        usdt.approve(address(tokenizedVault), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================
    // Test: Empty State
    // ============================================

    /**
     * @notice Test TVL returns zero when vault is empty
     * @dev Verifies:
     *      - No deposits made to vault
     *      - No shares deployed to ERC-4626
     *      - TVL should be 0 ETH and 0 USD
     *      - Function doesn't revert on empty state
     */
    function test_tvl_EmptyVault() public view {
        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        assertEq(ethValue, 0, "ETH TVL should be 0 for empty vault");
        assertEq(usdValue, 0, "USD TVL should be 0 for empty vault");
    }

    // ============================================
    // Test: Idle Assets Only
    // ============================================

    /**
     * @notice Test TVL with only idle assets (no deployment)
     * @dev Scenario:
     *      - Deposit 10 WETH to KingTokenizedVault
     *      - DO NOT deploy to ERC-4626 vault
     *      - Assets remain "idle" in the vault
     *
     * Expected TVL Calculation:
     *      - Idle WETH: 10 WETH * 1 ETH/WETH = 10 ETH
     *      - Deployed: 0 (no deployment)
     *      - Total ETH: 10 ETH
     *      - Total USD: 10 ETH * $2000/ETH = $20,000
     */
    function test_tvl_IdleAssetsOnly() public {
        // Deposit 10 WETH (remains idle, not deployed)
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        // Check TVL
        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        // Verify ETH value: 10 WETH * 1 ETH/WETH = 10 ETH
        assertEq(ethValue, 10 ether, "ETH TVL should equal idle WETH value");

        // Verify USD value: 10 ETH * $2000/ETH = $20,000
        assertEq(usdValue, 20_000 ether, "USD TVL should be 10 ETH * $2000");
    }

    /**
     * @notice Test TVL with multiple idle assets
     * @dev Scenario:
     *      - Deposit 5 WETH (18 decimals)
     *      - Deposit 10,000 USDC (6 decimals)
     *      - Neither deployed to vault
     *
     * Expected TVL Calculation:
     *      - Idle WETH: 5 WETH * 1 ETH/WETH = 5 ETH
     *      - Idle USDC: 10,000 USDC * 0.00025 ETH/USDC = 2.5 ETH
     *      - Total ETH: 5 + 2.5 = 7.5 ETH
     *      - Total USD: 7.5 ETH * $2000/ETH = $15,000
     */
    function test_tvl_MultipleIdleAssets() public {
        // Register USDC
        vm.startPrank(owner);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        tokenizedVault.registerAssets(assets, accepted);
        vm.stopPrank();

        // Deposit assets (both remain idle)
        vm.startPrank(kingVault);
        _depositToKingTokenizedVault(address(weth), 5 ether);
        _depositToKingTokenizedVault(address(usdc), 10_000e6);
        vm.stopPrank();

        // Check TVL
        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        // Expected: 5 ETH (WETH) + 2.5 ETH (USDC) = 7.5 ETH
        assertEq(ethValue, 7.5 ether, "ETH TVL should sum both idle assets");

        // Expected: 7.5 ETH * $2000/ETH = $15,000
        assertEq(usdValue, 15_000 ether, "USD TVL should be 7.5 ETH * $2000");
    }

    // ============================================
    // Test: Deployed Assets Only
    // ============================================

    /**
     * @notice Test TVL remains constant when assets are deployed
     * @dev Scenario:
     *      - Deposit 20 WETH to KingTokenizedVault (_deposits[weth] = 20 ether)
     *      - Deploy ALL 20 WETH to ERC-4626 vault
     *      - TVL should remain the same (based on _deposits, not balances)
     *
     * Expected TVL Calculation:
     *      - Principal (_deposits[weth]): 20 WETH
     *      - TVL = 20 WETH * 1 ETH/WETH = 20 ETH
     *      - Deployment does NOT change _deposits
     *      - Total ETH: 20 ETH (before and after deployment)
     *      - Total USD: 20 ETH * $2000/ETH = $40,000
     *
     * Key Test: TVL stays constant when deploying to ERC-4626
     */
    function test_tvl_DeployedAssetsOnly() public {
        // Deposit 20 WETH (_deposits[weth] = 20 ether)
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 20 ether);

        // Check TVL before deployment
        (uint256 ethBefore,) = tokenizedVault.tvl();
        assertEq(ethBefore, 20 ether, "TVL before deployment: 20 ETH principal");

        // Deploy all to ERC-4626 vault (balances change, _deposits stays same)
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        // Check TVL after deployment
        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        // Verify: TVL unchanged (still based on 20 WETH principal)
        assertEq(ethValue, 20 ether, "ETH TVL should equal principal (unchanged by deployment)");

        // Verify: 20 ETH * $2000/ETH = $40,000
        assertEq(usdValue, 40_000 ether, "USD TVL should be 20 ETH * $2000");
    }

    /**
     * @notice Test TVL does NOT change with share appreciation
     * @dev Scenario:
     *      - Deposit 10 WETH (_deposits[weth] = 10 ether)
     *      - Deploy to vault (receive 10 shares @ 1:1)
     *      - Simulate yield: shares appreciate to 1.5 WETH/share
     *      - TVL should remain at principal value (does NOT include yield)
     *
     * Expected TVL Calculation:
     *      - Principal (_deposits[weth]): 10 WETH
     *      - TVL = 10 WETH * 1 ETH/WETH = 10 ETH
     *      - Share appreciation does NOT affect _deposits
     *      - Total ETH: 10 ETH (constant, despite 1.5x appreciation)
     *      - Total USD: 10 ETH * $2000/ETH = $20,000
     *
     * Key Test: TVL tracks principal only, NOT yield (yield tracked by calculateProfit)
     */
    function test_tvl_WithShareAppreciation() public {
        // Deposit and deploy 10 WETH (_deposits[weth] = 10 ether)
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Simulate share appreciation: 1 share now worth 1.5 WETH
        erc4626Vault.setExchangeRate(1.5e18);

        // Check TVL
        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        // Verify: TVL unchanged at principal (10 WETH), NOT share value (15 WETH)
        assertEq(ethValue, 10 ether, "ETH TVL should equal principal (ignores appreciation)");

        // Verify: 10 ETH * $2000/ETH = $20,000
        assertEq(usdValue, 20_000 ether, "USD TVL should be 10 ETH * $2000");
    }

    /**
     * @notice Test TVL remains at principal despite significant share appreciation
     * @dev Scenario:
     *      - Deposit 100 WETH (_deposits[weth] = 100 ether)
     *      - Deploy to vault (100 shares @ 1:1)
     *      - Shares double in value to 2.0 WETH/share
     *      - TVL should remain at principal (does NOT include 100% gain)
     *
     * Expected TVL Calculation:
     *      - Principal (_deposits[weth]): 100 ETH
     *      - TVL = 100 WETH * 1 ETH/WETH = 100 ETH
     *      - Share value doubles to 200 ETH, but TVL stays at 100 ETH
     *      - Profit (100 ETH) tracked separately via calculateProfit()
     */
    function test_tvl_SignificantAppreciation() public {
        // Deposit and deploy 100 WETH (_deposits[weth] = 100 ether)
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 100 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 100 ether);

        // Double share value to 2.0 WETH/share
        erc4626Vault.setExchangeRate(2.0e18);

        // Check TVL
        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        // Verify: TVL stays at principal (100 ETH), NOT share value (200 ETH)
        assertEq(ethValue, 100 ether, "TVL should remain at principal (ignores 2x appreciation)");
        assertEq(usdValue, 200_000 ether, "USD TVL: 100 ETH * $2000");
    }

    // ============================================
    // Test: Mixed Idle and Deployed
    // ============================================

    /**
     * @notice Test TVL based on principal regardless of idle/deployed split
     * @dev Scenario:
     *      - Deposit 30 WETH (_deposits[weth] = 30 ether)
     *      - Deploy 20 WETH to vault (10 remains idle in contract)
     *      - TVL should be based on total principal, not split
     *
     * Expected TVL Calculation:
     *      - Principal (_deposits[weth]): 30 WETH
     *      - TVL = 30 WETH * 1 ETH/WETH = 30 ETH
     *      - Idle vs deployed split doesn't matter (both part of principal)
     *      - Total: 30 ETH (before and after deployment)
     *
     * Key Test: TVL = principal, regardless of how assets are distributed
     */
    function test_tvl_MixedIdleAndDeployed() public {
        // Deposit 30 WETH (_deposits[weth] = 30 ether)
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 30 ether);

        // Check TVL before deployment
        (uint256 ethBefore,) = tokenizedVault.tvl();
        assertEq(ethBefore, 30 ether, "TVL before deployment: 30 ETH principal");

        // Deploy only 20 WETH (10 remains idle, _deposits stays 30)
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        // Check TVL after deployment
        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        // Verify: TVL unchanged (based on 30 WETH principal, not idle/deployed split)
        assertEq(ethValue, 30 ether, "TVL should equal principal (unchanged by deployment)");
        assertEq(usdValue, 60_000 ether, "USD TVL: 30 ETH * $2000");
    }

    /**
     * @notice Test TVL with multiple assets ignores appreciation
     * @dev Complex scenario:
     *      - Deposit 15 WETH (_deposits[weth] = 15 ether)
     *      - Deploy 10 WETH to vault (5 remains idle)
     *      - Register and deposit 20,000 USDC (_deposits[usdc] = 20,000e6)
     *      - Shares appreciate to 1.8 WETH/share
     *      - TVL should be based on principal only
     *
     * Expected TVL Calculation:
     *      - WETH principal: 15 WETH * 1 ETH/WETH = 15 ETH
     *      - USDC principal: 20,000 USDC * 0.00025 ETH/USDC = 5 ETH
     *      - Total: 15 + 5 = 20 ETH (ignores share appreciation)
     *
     * Key Test: Multi-asset principal tracking, ignoring deployment and appreciation
     */
    function test_tvl_ComplexMixedScenario() public {
        // Register USDC
        vm.startPrank(owner);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        tokenizedVault.registerAssets(assets, accepted);
        vm.stopPrank();

        // Deposit assets (_deposits[weth] = 15 ether, _deposits[usdc] = 20,000e6)
        vm.startPrank(kingVault);
        _depositToKingTokenizedVault(address(weth), 15 ether);
        _depositToKingTokenizedVault(address(usdc), 20_000e6);
        vm.stopPrank();

        // Deploy 10 WETH (5 WETH and all USDC remain idle)
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Simulate appreciation (should NOT affect TVL)
        erc4626Vault.setExchangeRate(1.8e18);

        // Check TVL
        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        // Expected: 15 ETH (WETH principal) + 5 ETH (USDC principal) = 20 ETH
        assertEq(ethValue, 20 ether, "TVL should sum principals (ignores appreciation)");
        assertEq(usdValue, 40_000 ether, "USD TVL: 20 ETH * $2000");
    }

    // ============================================
    // Test: Edge Cases
    // ============================================

    /**
     * @notice Test TVL with very small amounts (dust)
     * @dev Verifies precision handling with small values
     *      - 0.001 WETH (1e15 wei)
     *      - Should not lose precision or revert
     */
    function test_tvl_SmallAmounts() public {
        // Deposit tiny amount
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 0.001 ether);

        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        assertEq(ethValue, 0.001 ether, "Should handle small amounts precisely");
        assertEq(usdValue, 2 ether, "USD: 0.001 ETH * $2000 = $2");
    }

    /**
     * @notice Test TVL with large amounts
     * @dev Verifies no overflow with large values
     *      - 1,000,000 WETH (1M ETH)
     *      - Tests Math.mulDiv overflow protection
     */
    function test_tvl_LargeAmounts() public {
        // Mint and deposit large amount
        weth.mint(kingVault, 1_000_000 ether);

        vm.startPrank(kingVault);
        weth.approve(address(tokenizedVault), type(uint256).max);
        _depositToKingTokenizedVault(address(weth), 1_000_000 ether);
        vm.stopPrank();

        (uint256 ethValue, uint256 usdValue) = tokenizedVault.tvl();

        assertEq(ethValue, 1_000_000 ether, "Should handle large amounts");
        assertEq(usdValue, 2_000_000_000 ether, "USD: 1M ETH * $2000 = $2B");
    }

    /**
     * @notice Test TVL stays constant after withdrawing from vault (not from kingVault)
     * @dev Scenario:
     *      - Deposit 50 WETH (_deposits[weth] = 50 ether)
     *      - Deploy all to ERC-4626 vault
     *      - Withdraw 20 WETH back from vault to contract (Type A - principal)
     *      - _deposits[weth] remains 50 ether (only changes on kingVault withdrawal)
     *      - TVL should remain constant
     *
     * Expected:
     *      - Initial TVL: 50 ETH (principal)
     *      - After vault withdrawal: 50 ETH (principal unchanged)
     *      - Composition changes (30 deployed + 20 idle), but principal stays same
     *      - (Note: In atomic mode, withdrawal completes immediately)
     */
    function test_tvl_AfterPartialWithdrawal() public {
        // Deposit and deploy 50 WETH (_deposits[weth] = 50 ether)
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 50 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 50 ether);

        // Check initial TVL
        (uint256 ethBefore,) = tokenizedVault.tvl();
        assertEq(ethBefore, 50 ether, "Initial TVL should be 50 ETH principal");

        // Withdraw 20 WETH from ERC-4626 vault back to contract
        // isProfitWithdrawal = false (Type A - principal withdrawal)
        // _deposits[weth] stays 50 ether (only kingVault withdrawals change _deposits)
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(address(weth), 20 ether, false);

        // Check TVL after withdrawal
        (uint256 ethAfter,) = tokenizedVault.tvl();

        // TVL unchanged: still based on 50 WETH principal
        // Composition: 30 deployed + 20 idle = 50 total
        assertEq(ethAfter, 50 ether, "TVL should remain 50 ETH (principal unchanged)");
    }

    /**
     * @notice Test TVL calculation with different decimal tokens
     * @dev Verifies proper decimal handling:
     *      - WETH: 18 decimals
     *      - USDC: 6 decimals
     *      - USDT: 6 decimals
     *
     * All should be correctly normalized to ETH (18 decimals)
     */
    function test_tvl_DifferentDecimals() public {
        // Register USDC and USDT
        vm.startPrank(owner);
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdt);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;
        tokenizedVault.registerAssets(assets, accepted);
        vm.stopPrank();

        // Deposit different decimal tokens
        vm.startPrank(kingVault);
        _depositToKingTokenizedVault(address(weth), 1 ether); // 18 decimals
        _depositToKingTokenizedVault(address(usdc), 4_000e6); // 6 decimals
        _depositToKingTokenizedVault(address(usdt), 4_000e6); // 6 decimals
        vm.stopPrank();

        (uint256 ethValue,) = tokenizedVault.tvl();

        // Expected:
        // WETH: 1 * 1 = 1 ETH
        // USDC: 4000 * 0.00025 = 1 ETH
        // USDT: 4000 * 0.00025 = 1 ETH
        // Total: 3 ETH
        assertEq(ethValue, 3 ether, "Should normalize different decimals correctly");
    }

    /**
     * @notice Test TVL stays constant after full vault withdrawal
     * @dev Scenario:
     *      - Deposit 25 WETH (_deposits[weth] = 25 ether)
     *      - Deploy all to vault
     *      - Withdraw all from vault back to contract
     *      - _deposits[weth] remains 25 ether
     *      - TVL should remain constant (principal unchanged)
     *
     * Key Test: Withdrawing from vault to contract doesn't change TVL
     */
    function test_tvl_AfterFullWithdrawal() public {
        // Deposit and deploy 25 WETH (_deposits[weth] = 25 ether)
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 25 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 25 ether);

        // Withdraw everything from vault (Type A - principal)
        // _deposits[weth] stays 25 ether
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(address(weth), 25 ether, false);

        // TVL unchanged: 25 ETH principal (now all idle in contract)
        (uint256 ethValue,) = tokenizedVault.tvl();
        assertEq(ethValue, 25 ether, "TVL should remain 25 ETH (principal unchanged)");
    }

    // ============================================
    // Test: Price Changes
    // ============================================

    /**
     * @notice Test TVL responds to ETH price changes
     * @dev Scenario:
     *      - Deposit 10 WETH
     *      - ETH price changes from $2000 to $3000
     *      - ETH TVL stays same, USD TVL increases
     */
    function test_tvl_EthPriceChange() public {
        // Deposit WETH
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(weth), 10 ether);

        // Check initial TVL
        (uint256 ethBefore, uint256 usdBefore) = tokenizedVault.tvl();
        assertEq(ethBefore, 10 ether, "ETH value: 10 ETH");
        assertEq(usdBefore, 20_000 ether, "USD value: 10 * $2000 = $20k");

        // Change ETH price to $3000
        priceProvider = new MockPriceProvider(3000e18);
        priceProvider.setPrice(address(weth), WETH_ETH_PRICE);

        // Update tokenized vault to use new price provider
        vm.prank(owner);
        tokenizedVault.setPriceProvider(address(priceProvider));

        // Check new TVL
        (uint256 ethAfter, uint256 usdAfter) = tokenizedVault.tvl();
        assertEq(ethAfter, 10 ether, "ETH value unchanged: 10 ETH");
        assertEq(usdAfter, 30_000 ether, "USD value increased: 10 * $3000 = $30k");
    }

    /**
     * @notice Test TVL responds to asset price changes
     * @dev Scenario:
     *      - Deposit USDC
     *      - USDC price in ETH changes
     *      - TVL should reflect new price
     */
    function test_tvl_AssetPriceChange() public {
        // Register USDC
        vm.startPrank(owner);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;
        tokenizedVault.registerAssets(assets, accepted);
        vm.stopPrank();

        // Deposit USDC
        vm.prank(kingVault);
        _depositToKingTokenizedVault(address(usdc), 10_000e6);

        // Initial: 10,000 USDC * 0.00025 ETH/USDC = 2.5 ETH
        (uint256 ethBefore,) = tokenizedVault.tvl();
        assertEq(ethBefore, 2.5 ether, "Initial: 10k USDC = 2.5 ETH");

        // Change USDC price (double it)
        priceProvider.setPrice(address(usdc), 0.0005e18);

        // New: 10,000 USDC * 0.0005 ETH/USDC = 5 ETH
        (uint256 ethAfter,) = tokenizedVault.tvl();
        assertEq(ethAfter, 5 ether, "After price change: 10k USDC = 5 ETH");
    }
}
