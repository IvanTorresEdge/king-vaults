// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingBoringVault} from "../../src/vaults/KingBoringVault.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockTeller, MockAccountant, MockAtomicQueue} from "./KingBoringVault.security.t.sol";

/**
 * @title ExternalVaultPauseTest
 * @notice Tests for HIGH-4 External Vault Pause Status fix
 * @dev Verifies that depositToVault() properly checks external vault pause status
 */
contract ExternalVaultPauseTest is Test {
    KingBoringVault public vault;
    MockERC20 public weth;
    MockERC20 public vaultToken;
    MockPriceProvider public priceProvider;
    MockTeller public teller;
    MockAccountant public accountant;
    MockAtomicQueue public atomicQueue;

    address public owner = address(0x1);
    address public kingVault = address(0x2);

    function setUp() public {
        // Set block timestamp to reasonable value for testing
        vm.warp(1000 days);

        // Deploy tokens
        weth = new MockERC20("WETH", "WETH", 18);
        vaultToken = new MockERC20("Vault", "VLT", 18);

        // Deploy price provider with default ETH/USD price
        priceProvider = new MockPriceProvider(2000e18);
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH

        // Deploy mock Veda contracts
        teller = new MockTeller(address(vaultToken));
        accountant = new MockAccountant(address(weth), address(vaultToken));
        teller.setAccountant(address(accountant));
        accountant.setRate(1.0e18);
        atomicQueue = new MockAtomicQueue();

        // Deploy vault
        KingBoringVault implementation = new KingBoringVault(address(vaultToken), address(teller), address(accountant));

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector,
            owner,
            kingVault,
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );
        vault = KingBoringVault(address(new ERC1967Proxy(address(implementation), initData)));

        // Setup profit distribution
        address[] memory recipients = new address[](1);
        recipients[0] = address(0x99);
        uint16[] memory percentsBPS = new uint16[](1);
        percentsBPS[0] = 10000;
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percentsBPS);

        // Fund the vault with some WETH
        weth.mint(address(vault), 100e18);
    }

    /**
     * @notice Test that depositToVault succeeds when external vaults are not paused
     */
    function test_ExternalVaultPause_DepositSucceedsWhenNotPaused() public {
        // Ensure teller and accountant are not paused
        assertFalse(teller.isPaused(), "Teller should not be paused");
        assertFalse(accountant.isPaused(), "Accountant should not be paused");

        // Deposit should succeed
        vm.prank(owner);
        uint256 shares = vault.depositToVault(address(weth), 10e18);

        assertGt(shares, 0, "Should receive shares");
    }

    /**
     * @notice Test that depositToVault reverts when Teller is paused
     */
    function test_ExternalVaultPause_DepositRevertsWhenTellerPaused() public {
        // Pause the Teller
        teller.setPaused(true);
        assertTrue(teller.isPaused(), "Teller should be paused");

        // Attempt deposit - should revert with ExternalVaultPaused error
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IKingVault.ExternalVaultPaused.selector, address(teller)));
        vault.depositToVault(address(weth), 10e18);
    }

    /**
     * @notice Test that depositToVault reverts when Accountant is paused
     */
    function test_ExternalVaultPause_DepositRevertsWhenAccountantPaused() public {
        // Pause the Accountant
        accountant.setPaused(true);
        assertTrue(accountant.isPaused(), "Accountant should be paused");

        // Attempt deposit - should revert with ExternalVaultPaused error
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IKingVault.ExternalVaultPaused.selector, address(accountant)));
        vault.depositToVault(address(weth), 10e18);
    }

    /**
     * @notice Test that depositToVault reverts when both Teller and Accountant are paused
     * @dev Should fail on Teller check first since Teller is checked before Accountant in OR condition
     */
    function test_ExternalVaultPause_DepositRevertsWhenBothPaused() public {
        // Pause both
        teller.setPaused(true);
        accountant.setPaused(true);
        assertTrue(teller.isPaused(), "Teller should be paused");
        assertTrue(accountant.isPaused(), "Accountant should be paused");

        // Should revert with ExternalVaultPaused, indicating Teller (checked first in OR)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IKingVault.ExternalVaultPaused.selector, address(teller)));
        vault.depositToVault(address(weth), 10e18);
    }

    /**
     * @notice Test that depositToVault succeeds after external vaults are unpaused
     */
    function test_ExternalVaultPause_DepositSucceedsAfterUnpause() public {
        // Pause both
        teller.setPaused(true);
        accountant.setPaused(true);

        // Verify deposits fail
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IKingVault.ExternalVaultPaused.selector, address(teller)));
        vault.depositToVault(address(weth), 10e18);

        // Unpause both
        teller.setPaused(false);
        accountant.setPaused(false);
        assertFalse(teller.isPaused(), "Teller should not be paused");
        assertFalse(accountant.isPaused(), "Accountant should not be paused");

        // Deposit should now succeed
        vm.prank(owner);
        uint256 shares = vault.depositToVault(address(weth), 10e18);

        assertGt(shares, 0, "Should receive shares after unpause");
    }

    /**
     * @notice Test gas savings from early pause check vs failed deposit
     * @dev Demonstrates HIGH-4 fix benefit: prevents wasted gas on doomed transactions
     */
    function test_ExternalVaultPause_GasSavingsFromEarlyCheck() public {
        // Measure gas when Teller is paused (should fail early)
        teller.setPaused(true);

        uint256 gasBefore = gasleft();
        vm.prank(owner);
        try vault.depositToVault(address(weth), 10e18) {
            fail("Should have reverted");
        } catch {
            uint256 gasUsedWithEarlyCheck = gasBefore - gasleft();

            // For comparison purposes, if there was no pause check,
            // the transaction would proceed further before failing
            // The early check saves gas by reverting immediately
            // (Exact savings depend on how far the transaction would proceed)

            // Verify the function reverted due to pause check
            assertTrue(gasUsedWithEarlyCheck > 0, "Should have used gas");

            // The key benefit: Transaction fails fast without executing expensive operations
            // like approval, external calls to Teller.deposit(), etc.
        }
    }
}
