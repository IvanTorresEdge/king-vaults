// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BoringVault} from "../../../src/vaults/BoringVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPriceProvider} from "../../mocks/MockPriceProvider.sol";
import {IKingVault} from "../../../src/interfaces/IKingVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DepositsTest
 * @notice Comprehensive unit tests for BoringVault deposits and share calculations
 * @dev Tests Task 7.2 acceptance criteria:
 *      - Test deposit() function from kingVault with single and multiple assets
 *      - Test depositToVault() with share minting and tracking
 *      - Test deposit with different exchange rates (1.0, 2.0, 2.4)
 *      - Test share calculation accuracy with various amounts
 *      - Test _deposits mapping updates correctly
 *      - Test getBalances() returns correct principal amounts
 *      - Test getBalance(asset) for individual assets
 *      - Test slippage validation during deposits
 *      - Test rejection of non-accepted assets
 *      - Verify Deposited event emissions
 */
contract DepositsTest is Test {
    // ============================================
    // Contracts
    // ============================================

    BoringVault public boringVault;
    BoringVault public implementation;
    MockERC20 public weth;
    MockERC20 public ethfi;
    MockERC20 public usdc;
    MockPriceProvider public priceProvider;
    MockERC20 public vaultToken; // Mock BoringVault shares
    MockTeller public teller;
    MockAccountant public accountant;
    MockAtomicQueue public atomicQueue;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public unauthorized = address(0x3);

    // ============================================
    // Events
    // ============================================

    event Deposited(address[] assets, uint256[] amounts, uint256 timestamp);
    event DepositCompleted(address indexed token, uint256 amount, uint256 sharesReceived);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ethfi = new MockERC20("EtherFi Token", "ETHFI", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vaultToken = new MockERC20("Boring Vault Shares", "bvWETH", 18);

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(ethfi), 0.0005e18); // 1 ETHFI = 0.0005 ETH
        priceProvider.setPrice(address(usdc), 0.0005e18); // 1 USDC = 0.0005 ETH

        // Deploy mock Veda contracts
        teller = new MockTeller(address(vaultToken));
        accountant = new MockAccountant(address(weth), address(vaultToken));
        atomicQueue = new MockAtomicQueue();

        // Connect teller to accountant
        teller.setAccountant(address(accountant));

        // Set up mock exchange rate in accountant (1 share = 1.0 WETH initially)
        accountant.setRate(1.0e18);

        // Deploy BoringVault implementation (with immutable addresses)
        implementation = new BoringVault(
            address(vaultToken), // vault
            address(teller),     // teller
            address(accountant)  // accountant
        );

        // Deploy and initialize proxy
        boringVault = _deployStandardBoringVault();
    }

    // ============================================
    // Helper Functions
    // ============================================

    /**
     * @notice Deploy and initialize a BoringVault proxy with given parameters
     */
    function _deployBoringVault(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address _atomicQueue,
        address[] memory _tokens,
        bool[] memory _accepted
    ) internal returns (BoringVault) {
        bytes memory initData = abi.encodeWithSelector(
            BoringVault.initialize.selector,
            _owner,
            _kingVault,
            _priceProvider,
            _atomicQueue,
            _tokens,
            _accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return BoringVault(address(proxy));
    }

    /**
     * @notice Deploy a properly initialized BoringVault for standard tests
     */
    function _deployStandardBoringVault() internal returns (BoringVault) {
        address[] memory tokens = new address[](3);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        tokens[2] = address(usdc);
        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        return _deployBoringVault(
            owner,
            kingVault,
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );
    }

    /**
     * @notice Calculate expected shares for a given asset amount
     */
    function _calculateExpectedShares(uint256 amount, uint256 rate) internal pure returns (uint256) {
        // shares = amount × (10^18 / rate)
        return Math.mulDiv(amount, 1e18, rate);
    }

    // ============================================
    // deposit() Tests - Single Asset from kingVault
    // ============================================

    function test_deposit_SingleAsset_SucceedsWithValidParameters() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Mint and approve tokens
        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);

        // Expect Deposited event
        vm.expectEmit(true, true, true, true);
        emit Deposited(tokens, amounts, block.timestamp);

        // Execute deposit
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Verify state
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal should be tracked");
        assertEq(weth.balanceOf(address(boringVault)), 1000e18, "Tokens should be transferred");
    }

    function test_deposit_SingleAsset_UpdatesDepositsMapping() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Before: balance is 0
        assertEq(boringVault.getBalance(address(weth)), 0);

        // Deposit
        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // After: balance is 1000e18
        assertEq(boringVault.getBalance(address(weth)), 1000e18);
    }

    function test_deposit_SingleAsset_MultipleDepositsAccumulate() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);

        // First deposit: 1000 WETH
        amounts[0] = 1000e18;
        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        assertEq(boringVault.getBalance(address(weth)), 1000e18);

        // Second deposit: 500 WETH
        amounts[0] = 500e18;
        weth.mint(kingVault, 500e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 500e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Total should be 1500 WETH
        assertEq(boringVault.getBalance(address(weth)), 1500e18);
    }

    function test_deposit_SingleAsset_RevertsWithZeroAmount() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        vm.prank(kingVault);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        boringVault.deposit(tokens, amounts);
    }

    function test_deposit_SingleAsset_RevertsWithUnacceptedAsset() public {
        // Deploy new token that's not registered
        MockERC20 unregistered = new MockERC20("Unregistered", "UNREG", 18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(unregistered);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(kingVault);
        vm.expectRevert(abi.encodeWithSelector(IKingVault.AssetNotAccepted.selector, address(unregistered)));
        boringVault.deposit(tokens, amounts);
    }

    function test_deposit_SingleAsset_RevertsForNonKingVault() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        boringVault.deposit(tokens, amounts);
    }

    // ============================================
    // deposit() Tests - Multiple Assets from kingVault
    // ============================================

    function test_deposit_MultipleAssets_SucceedsWithValidParameters() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;

        // Mint and approve tokens
        weth.mint(kingVault, 1000e18);
        ethfi.mint(kingVault, 2000e18);
        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        ethfi.approve(address(boringVault), 2000e18);

        // Expect Deposited event
        vm.expectEmit(true, true, true, true);
        emit Deposited(tokens, amounts, block.timestamp);

        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Verify state for both assets
        assertEq(boringVault.getBalance(address(weth)), 1000e18);
        assertEq(boringVault.getBalance(address(ethfi)), 2000e18);
        assertEq(weth.balanceOf(address(boringVault)), 1000e18);
        assertEq(ethfi.balanceOf(address(boringVault)), 2000e18);
    }

    function test_deposit_MultipleAssets_UpdatesAllDeposits() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        tokens[2] = address(usdc);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;
        amounts[2] = 500e6; // USDC has 6 decimals

        // Mint and approve all tokens
        weth.mint(kingVault, 1000e18);
        ethfi.mint(kingVault, 2000e18);
        usdc.mint(kingVault, 500e6);
        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        ethfi.approve(address(boringVault), 2000e18);
        usdc.approve(address(boringVault), 500e6);

        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Verify all deposits tracked
        assertEq(boringVault.getBalance(address(weth)), 1000e18);
        assertEq(boringVault.getBalance(address(ethfi)), 2000e18);
        assertEq(boringVault.getBalance(address(usdc)), 500e6);
    }

    function test_deposit_MultipleAssets_RevertsWithEmptyArray() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(kingVault);
        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        boringVault.deposit(tokens, amounts);
    }

    function test_deposit_MultipleAssets_RevertsWithMismatchedArrays() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.prank(kingVault);
        vm.expectRevert(IKingVault.InvalidAssetArray.selector);
        boringVault.deposit(tokens, amounts);
    }

    // ============================================
    // depositToVault() Tests - Share Minting at Rate 1.0
    // ============================================

    function test_depositToVault_Rate1_MintsCorrectShares() public {
        // Rate 1.0: 1 WETH = 1 share
        accountant.setRate(1.0e18);

        // First deposit from kingVault to have idle balance
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Now owner deploys to vault
        uint256 expectedShares = _calculateExpectedShares(1000e18, 1.0e18);
        assertEq(expectedShares, 1000e18, "At rate 1.0, shares should equal amount");

        vm.expectEmit(true, true, true, true);
        emit DepositCompleted(address(weth), 1000e18, expectedShares);

        vm.prank(owner);
        uint256 sharesReceived = boringVault.depositToVault(address(weth), 1000e18);

        // Verify shares received
        assertEq(sharesReceived, expectedShares, "Should receive expected shares");
        assertEq(vaultToken.balanceOf(address(boringVault)), expectedShares, "Vault should hold shares");

        // CRITICAL: _deposits should NOT change (only kingVault deposit() changes it)
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal unchanged");
    }

    function test_depositToVault_Rate1_DoesNotModifyDepositsMapping() public {
        accountant.setRate(1.0e18);

        // Deposit from kingVault
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Record principal before
        uint256 principalBefore = boringVault.getBalance(address(weth));

        // Deploy to vault
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 500e18);

        // Principal should be unchanged
        uint256 principalAfter = boringVault.getBalance(address(weth));
        assertEq(principalAfter, principalBefore, "depositToVault should NOT modify _deposits");
    }

    // ============================================
    // depositToVault() Tests - Share Minting at Rate 2.0
    // ============================================

    function test_depositToVault_Rate2_MintsCorrectShares() public {
        // Rate 2.0: 1 share = 2 WETH, so 1000 WETH = 500 shares
        accountant.setRate(2.0e18);

        // Deposit from kingVault
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Deploy to vault
        uint256 expectedShares = _calculateExpectedShares(1000e18, 2.0e18);
        assertEq(expectedShares, 500e18, "At rate 2.0, 1000 WETH = 500 shares");

        vm.expectEmit(true, true, true, true);
        emit DepositCompleted(address(weth), 1000e18, expectedShares);

        vm.prank(owner);
        uint256 sharesReceived = boringVault.depositToVault(address(weth), 1000e18);

        assertEq(sharesReceived, expectedShares, "Should receive 500 shares");
        assertEq(vaultToken.balanceOf(address(boringVault)), 500e18, "Vault should hold 500 shares");
    }

    function test_depositToVault_Rate2_PrincipalUnchanged() public {
        accountant.setRate(2.0e18);

        // Deposit from kingVault
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Deploy to vault (500 shares for 1000 WETH)
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Principal remains 1000 WETH (NOT share value)
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal unchanged at 1000 WETH");
    }

    // ============================================
    // depositToVault() Tests - Share Minting at Rate 2.4
    // ============================================

    function test_depositToVault_Rate2_4_MintsCorrectShares() public {
        // Rate 2.4: 1 share = 2.4 WETH, so 1000 WETH = 416.666... shares
        accountant.setRate(2.4e18);

        // Deposit from kingVault
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Deploy to vault
        uint256 expectedShares = _calculateExpectedShares(1000e18, 2.4e18);
        // expectedShares = 1000e18 * 1e18 / 2.4e18 = 416.666... e18

        vm.expectEmit(true, true, true, true);
        emit DepositCompleted(address(weth), 1000e18, expectedShares);

        vm.prank(owner);
        uint256 sharesReceived = boringVault.depositToVault(address(weth), 1000e18);

        assertEq(sharesReceived, expectedShares, "Should receive ~416.67 shares");

        // Verify calculation precision
        uint256 expectedCalculated = Math.mulDiv(1000e18, 1e18, 2.4e18);
        assertEq(sharesReceived, expectedCalculated, "Shares match calculated value");
    }

    function test_depositToVault_Rate2_4_ShareValueVsPrincipal() public {
        accountant.setRate(2.4e18);

        // Deposit from kingVault: 1000 WETH principal
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Deploy to vault: receives ~416.67 shares
        vm.prank(owner);
        uint256 sharesReceived = boringVault.depositToVault(address(weth), 1000e18);

        // At rate 2.4, shares are worth: 416.67 * 2.4 = 1000 WETH (matches principal)
        uint256 shareValue = Math.mulDiv(sharesReceived, 2.4e18, 1e18);
        assertApproxEqAbs(shareValue, 1000e18, 2, "Share value should equal principal at deposit (within rounding)");

        // Principal tracking unchanged
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal remains 1000 WETH");
    }

    // ============================================
    // Share Calculation Accuracy Tests
    // ============================================

    function test_shareCalculation_SmallAmounts_Accurate() public {
        accountant.setRate(2.0e18);

        // Small amount: 1 WETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;

        weth.mint(kingVault, 1e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        vm.prank(owner);
        uint256 shares = boringVault.depositToVault(address(weth), 1e18);

        // 1 WETH at rate 2.0 = 0.5 shares
        assertEq(shares, 0.5e18, "Small amount should calculate accurately");
    }

    function test_shareCalculation_LargeAmounts_Accurate() public {
        accountant.setRate(2.0e18);

        // Large amount: 1 million WETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000_000e18;

        weth.mint(kingVault, 1_000_000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1_000_000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        vm.prank(owner);
        uint256 shares = boringVault.depositToVault(address(weth), 1_000_000e18);

        // 1M WETH at rate 2.0 = 500k shares
        assertEq(shares, 500_000e18, "Large amount should calculate accurately");
    }

    function test_shareCalculation_FractionalRates_Accurate() public {
        // Rate with many decimals: 1.23456789
        accountant.setRate(1.23456789e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        vm.prank(owner);
        uint256 shares = boringVault.depositToVault(address(weth), 1000e18);

        // Verify using Math.mulDiv
        uint256 expected = Math.mulDiv(1000e18, 1e18, 1.23456789e18);
        assertEq(shares, expected, "Fractional rate should calculate with full precision");
    }

    function test_shareCalculation_DifferentDecimals_Accurate() public {
        accountant.setRate(2.0e18);

        // USDC has 6 decimals
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e6; // 1000 USDC

        usdc.mint(kingVault, 1000e6);
        vm.prank(kingVault);
        usdc.approve(address(boringVault), 1000e6);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        vm.prank(owner);
        uint256 shares = boringVault.depositToVault(address(usdc), 1000e6);

        // 1000 USDC at rate 2.0 = 500 shares (calculation handles decimals)
        uint256 expected = Math.mulDiv(1000e6, 1e18, 2.0e18);
        assertEq(shares, expected, "Different decimals should calculate correctly");
    }

    // ============================================
    // getBalances() Tests - Principal Tracking
    // ============================================

    function test_getBalances_ReturnsCorrectPrincipalAmounts() public {
        // Deposit multiple assets
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;

        weth.mint(kingVault, 1000e18);
        ethfi.mint(kingVault, 2000e18);
        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        ethfi.approve(address(boringVault), 2000e18);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Get balances
        (address[] memory assets, uint256[] memory balances) = boringVault.getBalances();

        // Find WETH and ETHFI in results
        bool foundWeth = false;
        bool foundEthfi = false;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(weth)) {
                assertEq(balances[i], 1000e18, "WETH principal should be 1000");
                foundWeth = true;
            } else if (assets[i] == address(ethfi)) {
                assertEq(balances[i], 2000e18, "ETHFI principal should be 2000");
                foundEthfi = true;
            }
        }
        assertTrue(foundWeth && foundEthfi, "Both assets should be in results");
    }

    function test_getBalances_ReflectsPrincipalNotShareValue() public {
        accountant.setRate(2.0e18);

        // Deposit 1000 WETH as principal
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Deploy to vault (gets 500 shares at rate 2.0)
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Change rate to 2.4 (share appreciation)
        accountant.setRate(2.4e18);
        // Now 500 shares are worth 500 * 2.4 = 1200 WETH

        // getBalances should still return 1000 (principal), NOT 1200 (share value)
        (address[] memory assets, uint256[] memory balances) = boringVault.getBalances();

        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(weth)) {
                assertEq(balances[i], 1000e18, "Should return principal 1000, not share value 1200");
            }
        }
    }

    function test_getBalances_EmptyWhenNoDeposits() public {
        // No deposits yet
        (address[] memory assets, uint256[] memory balances) = boringVault.getBalances();

        // All balances should be 0
        for (uint256 i = 0; i < balances.length; i++) {
            assertEq(balances[i], 0, "All balances should be 0 with no deposits");
        }
    }

    // ============================================
    // getBalance() Tests - Individual Asset
    // ============================================

    function test_getBalance_ReturnsCorrectPrincipal() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        uint256 balance = boringVault.getBalance(address(weth));
        assertEq(balance, 1000e18, "Should return principal amount");
    }

    function test_getBalance_ReturnsZeroForUnregistered() public {
        MockERC20 unregistered = new MockERC20("Unregistered", "UNREG", 18);
        uint256 balance = boringVault.getBalance(address(unregistered));
        assertEq(balance, 0, "Should return 0 for unregistered asset");
    }

    function test_getBalance_ReturnsZeroForNoDeposits() public {
        uint256 balance = boringVault.getBalance(address(weth));
        assertEq(balance, 0, "Should return 0 when no deposits");
    }

    function test_getBalance_TracksMultipleDeposits() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);

        // First deposit
        amounts[0] = 1000e18;
        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        assertEq(boringVault.getBalance(address(weth)), 1000e18);

        // Second deposit
        amounts[0] = 500e18;
        weth.mint(kingVault, 500e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 500e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        assertEq(boringVault.getBalance(address(weth)), 1500e18, "Should accumulate deposits");
    }

    // ============================================
    // Slippage Validation Tests
    // ============================================

    function test_slippage_DefaultSlippageIs50BPS() public {
        assertEq(boringVault.maxSlippageBPS(), 50, "Default slippage should be 50 BPS (0.5%)");
    }

    function test_slippage_DepositSucceedsWithinTolerance() public {
        accountant.setRate(2.0e18);

        // Deposit assets
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Expected: 500 shares at rate 2.0
        // Min shares with 50 BPS slippage: 500 * (10000 - 50) / 10000 = 497.5
        uint256 expectedShares = 500e18;
        uint256 minShares = (expectedShares * (10_000 - 50)) / 10_000;

        // Teller will return exactly expected shares (no slippage)
        vm.prank(owner);
        uint256 received = boringVault.depositToVault(address(weth), 1000e18);

        assertGe(received, minShares, "Received should meet minimum");
        assertEq(received, expectedShares, "Should receive full expected amount");
    }

    function test_slippage_DepositRevertsWhenExceeded() public {
        accountant.setRate(2.0e18);

        // Deposit assets
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Configure teller to return fewer shares than minimum
        uint256 expectedShares = 500e18;
        uint256 minShares = (expectedShares * (10_000 - 50)) / 10_000;
        teller.setReturnShares(minShares - 1); // Return 1 wei less than minimum

        // Should revert with SlippageExceeded
        vm.prank(owner);
        vm.expectRevert();
        boringVault.depositToVault(address(weth), 1000e18);
    }

    function test_slippage_CanUpdateMaxSlippage() public {
        vm.prank(owner);
        boringVault.setMaxSlippage(100); // 1%

        assertEq(boringVault.maxSlippageBPS(), 100, "Slippage should be updated to 100 BPS");
    }

    function test_slippage_CannotExceedLimit() public {
        vm.prank(owner);
        vm.expectRevert();
        boringVault.setMaxSlippage(1001); // Over 10% limit
    }

    // ============================================
    // depositToVault() Validation Tests
    // ============================================

    function test_depositToVault_RevertsForUnacceptedAsset() public {
        MockERC20 unregistered = new MockERC20("Unregistered", "UNREG", 18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IKingVault.AssetNotAccepted.selector, address(unregistered)));
        boringVault.depositToVault(address(unregistered), 1000e18);
    }

    function test_depositToVault_RevertsWithZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(IKingVault.ZeroAmount.selector);
        boringVault.depositToVault(address(weth), 0);
    }

    function test_depositToVault_RevertsWithInsufficientIdle() public {
        // No idle balance yet
        vm.prank(owner);
        vm.expectRevert();
        boringVault.depositToVault(address(weth), 1000e18);
    }

    function test_depositToVault_RevertsForNonOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        boringVault.depositToVault(address(weth), 1000e18);
    }

    function test_depositToVault_RevertsWhenPaused() public {
        // Deposit some assets first
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Pause
        vm.prank(owner);
        boringVault.pause();

        // Should revert
        vm.prank(owner);
        vm.expectRevert();
        boringVault.depositToVault(address(weth), 1000e18);
    }

    // ============================================
    // Event Emission Tests
    // ============================================

    function test_events_DepositEmitsDeposited() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit Deposited(tokens, amounts, block.timestamp);

        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);
    }

    function test_events_DepositToVaultEmitsDepositCompleted() public {
        accountant.setRate(2.0e18);

        // Deposit assets first
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Expect DepositCompleted event
        uint256 expectedShares = 500e18;
        vm.expectEmit(true, true, true, true);
        emit DepositCompleted(address(weth), 1000e18, expectedShares);

        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);
    }

    // ============================================
    // Edge Cases and Integration Tests
    // ============================================

    function test_edgeCase_PartialDeployment() public {
        accountant.setRate(2.0e18);

        // Deposit 1000 WETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Deploy only 600 WETH to vault
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 600e18);

        // Should have 400 WETH idle
        assertEq(weth.balanceOf(address(boringVault)), 400e18, "Should have 400 idle");

        // Should have 300 shares (600 / 2.0)
        assertEq(vaultToken.balanceOf(address(boringVault)), 300e18, "Should have 300 shares");

        // Principal unchanged at 1000
        assertEq(boringVault.getBalance(address(weth)), 1000e18, "Principal unchanged");
    }

    function test_edgeCase_MultipleAssetsWithDifferentRates() public {
        // Different assets deposited and deployed
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;

        weth.mint(kingVault, 1000e18);
        ethfi.mint(kingVault, 2000e18);
        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        ethfi.approve(address(boringVault), 2000e18);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Deploy WETH at rate 2.0
        accountant.setRate(2.0e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 1000e18);

        // Deploy ETHFI at rate 2.4
        accountant.setRate(2.4e18);
        vm.prank(owner);
        boringVault.depositToVault(address(ethfi), 2000e18);

        // Verify principals unchanged
        assertEq(boringVault.getBalance(address(weth)), 1000e18);
        assertEq(boringVault.getBalance(address(ethfi)), 2000e18);
    }
}

