// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingTokenizedVault} from "../../src/vaults/KingTokenizedVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingTokenizedVault_IntegrationTest
 * @notice Integration tests for KingTokenizedVault dual flow architecture (Feature 8.2)
 * @dev Tests Task 8.2 acceptance criteria:
 *      - Tests Flow A independently (deposit/withdraw from main vault)
 *      - Tests Flow B independently (deploy to ERC-4626 vault)
 *      - Validates no interference between flows
 *      - Tests complete lifecycle scenarios
 *      - Validates accounting correctness across flows
 *
 * Flow Architecture:
 *      Flow A (Custody): KingVault <-> KingTokenizedVault
 *          - deposit(): Transfer assets from KingVault to vault
 *          - withdraw(): Return assets from vault to KingVault
 *          - Principal tracking in _deposits mapping
 *
 *      Flow B (Deployment): KingTokenizedVault <-> ERC-4626 Vault
 *          - depositToVault(): Deploy idle assets to ERC-4626 vault
 *          - withdrawFromVault(): Retrieve assets from ERC-4626 vault
 *          - Share tracking, profit calculation
 *
 * Critical Invariants:
 *      1. Flow A operations do NOT affect Flow B share balances
 *      2. Flow B operations do NOT affect Flow A principal tracking
 *      3. Total accounting: principal + profit = share value
 *      4. No asset leakage between flows
 */
