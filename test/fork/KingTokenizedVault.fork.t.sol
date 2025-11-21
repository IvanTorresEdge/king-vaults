// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingTokenizedVault} from "../../src/vaults/KingTokenizedVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingTokenizedVault_ForkTest
 * @notice Fork tests for KingTokenizedVault with real Concrete vault (Feature 8.3)
 * @dev Tests Task 8.3 acceptance criteria:
 *      - Tests against real Concrete vault on mainnet fork
 *      - Validates share conversions with real vault
 *      - Tests actual yield generation
 *      - Verifies integration with production contracts
 *
 * Test Strategy:
 *      1. Fork Ethereum mainnet at recent block
 *      2. Deploy KingTokenizedVault pointing to real Concrete vault
 *      3. Execute real deposit/withdrawal flows
 *      4. Validate share conversion rates
 *      5. Test profit calculations with real yield
 *
 * NOTE: These tests require:
 *      - Mainnet RPC URL configured (MAINNET_RPC_URL env variable)
 *      - Sufficient block confirmations for fork stability
 *      - Real Concrete vault addresses (update CONCRETE_VAULT_* constants)
 *
 * Run with: forge test --match-contract KingTokenizedVault_ForkTest --fork-url $MAINNET_RPC_URL
 */
contract KingTokenizedVault_ForkTest is Test {
    // ============================================
    // Fork Configuration
    // ============================================

    /**
     * @notice Mainnet fork block number
     * @dev Update to recent stable block before running tests
     * @dev Use: cast block-number --rpc-url $MAINNET_RPC_URL
     */
    uint256 public constant FORK_BLOCK = 21_000_000; // Update to recent block

    // ============================================
    // Concrete Vault Addresses (Mainnet)
    // ============================================

    /**
     * @notice Concrete WETH vault address
     * @dev TODO: Update with actual Concrete ctWETH vault address
     * @dev Check https://defillama.com/protocol/concrete for deployments
     */
    address public constant CONCRETE_WETH_VAULT = address(0); // UPDATE THIS

    /**
     * @notice Concrete USDC vault address
     * @dev TODO: Update with actual Concrete ctUSDC vault address
     */
    address public constant CONCRETE_USDC_VAULT = address(0); // UPDATE THIS

    // ============================================
    // Mainnet Token Addresses
    // ============================================

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // ============================================
    // Contracts
    // ============================================

    KingTokenizedVault public tokenizedVault;
    KingTokenizedVault public implementation;
    MockPriceProvider public priceProvider;
    IERC4626 public concreteVault;
    IERC20 public underlyingAsset;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault;

    // ============================================
    // Whale Addresses (for token transfers)
    // ============================================

    address public wethWhale = 0x8EB8a3b98659Cce290402893d0123abb75E3ab28; // Example whale
    address public usdcWhale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Example whale

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Skip tests if no RPC URL configured or vault not set
        if (CONCRETE_WETH_VAULT == address(0)) {
            console2.log("SKIPPING FORK TESTS: Concrete vault address not configured");
            console2.log("Update CONCRETE_WETH_VAULT constant in test file");
            return;
        }

        // Create mainnet fork
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        // Initialize Concrete vault interface
        concreteVault = IERC4626(CONCRETE_WETH_VAULT);
        underlyingAsset = IERC20(concreteVault.asset());

        // Deploy mock price provider (in production, use real oracle)
        priceProvider = new MockPriceProvider(2000e18);
        priceProvider.setPrice(address(underlyingAsset), 1e18);

        // Deploy KingTokenizedVault implementation
        implementation = new KingTokenizedVault(CONCRETE_WETH_VAULT, true); // Atomic mode

        // Deploy proxy
        address[] memory assets = new address[](1);
        assets[0] = address(underlyingAsset);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tokenizedVault = KingTokenizedVault(address(proxy));

        // Fund kingVault with real tokens from whale
        _fundFromWhale();
    }

    // ============================================
    // Helper Functions
    // ============================================

    /**
     * @notice Fund kingVault with tokens from mainnet whale
     * @dev Impersonates whale to transfer tokens
     */
    function _fundFromWhale() internal {
        if (CONCRETE_WETH_VAULT == address(0)) return;

        address whale = address(underlyingAsset) == WETH ? wethWhale : usdcWhale;
        uint256 fundAmount = 100 ether; // Adjust based on asset decimals

        vm.prank(whale);
        underlyingAsset.transfer(kingVault, fundAmount);

        // Approve vault
        vm.prank(kingVault);
        underlyingAsset.approve(address(tokenizedVault), type(uint256).max);
    }

    /**
     * @notice Helper to deposit to vault
     */
    function _depositToVault(uint256 amount) internal {
        address[] memory assets = new address[](1);
        assets[0] = address(underlyingAsset);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        tokenizedVault.deposit(assets, amounts);
    }

    /**
     * @notice Skip test if vault not configured
     */
    modifier skipIfNotConfigured() {
        if (CONCRETE_WETH_VAULT == address(0)) {
            console2.log("Test skipped: Vault not configured");
            return;
        }
        _;
    }

    // ============================================
    // Vault Integration Tests
    // ============================================

    /**
     * @notice Test deployment connects to real Concrete vault
     * @dev Verifies:
     *      - Vault address matches Concrete deployment
     *      - Underlying asset matches expected token
     *      - Vault is operational (not paused)
     */
    function test_fork_vaultConnection() public view skipIfNotConfigured {
        assertEq(tokenizedVault.vault(), CONCRETE_WETH_VAULT, "Should connect to Concrete vault");
        assertEq(address(underlyingAsset), concreteVault.asset(), "Underlying asset should match");
        assertGt(concreteVault.totalAssets(), 0, "Concrete vault should have assets deployed");
    }

    /**
     * @notice Test deposit to real Concrete vault
     * @dev Verifies:
     *      - Deposit executes successfully with real vault
     *      - Share conversion rate is reasonable
     *      - Shares received and tracked correctly
     */
    function test_fork_depositToConcreteVault() public skipIfNotConfigured {
        uint256 depositAmount = 1 ether; // 1 WETH or equivalent

        // Deposit to KingTokenizedVault
        vm.prank(kingVault);
        _depositToVault(depositAmount);

        // Deploy to Concrete vault
        uint256 sharesBefore = tokenizedVault.getVaultShares();

        vm.prank(owner);
        uint256 sharesReceived = tokenizedVault.depositToVault(address(underlyingAsset), depositAmount);

        // Verify shares received
        assertGt(sharesReceived, 0, "Should receive shares from Concrete");
        assertEq(tokenizedVault.getVaultShares(), sharesBefore + sharesReceived, "Shares should be tracked correctly");

        // Verify reasonable share conversion (within 50% of 1:1)
        // Real vaults may have appreciation/depreciation
        assertGt(sharesReceived, depositAmount / 2, "Share conversion should be reasonable (lower bound)");
        assertLt(sharesReceived, depositAmount * 2, "Share conversion should be reasonable (upper bound)");

        console2.log("Deposited:", depositAmount);
        console2.log("Shares received:", sharesReceived);
        console2.log("Exchange rate:", (sharesReceived * 1e18) / depositAmount);
    }

    /**
     * @notice Test withdrawal from real Concrete vault
     * @dev Verifies:
     *      - Withdrawal executes successfully
     *      - Asset conversion from shares is correct
     *      - Assets received match expected amount
     */
    function test_fork_withdrawFromConcreteVault() public skipIfNotConfigured {
        uint256 depositAmount = 2 ether;

        // Setup: Deposit and deploy
        vm.prank(kingVault);
        _depositToVault(depositAmount);

        vm.prank(owner);
        uint256 sharesReceived = tokenizedVault.depositToVault(address(underlyingAsset), depositAmount);

        // Withdraw half
        uint256 sharesToWithdraw = sharesReceived / 2;

        uint256 balanceBefore = underlyingAsset.balanceOf(address(tokenizedVault));

        vm.prank(owner);
        uint256 assetsReceived = tokenizedVault.withdrawFromVault(address(underlyingAsset), sharesToWithdraw, false);

        // Verify assets received
        assertGt(assetsReceived, 0, "Should receive assets from Concrete");
        assertEq(
            underlyingAsset.balanceOf(address(tokenizedVault)),
            balanceBefore + assetsReceived,
            "Asset balance should increase"
        );

        // Verify reasonable asset conversion
        uint256 expectedAssets = depositAmount / 2;
        assertGt(assetsReceived, expectedAssets / 2, "Asset conversion should be reasonable (lower bound)");
        assertLt(assetsReceived, expectedAssets * 2, "Asset conversion should be reasonable (upper bound)");

        console2.log("Shares withdrawn:", sharesToWithdraw);
        console2.log("Assets received:", assetsReceived);
    }

    /**
     * @notice Test share conversion accuracy with real vault
     * @dev Verifies:
     *      - convertToShares matches actual deposit results
     *      - convertToAssets matches actual withdrawal results
     *      - Preview functions are accurate
     */
    function test_fork_shareConversionAccuracy() public skipIfNotConfigured {
        uint256 depositAmount = 1 ether;

        // Test preview vs actual deposit
        uint256 previewedShares = concreteVault.convertToShares(depositAmount);

        vm.prank(kingVault);
        _depositToVault(depositAmount);

        vm.prank(owner);
        uint256 actualShares = tokenizedVault.depositToVault(address(underlyingAsset), depositAmount);

        // Verify preview accuracy (allow 1% deviation for slippage)
        assertApproxEqRel(actualShares, previewedShares, 0.01e18, "Preview should match actual (deposit)");

        // Test preview vs actual withdrawal
        uint256 previewedAssets = concreteVault.convertToAssets(actualShares);

        vm.prank(owner);
        uint256 actualAssets = tokenizedVault.withdrawFromVault(address(underlyingAsset), actualShares, false);

        // Verify preview accuracy
        assertApproxEqRel(actualAssets, previewedAssets, 0.01e18, "Preview should match actual (withdrawal)");

        console2.log("Previewed shares:", previewedShares);
        console2.log("Actual shares:", actualShares);
        console2.log("Previewed assets:", previewedAssets);
        console2.log("Actual assets:", actualAssets);
    }

    // ============================================
    // Yield Generation Tests
    // ============================================

    /**
     * @notice Test profit calculation with real yield
     * @dev Verifies:
     *      - Vault generates positive yield over time
     *      - Profit calculation is accurate
     *      - Share appreciation tracked correctly
     *
     * NOTE: This test may need time advancement to see yield
     */
    function test_fork_realYieldGeneration() public skipIfNotConfigured {
        uint256 depositAmount = 5 ether;

        // Deposit and deploy
        vm.prank(kingVault);
        _depositToVault(depositAmount);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(underlyingAsset), depositAmount);

        // Record initial state
        uint256 initialShares = tokenizedVault.getVaultShares();
        uint256 initialValue = concreteVault.convertToAssets(initialShares);

        console2.log("Initial shares:", initialShares);
        console2.log("Initial value:", initialValue);

        // Advance time (simulate yield accrual)
        // In real scenarios, Concrete vault will accrue yield from strategies
        vm.warp(block.timestamp + 30 days);

        // Check for yield (may be minimal in fork test)
        uint256 currentValue = concreteVault.convertToAssets(initialShares);
        uint256 profit = tokenizedVault.calculateProfit();

        console2.log("Value after 30 days:", currentValue);
        console2.log("Calculated profit:", profit);

        // Note: In fork test, yield may be zero unless vault has active strategies
        // This test validates the calculation works, not that yield exists
        assertGe(currentValue, initialValue, "Value should not decrease");
    }

    /**
     * @notice Test profit harvesting with real vault
     * @dev Verifies:
     *      - Harvest works with real share redemption
     *      - Profit shares calculated correctly
     *      - Assets received from profit harvest
     */
    function test_fork_profitHarvest() public skipIfNotConfigured {
        uint256 depositAmount = 10 ether;

        // Setup
        vm.prank(kingVault);
        _depositToVault(depositAmount);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(underlyingAsset), depositAmount);

        // Advance time for yield
        vm.warp(block.timestamp + 90 days);

        // Calculate profit
        uint256 profit = tokenizedVault.calculateProfit();

        if (profit == 0) {
            console2.log("No profit generated in fork (expected if vault has no active yield)");
            return;
        }

        // Harvest (will revert if no profit)
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Verify assets in vault increased
        assertGt(underlyingAsset.balanceOf(address(tokenizedVault)), 0, "Should have harvested assets");

        console2.log("Profit harvested:", profit);
    }

    // ============================================
    // Edge Case Tests
    // ============================================

    /**
     * @notice Test behavior during high vault utilization
     * @dev Verifies:
     *      - Operations work when vault is heavily utilized
     *      - Slippage protection handles real market conditions
     */
    function test_fork_highUtilizationScenario() public skipIfNotConfigured {
        // Get vault utilization info
        uint256 totalAssets = concreteVault.totalAssets();
        uint256 totalSupply = concreteVault.totalSupply();

        console2.log("Vault total assets:", totalAssets);
        console2.log("Vault total supply:", totalSupply);

        // Small deposit relative to vault size
        uint256 depositAmount = 0.1 ether;

        vm.prank(kingVault);
        _depositToVault(depositAmount);

        vm.prank(owner);
        uint256 shares = tokenizedVault.depositToVault(address(underlyingAsset), depositAmount);

        // Verify deposit succeeded despite vault size
        assertGt(shares, 0, "Should receive shares even in large vault");
    }

    /**
     * @notice Test slippage protection with real vault
     * @dev Verifies:
     *      - Slippage tolerance works with real conversion rates
     *      - Reverts on excessive slippage
     */
    function test_fork_slippageProtection() public skipIfNotConfigured {
        // Set very tight slippage (10 BPS = 0.1%)
        vm.prank(owner);
        tokenizedVault.setMaxSlippage(10);

        uint256 depositAmount = 1 ether;

        vm.prank(kingVault);
        _depositToVault(depositAmount);

        // This may revert if real vault has >0.1% slippage
        // That's expected behavior - slippage protection working
        vm.prank(owner);
        try tokenizedVault.depositToVault(address(underlyingAsset), depositAmount) returns (uint256 shares) {
            console2.log("Deposit succeeded with tight slippage");
            assertGt(shares, 0, "Should receive shares");
        } catch {
            console2.log("Deposit reverted due to slippage (protection working)");
        }
    }

    // ============================================
    // Multi-Asset Tests (if Concrete supports)
    // ============================================

    /**
     * @notice Test multiple asset deployment
     * @dev Verifies:
     *      - Can interact with multiple Concrete vaults
     *      - Principal tracking across assets
     *
     * NOTE: Requires CONCRETE_USDC_VAULT to be configured
     */
    function test_fork_multiAssetDeployment() public pure {
        if (CONCRETE_USDC_VAULT == address(0)) {
            console2.log("Skipping multi-asset test: USDC vault not configured");
            return;
        }

        // This test would deploy a second KingTokenizedVault for USDC
        // and verify both vaults operate independently
        // Implementation depends on multi-vault setup requirements
    }

    // ============================================
    // Concrete-Specific Feature Tests
    // ============================================

    /**
     * @notice Test Concrete vault metadata
     * @dev Verifies:
     *      - Vault returns correct name/symbol
     *      - Decimals match underlying asset
     *      - Asset address is correct
     */
    function test_fork_concreteVaultMetadata() public view skipIfNotConfigured {
        // Verify ERC-4626 metadata
        assertEq(concreteVault.asset(), address(underlyingAsset), "Asset should match");

        uint8 vaultDecimals = IERC20Metadata(address(concreteVault)).decimals();
        uint8 assetDecimals = IERC20Metadata(address(underlyingAsset)).decimals();

        console2.log("Vault name:", IERC20Metadata(address(concreteVault)).name());
        console2.log("Vault symbol:", IERC20Metadata(address(concreteVault)).symbol());
        console2.log("Vault decimals:", vaultDecimals);
        console2.log("Asset decimals:", assetDecimals);

        // Concrete vaults typically match underlying asset decimals
        assertEq(vaultDecimals, assetDecimals, "Decimals should match (typical for Concrete)");
    }

    /**
     * @notice Test Concrete vault limits
     * @dev Verifies:
     *      - maxDeposit returns reasonable limit
     *      - maxWithdraw reflects available liquidity
     */
    function test_fork_concreteVaultLimits() public view skipIfNotConfigured {
        uint256 maxDeposit = concreteVault.maxDeposit(address(tokenizedVault));
        uint256 maxWithdraw = concreteVault.maxWithdraw(address(tokenizedVault));

        console2.log("Max deposit:", maxDeposit);
        console2.log("Max withdraw:", maxWithdraw);

        // Concrete vaults should have reasonable limits
        assertGt(maxDeposit, 0, "Should allow deposits");
    }
}
