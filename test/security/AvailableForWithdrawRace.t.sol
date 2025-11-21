// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingBoringVault} from "../../src/vaults/KingBoringVault.sol";
import {KingTokenizedVault} from "../../src/vaults/KingTokenizedVault.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockTeller, MockAccountant, MockAtomicQueue} from "./KingBoringVault.security.t.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";

/**
 * @title AvailableForWithdrawRaceTest
 * @notice Tests for HIGH-3 availableForWithdraw Race Condition fix
 * @dev Verifies atomic availability checks prevent race conditions
 */
contract AvailableForWithdrawRaceTest is Test {
    KingBoringVault public boringVault;
    MockERC20 public weth;
    MockERC20 public ethfi;
    MockERC20 public vaultToken;
    MockPriceProvider public priceProvider;

    address public owner = address(0x1);
    address public kingVault;

    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Set block timestamp to reasonable value for testing
        vm.warp(1000 days);

        // Deploy tokens
        weth = new MockERC20("WETH", "WETH", 18);
        ethfi = new MockERC20("ETHFI", "ETHFI", 18);
        vaultToken = new MockERC20("Vault", "VLT", 18);

        // Deploy price provider with default ETH/USD price
        priceProvider = new MockPriceProvider(2000e18);
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(ethfi), 0.5e18); // 1 ETHFI = 0.5 ETH

        // Deploy mock Veda contracts
        MockTeller teller = new MockTeller(address(vaultToken));
        MockAccountant accountant = new MockAccountant(address(weth), address(vaultToken));
        teller.setAccountant(address(accountant));
        accountant.setRate(1.0e18);
        MockAtomicQueue queue = new MockAtomicQueue();

        // Deploy vault
        KingBoringVault implementation = new KingBoringVault(address(vaultToken), address(teller), address(accountant));

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector,
            owner,
            kingVault,
            address(priceProvider),
            address(queue),
            tokens,
            accepted
        );
        boringVault = KingBoringVault(address(new ERC1967Proxy(address(implementation), initData)));

        // Setup profit distribution
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x99);
        uint16[] memory percentsBPS = new uint16[](1);
        percentsBPS[0] = 10000;
        vm.prank(owner);
        boringVault.setProfitsDistribution(recipients, percentsBPS);
    }

    /**
     * @notice Test 1: Multi-asset batch withdrawal succeeds when all assets available
     */
    function test_RaceCondition_MultiAssetWithdrawalSucceeds() public {
        // Deposit multiple assets
        weth.mint(kingVault, 100e18);
        ethfi.mint(kingVault, 200e18);

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 100e18);
        ethfi.approve(address(boringVault), 200e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Both assets should have idle balance
        assertEq(weth.balanceOf(address(boringVault)), 100e18, "WETH balance should match");
        assertEq(ethfi.balanceOf(address(boringVault)), 200e18, "ETHFI balance should match");

        // Withdraw both assets in a single batch
        amounts[0] = 50e18;
        amounts[1] = 100e18;

        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        // Verify withdrawal succeeded for both assets
        assertEq(weth.balanceOf(kingVault), 50e18, "WETH withdrawal should succeed");
        assertEq(ethfi.balanceOf(kingVault), 100e18, "ETHFI withdrawal should succeed");
        assertEq(weth.balanceOf(address(boringVault)), 50e18, "WETH remaining should be correct");
        assertEq(ethfi.balanceOf(address(boringVault)), 100e18, "ETHFI remaining should be correct");
    }

    /**
     * @notice Test 2: Multi-asset batch reverts if ANY asset becomes unavailable
     */
    function test_RaceCondition_MultiAssetWithdrawalRevertsIfAnyUnavailable() public {
        // Deposit multiple assets
        weth.mint(kingVault, 100e18);
        ethfi.mint(kingVault, 200e18);

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 100e18);
        ethfi.approve(address(boringVault), 200e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Deposit some ETHFI into BoringVault to reduce available idle balance
        vm.prank(owner);
        boringVault.depositToVault(address(ethfi), 150e18);

        // Now try to withdraw both assets
        // WETH should be available (100e18 idle)
        // ETHFI should have only 50e18 idle (200 - 150 deposited to vault)
        amounts[0] = 50e18; // This is available
        amounts[1] = 100e18; // This exceeds idle (only 50 idle)

        // Withdrawal should revert due to ETHFI needing vault withdrawal
        // which would require checking availability
        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.withdraw(tokens, amounts, kingVault);

        // Verify NEITHER asset was withdrawn (atomic behavior)
        assertEq(weth.balanceOf(kingVault), 0, "WETH should not be withdrawn");
        assertEq(ethfi.balanceOf(kingVault), 0, "ETHFI should not be withdrawn");
    }

    /**
     * @notice Test 3: Atomic check prevents withdrawing more than available across multiple assets
     */
    function test_RaceCondition_AtomicCheckPreventsOverWithdrawal() public {
        // Deposit assets
        weth.mint(kingVault, 100e18);
        ethfi.mint(kingVault, 200e18);

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 100e18);
        ethfi.approve(address(boringVault), 200e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Deposit both assets into vault to reduce idle balance
        vm.startPrank(owner);
        boringVault.depositToVault(address(weth), 80e18);
        boringVault.depositToVault(address(ethfi), 150e18);
        vm.stopPrank();

        // Verify available amounts (idle balance)
        assertEq(weth.balanceOf(address(boringVault)), 20e18, "WETH idle should be 20");
        assertEq(ethfi.balanceOf(address(boringVault)), 50e18, "ETHFI idle should be 50");

        // Try to withdraw more than idle for first asset
        amounts[0] = 30e18; // Exceeds 20e18 idle
        amounts[1] = 40e18; // Within 50e18 idle

        // Should revert on WETH needing vault withdrawal
        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.withdraw(tokens, amounts, kingVault);

        // Verify nothing was withdrawn (atomic behavior)
        assertEq(weth.balanceOf(kingVault), 0, "No WETH should be withdrawn");
        assertEq(ethfi.balanceOf(kingVault), 0, "No ETHFI should be withdrawn");
    }

    /**
     * @notice Test 4: Verify deposited assets reduce idle balance
     */
    function test_RaceCondition_DepositedAssetsReduceIdleBalance() public {
        // Deposit asset
        weth.mint(kingVault, 100e18);

        vm.prank(kingVault);
        weth.approve(address(boringVault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Initially all 100 WETH should be idle
        assertEq(weth.balanceOf(address(boringVault)), 100e18, "All WETH should be idle initially");

        // Deposit 60 WETH into BoringVault
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 60e18);

        // Now only 40 WETH should be idle
        assertEq(weth.balanceOf(address(boringVault)), 40e18, "Only 40 WETH should be idle");

        // Withdrawal of 40 WETH should succeed (all idle)
        amounts[0] = 40e18;
        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        assertEq(weth.balanceOf(kingVault), 40e18, "40 WETH should be withdrawn");

        // Withdrawal of additional 1 WETH should fail (needs vault withdrawal)
        amounts[0] = 1e18;
        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.withdraw(tokens, amounts, kingVault);
    }
}