contract KingTokenizedVault_IntegrationTest is Test {
    // ============================================
    // Contracts
    // ============================================

    KingTokenizedVault public tokenizedVault;
    KingTokenizedVault public implementation;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockPriceProvider public priceProvider;
    MockERC4626Vault public erc4626Vault;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault;
    address public unauthorized = address(0x3);

    // ============================================
    // Events
    // ============================================

    event Deposited(address[] assets, uint256[] amounts, uint256 timestamp);
    event Withdrawn(address[] assets, uint256[] amounts, address receiver, uint256 timestamp);
    event DepositCompleted(address indexed asset, uint256 amount, uint256 sharesReceived);
    event WithdrawalConfirmed(address indexed asset, uint256 amountReceived);
    event ProfitsHarvested(uint256 timestamp);
    event ProfitsDistributed(address indexed asset, uint256 amount);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mock ERC-4626 vault (WETH vault)
        erc4626Vault = new MockERC4626Vault(weth, "Vault WETH", "vWETH");

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(usdc), 0.0005e18); // 1 USDC = 0.0005 ETH

        // Deploy KingTokenizedVault (atomic mode)
        implementation = new KingTokenizedVault(address(erc4626Vault), true);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tokenizedVault = KingTokenizedVault(address(proxy));

        // Fund king vault
        weth.mint(kingVault, 1000 ether);
        vm.prank(kingVault);
        weth.approve(address(tokenizedVault), type(uint256).max);
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _depositToVault(address asset, uint256 amount) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        tokenizedVault.deposit(assets, amounts);
    }

    function _withdrawFromVault(address asset, uint256 amount, address receiver) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        tokenizedVault.withdraw(assets, amounts, receiver);
    }

    // ============================================
    // Flow A Tests - Independent Operation
    // ============================================

    /**
     * @notice Test Flow A deposit operation
     * @dev Verifies:
     *      - KingVault can deposit assets to tokenized vault
     *      - Principal tracking updated correctly
     *      - Assets transferred to vault
     *      - No shares created (Flow B not involved)
     */
    function test_flowA_deposit_Success() public {
        uint256 depositAmount = 10 ether;

        vm.expectEmit(false, false, false, false);
        emit Deposited(new address[](1), new uint256[](1), block.timestamp);

        vm.prank(kingVault);
        _depositToVault(address(weth), depositAmount);

        // Verify Flow A state
        assertEq(tokenizedVault.getBalance(address(weth)), depositAmount, "Balance should match deposit");
        assertEq(weth.balanceOf(address(tokenizedVault)), depositAmount, "Vault should hold WETH");

        // Verify Flow B not affected
        assertEq(tokenizedVault.getVaultShares(), 0, "No shares should exist");
        assertEq(erc4626Vault.balanceOf(address(tokenizedVault)), 0, "No ERC4626 shares");
    }

    /**
     * @notice Test Flow A withdraw operation
     * @dev Verifies:
     *      - KingVault can withdraw deposited assets
     *      - Principal tracking decremented
     *      - Assets returned to receiver
     *      - No interaction with Flow B
     */
    function test_flowA_withdraw_Success() public {
        // Setup: Deposit first
        vm.prank(kingVault);
        _depositToVault(address(weth), 10 ether);

        uint256 withdrawAmount = 5 ether;
        uint256 balanceBefore = weth.balanceOf(kingVault);

        vm.expectEmit(false, false, false, false);
        emit Withdrawn(new address[](1), new uint256[](1), kingVault, block.timestamp);

        vm.prank(kingVault);
        _withdrawFromVault(address(weth), withdrawAmount, kingVault);

        // Verify Flow A state
        assertEq(tokenizedVault.getBalance(address(weth)), 5 ether, "Remaining balance should be 5 ETH");
        assertEq(weth.balanceOf(kingVault), balanceBefore + withdrawAmount, "KingVault should receive WETH");

        // Verify Flow B not affected
        assertEq(tokenizedVault.getVaultShares(), 0, "No shares should exist");
    }

    /**
     * @notice Test Flow A multiple deposits and withdrawals
     * @dev Verifies:
     *      - Multiple operations maintain correct accounting
     *      - Principal tracking accurate across operations
     */
    function test_flowA_multipleOperations_Success() public {
        vm.startPrank(kingVault);

        // Deposit 10 ETH
        _depositToVault(address(weth), 10 ether);
        assertEq(tokenizedVault.getBalance(address(weth)), 10 ether);

        // Deposit 5 more ETH
        _depositToVault(address(weth), 5 ether);
        assertEq(tokenizedVault.getBalance(address(weth)), 15 ether);

        // Withdraw 3 ETH
        _withdrawFromVault(address(weth), 3 ether, kingVault);
        assertEq(tokenizedVault.getBalance(address(weth)), 12 ether);

        // Withdraw 7 ETH
        _withdrawFromVault(address(weth), 7 ether, kingVault);
        assertEq(tokenizedVault.getBalance(address(weth)), 5 ether);

        vm.stopPrank();

        // Verify no Flow B interaction
        assertEq(tokenizedVault.getVaultShares(), 0, "Should have no shares");
    }

    // ============================================
    // Flow B Tests - Independent Operation
    // ============================================

    /**
     * @notice Test Flow B deposit operation
     * @dev Verifies:
     *      - Owner can deploy idle assets to ERC-4626 vault
     *      - Shares received and tracked
     *      - Assets transferred to ERC-4626 vault
     *      - Flow A principal unchanged
     */
    function test_flowB_depositToVault_Success() public {
        // Setup: Flow A deposit first
        vm.prank(kingVault);
        _depositToVault(address(weth), 20 ether);

        uint256 principalBefore = tokenizedVault.getBalance(address(weth));

        // Flow B: Deploy to vault
        vm.expectEmit(true, false, false, false);
        emit DepositCompleted(address(weth), 10 ether, 10 ether);

        vm.prank(owner);
        uint256 sharesReceived = tokenizedVault.depositToVault(address(weth), 10 ether);

        // Verify Flow B state
        assertEq(sharesReceived, 10 ether, "Should receive shares 1:1");
        assertEq(tokenizedVault.getVaultShares(), 10 ether, "Shares tracked correctly");
        assertEq(erc4626Vault.balanceOf(address(tokenizedVault)), 10 ether, "ERC4626 shares received");

        // Verify Flow A principal unchanged
        assertEq(tokenizedVault.getBalance(address(weth)), principalBefore, "Principal should remain same");
    }

    /**
     * @notice Test Flow B withdrawal operation (atomic mode)
     * @dev Verifies:
     *      - Owner can withdraw from ERC-4626 vault
     *      - Assets received from vault
     *      - Shares deducted
     *      - Flow A principal unchanged
     */
    function test_flowB_withdrawFromVault_AtomicSuccess() public {
        // Setup: Flow A deposit + Flow B deploy
        vm.prank(kingVault);
        _depositToVault(address(weth), 20 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        uint256 principalBefore = tokenizedVault.getBalance(address(weth));

        // Flow B: Withdraw from vault
        vm.expectEmit(true, false, false, false);
        emit WithdrawalConfirmed(address(weth), 10 ether);

        vm.prank(owner);
        uint256 assetsReceived = tokenizedVault.withdrawFromVault(address(weth), 10 ether, false);

        // Verify Flow B state
        assertEq(assetsReceived, 10 ether, "Should receive assets 1:1");
        assertEq(tokenizedVault.getVaultShares(), 10 ether, "Remaining shares should be 10");
        assertEq(weth.balanceOf(address(tokenizedVault)), 10 ether, "Should have idle WETH");

        // Verify Flow A principal unchanged
        assertEq(tokenizedVault.getBalance(address(weth)), principalBefore, "Principal should remain same");
    }

    /**
     * @notice Test Flow B profit harvest and distribution
     * @dev Verifies:
     *      - Profit calculated correctly
     *      - Harvest extracts profit shares
     *      - Distribution sends to kingVault
     *      - Flow A principal unchanged
     */
    function test_flowB_profitCycle_Success() public {
        // Setup: Flow A deposit + Flow B deploy
        vm.prank(kingVault);
        _depositToVault(address(weth), 20 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        uint256 principalBefore = tokenizedVault.getBalance(address(weth));

        // Simulate profit: 50% appreciation
        erc4626Vault.setExchangeRate(1.5e18);

        // Calculate profit
        uint256 profit = tokenizedVault.calculateProfit();
        assertGt(profit, 0, "Should have profit");

        // Harvest profits
        vm.expectEmit(false, false, false, false);
        emit ProfitsHarvested(block.timestamp);

        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Distribute profits
        uint256 kingVaultBalanceBefore = weth.balanceOf(kingVault);

        vm.expectEmit(true, false, false, false);
        emit ProfitsDistributed(address(weth), weth.balanceOf(address(tokenizedVault)));

        vm.prank(owner);
        tokenizedVault.distributeProfits();

        // Verify profit distributed to kingVault
        assertGt(weth.balanceOf(kingVault), kingVaultBalanceBefore, "KingVault should receive profits");

        // Verify Flow A principal unchanged
        assertEq(tokenizedVault.getBalance(address(weth)), principalBefore, "Principal should remain same");
    }

    // ============================================
    // Dual Flow Interference Tests
    // ============================================

    /**
     * @notice Test Flow A deposit does not affect Flow B shares
     * @dev Verifies:
     *      - Depositing to vault after shares deployed
     *      - Share count unchanged
     *      - Principal increases
     */
    function test_dualFlow_flowADepositDoesNotAffectFlowBShares() public {
        // Flow A: Initial deposit
        vm.prank(kingVault);
        _depositToVault(address(weth), 10 ether);

        // Flow B: Deploy to vault
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        uint256 sharesBefore = tokenizedVault.getVaultShares();

        // Flow A: Additional deposit
        vm.prank(kingVault);
        _depositToVault(address(weth), 5 ether);

        // Verify Flow B shares unchanged
        assertEq(tokenizedVault.getVaultShares(), sharesBefore, "Shares should be unchanged");

        // Verify Flow A principal increased
        assertEq(tokenizedVault.getBalance(address(weth)), 15 ether, "Principal should increase");
    }

    /**
     * @notice Test Flow B deployment does not affect Flow A principal
     * @dev Verifies:
     *      - Deploying idle assets to vault
     *      - Principal tracking unchanged
     *      - Shares created
     */
    function test_dualFlow_flowBDeploymentDoesNotAffectFlowAPrincipal() public {
        // Flow A: Deposit
        vm.prank(kingVault);
        _depositToVault(address(weth), 20 ether);

        uint256 principalBefore = tokenizedVault.getBalance(address(weth));

        // Flow B: Deploy half to vault
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Verify Flow A principal unchanged
        assertEq(tokenizedVault.getBalance(address(weth)), principalBefore, "Principal should be unchanged");

        // Verify Flow B shares created
        assertEq(tokenizedVault.getVaultShares(), 10 ether, "Shares should be created");
    }

    /**
     * @notice Test Flow A withdraw respects Flow B reserved assets
     * @dev Verifies:
     *      - Cannot withdraw assets reserved for profit distribution
     *      - availableForWithdraw accounts for queued operations
     */
    function test_dualFlow_flowAWithdrawRespectsFlowBReservations() public {
        // Setup: Deposit + deploy + profit
        vm.prank(kingVault);
        _depositToVault(address(weth), 20 ether);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        // Generate profit
        erc4626Vault.setExchangeRate(1.5e18);

        // Harvest (queues profit assets)
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Calculate available for withdraw
        uint256 available = tokenizedVault.availableForWithdraw(address(weth));

        // Idle balance exists but some is reserved for profit distribution
        uint256 idle = weth.balanceOf(address(tokenizedVault));
        assertLt(available, idle, "Available should be less than idle (profits reserved)");

        // Attempting to withdraw more than available should fail
        vm.prank(kingVault);
        vm.expectRevert();
        _withdrawFromVault(address(weth), idle, kingVault);
    }

    /**
     * @notice Test complete lifecycle with both flows
     * @dev Integration test covering:
     *      1. Flow A: Deposit from kingVault
     *      2. Flow B: Deploy to ERC-4626
     *      3. Flow B: Profit generation
     *      4. Flow B: Harvest and distribute profits
     *      5. Flow A: Withdraw principal back to kingVault
     */
    function test_dualFlow_completeLifecycle() public {
        uint256 initialDeposit = 50 ether;

        // Step 1: Flow A - Deposit from kingVault
        vm.prank(kingVault);
        _depositToVault(address(weth), initialDeposit);
        assertEq(tokenizedVault.getBalance(address(weth)), initialDeposit, "Principal recorded");

        // Step 2: Flow B - Deploy to ERC-4626 vault
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), initialDeposit);
        assertEq(tokenizedVault.getVaultShares(), initialDeposit, "Shares received");
        assertEq(tokenizedVault.getBalance(address(weth)), initialDeposit, "Principal unchanged");

        // Step 3: Flow B - Simulate profit (20% appreciation)
        // Fund vault to back the appreciation: 50 ether * 1.2 = 60 ether needed, so mint 10 more
        weth.mint(address(erc4626Vault), 10 ether);
        erc4626Vault.setExchangeRate(1.2e18);
        uint256 profit = tokenizedVault.calculateProfit();
        assertGt(profit, 0, "Profit generated");

        // Step 4: Flow B - Harvest and distribute profits
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        uint256 kingVaultBalanceBefore = weth.balanceOf(kingVault);
        vm.prank(owner);
        tokenizedVault.distributeProfits();

        uint256 profitsReceived = weth.balanceOf(kingVault) - kingVaultBalanceBefore;
        assertGt(profitsReceived, 0, "Profits distributed to kingVault");

        // Step 5: Flow B - Withdraw remaining from ERC-4626
        uint256 remainingShares = tokenizedVault.getVaultShares();
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(address(weth), remainingShares, false);

        // Step 6: Flow A - Withdraw all principal back to kingVault
        uint256 finalPrincipal = tokenizedVault.getBalance(address(weth));
        assertEq(finalPrincipal, initialDeposit, "Principal should be unchanged");

        vm.prank(kingVault);
        _withdrawFromVault(address(weth), finalPrincipal, kingVault);

        // Verify final state
        assertEq(tokenizedVault.getBalance(address(weth)), 0, "No principal remaining");
        assertEq(tokenizedVault.getVaultShares(), 0, "No shares remaining");
        assertEq(weth.balanceOf(address(tokenizedVault)), 0, "No idle balance");
    }

    // ============================================
    // Accounting Invariant Tests
    // ============================================

    /**
     * @notice Test accounting invariant: TVL = principal only
     * @dev Verifies:
     *      - TVL calculation uses principal only
     *      - Share appreciation does not affect TVL
     *      - Profit is separate from TVL
     */
    function test_accounting_tvlEqualsPrincipalOnly() public {
        // Deposit
        vm.prank(kingVault);
        _depositToVault(address(weth), 20 ether);

        (uint256 tvlEthAfterDeposit, uint256 tvlUsdAfterDeposit) = tokenizedVault.tvl();

        // Deploy to vault
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 20 ether);

        // TVL should be unchanged (principal-only)
        (uint256 tvlEthAfterDeploy, uint256 tvlUsdAfterDeploy) = tokenizedVault.tvl();
        assertEq(tvlEthAfterDeploy, tvlEthAfterDeposit, "TVL ETH should be principal only");
        assertEq(tvlUsdAfterDeploy, tvlUsdAfterDeposit, "TVL USD should be principal only");

        // Generate profit
        erc4626Vault.setExchangeRate(2.0e18); // 100% profit

        // TVL still unchanged (profit not in TVL)
        (uint256 tvlEthAfterProfit, uint256 tvlUsdAfterProfit) = tokenizedVault.tvl();
        assertEq(tvlEthAfterProfit, tvlEthAfterDeposit, "TVL should ignore profit");
        assertEq(tvlUsdAfterProfit, tvlUsdAfterDeposit, "TVL should ignore profit");

        // Profit is separate
        uint256 profit = tokenizedVault.calculateProfit();
        assertGt(profit, 0, "Profit exists but not in TVL");
    }

    /**
     * @notice Test accounting invariant: Total value = principal + profit
     * @dev Verifies:
     *      - Share value = principal value + profit value
     *      - Profit calculation is accurate
     */
    function test_accounting_totalValueEqualsPrincipalPlusProfit() public {
        uint256 principal = 30 ether;

        vm.prank(kingVault);
        _depositToVault(address(weth), principal);

        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), principal);

        // Set 50% appreciation
        erc4626Vault.setExchangeRate(1.5e18);

        // Calculate components
        uint256 shareValue = erc4626Vault.convertToAssets(tokenizedVault.getVaultShares());
        uint256 principalValue = principal;
        uint256 profitValue = tokenizedVault.calculateProfit();

        // Verify: share value = principal + profit
        assertApproxEqRel(shareValue, principalValue + profitValue, 0.01e18, "Share value = principal + profit");
    }

    /**
     * @notice Test no asset leakage between flows
     * @dev Verifies:
     *      - All deposited assets accounted for
     *      - No assets lost in transfers
     */
    function test_accounting_noAssetLeakage() public {
        // Fund kingVault with extra WETH for this test
        weth.mint(kingVault, 40 ether);
        uint256 initialKingVaultBalance = weth.balanceOf(kingVault);

        // Deposit
        vm.prank(kingVault);
        _depositToVault(address(weth), 40 ether);

        // Assets should be in vault
        assertEq(weth.balanceOf(address(tokenizedVault)), 40 ether, "Vault should hold assets");

        // Deploy
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 40 ether);

        // Assets should be in ERC-4626
        assertEq(weth.balanceOf(address(erc4626Vault)), 40 ether, "ERC4626 should hold assets");

        // Withdraw from ERC-4626
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(address(weth), 40 ether, false);

        // Assets back in vault
        assertEq(weth.balanceOf(address(tokenizedVault)), 40 ether, "Vault should hold assets again");

        // Withdraw to kingVault
        vm.prank(kingVault);
        _withdrawFromVault(address(weth), 40 ether, kingVault);

        // Verify total conservation
        uint256 finalKingVaultBalance = weth.balanceOf(kingVault);
        assertEq(finalKingVaultBalance, initialKingVaultBalance, "No asset leakage");
    }
}