// ============================================
// Mock Contracts
// ============================================

/**
 * @notice Mock Teller contract for testing deposits
 * @dev Simulates Veda Teller behavior using an accountant for exchange rates
 */
contract MockTeller {
    address public vault;
    address public accountant;
    bool public paused;
    uint256 public returnShares; // 0 = calculate normally

    constructor(address _vault) {
        vault = _vault;
    }

    function setAccountant(address _accountant) external {
        accountant = _accountant;
    }

    function deposit(
        MockERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint
    ) external returns (uint256 shares) {
        require(!paused, "Teller paused");

        // NOTE: In real Veda Teller:
        // 1. Caller (BoringVault) approves vault to spend depositAsset
        // 2. Teller calls vault.enter() which pulls depositAsset from caller using vault's approval
        // 3. Vault mints shares to caller based on current exchange rate
        //
        // Simplified mock: Since we can't easily replicate the vault.enter() pattern with separate
        // approval checking, we just simulate the end result: transfer assets to vault and mint shares

        // Verify caller has sufficient balance
        require(depositAsset.balanceOf(msg.sender) >= depositAmount, "Insufficient balance");

        // Simulate the vault pulling funds from caller
        // NOTE: In reality, teller calls vault.enter() and vault pulls using its approval
        // For mocking, we use burn/mint to simulate transfer without needing approval checks
        // This is acceptable for unit tests; integration tests verify the real flow
        depositAsset.burn(msg.sender, depositAmount);
        depositAsset.mint(address(vault), depositAmount);

        // Calculate shares to mint
        if (returnShares > 0) {
            // Use manually set return value (for slippage tests)
            shares = returnShares;
            // Reset for next call
            returnShares = 0;
        } else {
            // Calculate shares using accountant rate
            // shares = depositAmount × (10^18 / rate)
            if (accountant != address(0)) {
                uint256 rate = MockAccountant(accountant).getRate();
                shares = (depositAmount * 1e18) / rate;
            } else {
                // Fallback to 1:1 if no accountant set
                shares = depositAmount;
            }
            require(shares >= minimumMint, "Below minimum shares");
        }

        // Vault mints shares to caller
        MockERC20(vault).mint(msg.sender, shares);

        return shares;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function setReturnShares(uint256 _shares) external {
        returnShares = _shares;
    }
}

/**
 * @notice Mock Accountant contract for testing exchange rates
 */
contract MockAccountant {
    address public base;
    address public vault;
    uint256 public rate;
    bool public paused;

    constructor(address _base, address _vault) {
        base = _base;
        vault = _vault;
        rate = 1e18; // Default 1:1
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getRateInQuoteSafe(MockERC20) external view returns (uint256) {
        require(!paused, "Accountant paused");
        return rate;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }
}

/**
 * @notice Mock AtomicQueue contract for testing
 */
contract MockAtomicQueue {
    struct AtomicRequest {
        uint64 deadline;
        uint88 atomicPrice;
        uint96 offerAmount;
        bool inSolve;
    }

    mapping(address => mapping(address => mapping(address => AtomicRequest))) public requests;

    function updateAtomicRequest(
        MockERC20 offer,
        MockERC20 want,
        AtomicRequest calldata request
    ) external {
        requests[msg.sender][address(offer)][address(want)] = request;
    }

    function getUserAtomicRequest(
        address user,
        MockERC20 offer,
        MockERC20 want
    ) external view returns (AtomicRequest memory) {
        return requests[user][address(offer)][address(want)];
    }
}
