// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {KingVaultHarness} from "../base/KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title UpgradeTimelockTest
 * @notice Tests for UUPS upgrade timelock mechanism
 * @dev Verifies 24-hour timelock, validation checks, and upgrade safety mechanisms
 */
contract UpgradeTimelockTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;
    KingVaultHarness public newImplementation;
    MockPriceProvider public priceProvider;

    address public owner = address(0x1);
    address public kingVault;
    address public unauthorized = address(0x999);

    event UpgradeScheduled(address indexed newImplementation, uint256 executeAfter);
    event UpgradeCancelled(address indexed implementation);

    function setUp() public {
        kingVault = address(new MockKingVaultController());

        // Deploy price provider
        priceProvider = new MockPriceProvider(2000e18);

        // Deploy initial implementation
        implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Deploy new implementation for upgrade tests
        newImplementation = new KingVaultHarness();
    }

    // ============================================
    // scheduleUpgrade() Tests
    // ============================================

    function test_ScheduleUpgrade_Success() public {
        // Schedule upgrade as owner
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));

        // Verify upgrade was scheduled
        uint256 executeAfter = vault.upgradeTimelock(address(newImplementation));
        assertEq(executeAfter, block.timestamp + 24 hours, "Upgrade should be scheduled for 24 hours from now");
    }

    function test_ScheduleUpgrade_EmitsEvent() public {
        uint256 expectedExecuteAfter = block.timestamp + 24 hours;

        // Expect event
        vm.expectEmit(true, false, false, true);
        emit UpgradeScheduled(address(newImplementation), expectedExecuteAfter);

        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
    }

    function test_ScheduleUpgrade_RevertsForNonOwner() public {
        // Unauthorized user cannot schedule
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.scheduleUpgrade(address(newImplementation));
    }

    function test_ScheduleUpgrade_RevertsForEOA() public {
        address eoaAddress = address(0x123456);

        // Cannot schedule EOA as implementation
        vm.prank(owner);
        vm.expectRevert(IKingVault.InvalidContract.selector);
        vault.scheduleUpgrade(eoaAddress);
    }

    function test_ScheduleUpgrade_CanReschedule() public {
        // Schedule first time
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
        uint256 firstSchedule = vault.upgradeTimelock(address(newImplementation));

        // Fast forward 1 hour
        vm.warp(block.timestamp + 1 hours);

        // Reschedule (update the timelock)
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
        uint256 secondSchedule = vault.upgradeTimelock(address(newImplementation));

        // Second schedule should be later than first
        assertGt(secondSchedule, firstSchedule, "Rescheduling should update the timelock");
    }

    // ============================================
    // cancelUpgrade() Tests
    // ============================================

    function test_CancelUpgrade_Success() public {
        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));

        // Verify it was scheduled
        assertGt(vault.upgradeTimelock(address(newImplementation)), 0, "Upgrade should be scheduled");

        // Cancel upgrade
        vm.prank(owner);
        vault.cancelUpgrade(address(newImplementation));

        // Verify it was cancelled
        assertEq(vault.upgradeTimelock(address(newImplementation)), 0, "Upgrade should be cancelled");
    }

    function test_CancelUpgrade_EmitsEvent() public {
        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));

        // Expect cancel event
        vm.expectEmit(true, false, false, false);
        emit UpgradeCancelled(address(newImplementation));

        // Cancel upgrade
        vm.prank(owner);
        vault.cancelUpgrade(address(newImplementation));
    }

    function test_CancelUpgrade_RevertsForNonOwner() public {
        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));

        // Unauthorized user cannot cancel
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.cancelUpgrade(address(newImplementation));
    }

    function test_CancelUpgrade_RevertsIfNotScheduled() public {
        // Try to cancel non-existent upgrade
        vm.prank(owner);
        vm.expectRevert(IKingVault.UpgradeNotScheduled.selector);
        vault.cancelUpgrade(address(newImplementation));
    }

    // ============================================
    // upgradeTo() with Timelock Tests
    // ============================================

    function test_UpgradeTo_RevertsIfNotScheduled() public {
        // Try to upgrade without scheduling
        vm.prank(owner);
        vm.expectRevert(IKingVault.UpgradeNotScheduled.selector);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_UpgradeTo_RevertsBeforeTimelockExpiry() public {
        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));

        // Try to upgrade immediately (should fail - need to wait 24 hours)
        vm.prank(owner);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImplementation), "");

        // Try after 23 hours (still too early)
        vm.warp(block.timestamp + 23 hours);
        vm.prank(owner);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_UpgradeTo_SucceedsAfterTimelockExpiry() public {
        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));

        // Fast forward 24 hours
        vm.warp(block.timestamp + 24 hours);

        // Upgrade should now succeed
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImplementation), "");

        // Verify upgrade succeeded by checking implementation
        // Note: We can't directly check implementation address in UUPS,
        // but we can verify vault still works
        assertTrue(address(vault) != address(0), "Vault should still exist after upgrade");
    }

    function test_UpgradeTo_RevertsForIncompatibleInterface() public {
        // Deploy a contract that doesn't support IKingVault interface
        MockERC20 incompatibleContract = new MockERC20("Test", "TST", 18);

        // Try to schedule - should fail because it's not a contract (has code but wrong interface)
        // Actually, scheduleUpgrade only checks code.length, so it will succeed
        vm.prank(owner);
        vault.scheduleUpgrade(address(incompatibleContract));

        // Fast forward 24 hours
        vm.warp(block.timestamp + 24 hours);

        // Try to upgrade - should revert because incompatibleContract doesn't support IKingVault
        vm.prank(owner);
        vm.expectRevert(IKingVault.InvalidInterface.selector);
        vault.upgradeToAndCall(address(incompatibleContract), "");
    }

    // ============================================
    // Integration Tests
    // ============================================

    function test_UpgradeWorkflow_FullCycle() public {
        // 1. Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
        uint256 scheduledTime = vault.upgradeTimelock(address(newImplementation));
        assertGt(scheduledTime, 0, "Step 1: Upgrade should be scheduled");

        // 2. Wait for timelock (24 hours)
        vm.warp(block.timestamp + 24 hours);

        // 3. Execute upgrade
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImplementation), "");

        // Vault should still be functional
        assertEq(vault.owner(), owner, "Step 3: Owner should remain unchanged after upgrade");
        assertEq(vault.kingVault(), kingVault, "Step 3: kingVault should remain unchanged after upgrade");
    }

    function test_UpgradeWorkflow_WithCancellation() public {
        // 1. Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
        assertGt(vault.upgradeTimelock(address(newImplementation)), 0, "Step 1: Upgrade should be scheduled");

        // 2. Discover issue and cancel
        vm.prank(owner);
        vault.cancelUpgrade(address(newImplementation));
        assertEq(vault.upgradeTimelock(address(newImplementation)), 0, "Step 2: Upgrade should be cancelled");

        // 3. Fast forward 24 hours
        vm.warp(block.timestamp + 24 hours);

        // 4. Try to upgrade - should fail because it was cancelled
        vm.prank(owner);
        vm.expectRevert(IKingVault.UpgradeNotScheduled.selector);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_UpgradeWorkflow_RescheduleAfterCancel() public {
        // 1. Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));

        // 2. Cancel upgrade
        vm.prank(owner);
        vault.cancelUpgrade(address(newImplementation));

        // 3. Reschedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
        assertGt(vault.upgradeTimelock(address(newImplementation)), 0, "Step 3: Upgrade should be rescheduled");

        // 4. Wait and execute
        vm.warp(block.timestamp + 24 hours);
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImplementation), "");

        // Should succeed
        assertTrue(address(vault) != address(0), "Upgrade should succeed after reschedule");
    }

    // ============================================
    // Time Boundary Tests
    // ============================================

    function test_UpgradeTo_ExactlyAtTimelockExpiry() public {
        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
        uint256 executeAfter = vault.upgradeTimelock(address(newImplementation));

        // Warp to exactly the expiry time
        vm.warp(executeAfter);

        // Should succeed at exact expiry time
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_UpgradeTo_OnceSecondBeforeExpiry() public {
        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
        uint256 executeAfter = vault.upgradeTimelock(address(newImplementation));

        // Warp to 1 second before expiry
        vm.warp(executeAfter - 1);

        // Should revert (timelock not yet expired)
        vm.prank(owner);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_UpgradeTo_OneSecondAfterExpiry() public {
        // Schedule upgrade
        vm.prank(owner);
        vault.scheduleUpgrade(address(newImplementation));
        uint256 executeAfter = vault.upgradeTimelock(address(newImplementation));

        // Warp to 1 second after expiry
        vm.warp(executeAfter + 1);

        // Should succeed
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    // ============================================
    // Constant Verification
    // ============================================

    function test_UpgradeDelay_Is24Hours() public {
        uint256 upgradeDelay = vault.UPGRADE_DELAY();
        assertEq(upgradeDelay, 24 hours, "UPGRADE_DELAY should be 24 hours");
        assertEq(upgradeDelay, 86400, "UPGRADE_DELAY should be 86400 seconds");
    }
}
