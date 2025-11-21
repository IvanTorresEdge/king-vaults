// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultSetProfitsDistributionTest
 * @notice Comprehensive tests for setProfitsDistribution() function (Task 5.7)
 * @dev Tests cover all scenarios from tasks.md and spec TS-13 to TS-16
 */
contract KingVaultSetProfitsDistributionTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;
    MockPriceProvider public priceProvider;

    address public owner = address(0x1);
    address public kingVault;
    address public treasury = address(0x3);
    address public devFund = address(0x4);
    address public marketingFund = address(0x5);
    address public unauthorized = address(0x6);

    uint16 public constant HUNDRED_PERCENT = 10000;

    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Deploy price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 ETH

        // Deploy implementation
        implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, address(priceProvider));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));
    }

    // ============================================
    // Happy Path Tests
    // ============================================

    /// @notice TS-13: Initial setup with single recipient (100%)
    function test_SetProfitsDistribution_SingleRecipient100Percent() public {
        // Arrange
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;

        // Act
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);

        // Assert
        (bool isRecipient, uint256 percentage) = vault.getProfitRecipientInfo(treasury);
        assertEq(isRecipient, true, "Treasury should be a recipient");
        assertEq(percentage, HUNDRED_PERCENT, "Treasury should have 100%");
    }

    /// @notice TS-14: Multiple recipients (60/40 split)
    function test_SetProfitsDistribution_MultipleRecipients_6040Split() public {
        // Arrange
        address[] memory recipients = new address[](2);
        recipients[0] = treasury;
        recipients[1] = devFund;
        uint16[] memory percents = new uint16[](2);
        percents[0] = 6000; // 60%
        percents[1] = 4000; // 40%

        // Act
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);

        // Assert
        (bool isTreasuryRecipient, uint256 treasuryPercent) = vault.getProfitRecipientInfo(treasury);
        (bool isDevRecipient, uint256 devPercent) = vault.getProfitRecipientInfo(devFund);

        assertEq(isTreasuryRecipient, true);
        assertEq(treasuryPercent, 6000);
        assertEq(isDevRecipient, true);
        assertEq(devPercent, 4000);
    }

    /// @notice Multiple recipients (33/33/34 split)
    function test_SetProfitsDistribution_ThreeRecipients_333334Split() public {
        address[] memory recipients = new address[](3);
        recipients[0] = treasury;
        recipients[1] = devFund;
        recipients[2] = marketingFund;
        uint16[] memory percents = new uint16[](3);
        percents[0] = 3333; // 33.33%
        percents[1] = 3333; // 33.33%
        percents[2] = 3334; // 33.34%

        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);

        (bool isTreasury, uint256 treasuryPct) = vault.getProfitRecipientInfo(treasury);
        (bool isDev, uint256 devPct) = vault.getProfitRecipientInfo(devFund);
        (bool isMkt, uint256 mktPct) = vault.getProfitRecipientInfo(marketingFund);

        assertEq(isTreasury && isDev && isMkt, true);
        assertEq(treasuryPct, 3333);
        assertEq(devPct, 3333);
        assertEq(mktPct, 3334);
    }

    /// @notice Updating existing distribution
    function test_SetProfitsDistribution_UpdateExisting() public {
        // Setup initial 100% treasury
        address[] memory initial = new address[](1);
        initial[0] = treasury;
        uint16[] memory initialPercent = new uint16[](1);
        initialPercent[0] = HUNDRED_PERCENT;

        vm.prank(owner);
        vault.setProfitsDistribution(initial, initialPercent);

        // Update to 70/30 split
        address[] memory updated = new address[](2);
        updated[0] = treasury;
        updated[1] = devFund;
        uint16[] memory updatedPercent = new uint16[](2);
        updatedPercent[0] = 7000;
        updatedPercent[1] = 3000;

        vm.prank(owner);
        vault.setProfitsDistribution(updated, updatedPercent);

        // Assert updated values
        (, uint256 treasuryPct) = vault.getProfitRecipientInfo(treasury);
        (, uint256 devPct) = vault.getProfitRecipientInfo(devFund);

        assertEq(treasuryPct, 7000, "Treasury should be updated to 70%");
        assertEq(devPct, 3000, "DevFund should be 30%");
    }

    /// @notice TS-15: Remove recipient by setting to 0
    function test_SetProfitsDistribution_RemoveRecipient() public {
        // Setup 70/30 split
        address[] memory initial = new address[](2);
        initial[0] = treasury;
        initial[1] = devFund;
        uint16[] memory initialPercent = new uint16[](2);
        initialPercent[0] = 7000;
        initialPercent[1] = 3000;

        vm.prank(owner);
        vault.setProfitsDistribution(initial, initialPercent);

        // Remove devFund, give all to treasury
        address[] memory updated = new address[](2);
        updated[0] = devFund;
        updated[1] = treasury;
        uint16[] memory updatedPercent = new uint16[](2);
        updatedPercent[0] = 0; // Remove devFund
        updatedPercent[1] = HUNDRED_PERCENT;

        vm.prank(owner);
        vault.setProfitsDistribution(updated, updatedPercent);

        // Assert
        (bool isDevRecipient, uint256 devPct) = vault.getProfitRecipientInfo(devFund);
        (bool isTreasuryRecipient, uint256 treasuryPct) = vault.getProfitRecipientInfo(treasury);

        assertEq(devPct, 0, "DevFund should be 0 (kept for audit trail)");
        assertEq(isDevRecipient, false, "DevFund should not be active recipient");
        assertEq(treasuryPct, HUNDRED_PERCENT, "Treasury should have 100%");
        assertEq(isTreasuryRecipient, true);
    }

    /// @notice Event emission with privacy (no recipient details)
    function test_SetProfitsDistribution_EmitsEvent() public {
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;

        // Expect event with only timestamp (privacy)
        vm.expectEmit(false, false, false, true);
        emit IKingVault.ProfitsDistributionUpdated(block.timestamp);

        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    // ============================================
    // Error Cases
    // ============================================

    /// @notice TS-16: Invalid distribution total (not 100%)
    function test_SetProfitsDistribution_RevertsForInvalidTotal_TooLow() public {
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = 9000; // Only 90%

        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidDistributionTotal.selector, 9000));
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    function test_SetProfitsDistribution_RevertsForInvalidTotal_TooHigh() public {
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = 11000; // 110%

        // First revert on InvalidPercentage (individual check)
        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidPercentage.selector));
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    function test_SetProfitsDistribution_RevertsForInvalidTotal_MultipleNotSumming() public {
        address[] memory recipients = new address[](2);
        recipients[0] = treasury;
        recipients[1] = devFund;
        uint16[] memory percents = new uint16[](2);
        percents[0] = 6000; // 60%
        percents[1] = 3000; // 30% - total 90%

        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidDistributionTotal.selector, 9000));
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    /// @notice Zero address recipient
    function test_SetProfitsDistribution_RevertsForZeroAddress() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0);
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;

        vm.expectRevert(abi.encodeWithSelector(IKingVault.ZeroAddress.selector));
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    /// @notice Empty arrays
    function test_SetProfitsDistribution_RevertsForEmptyArrays() public {
        address[] memory recipients = new address[](0);
        uint16[] memory percents = new uint16[](0);

        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidAssetArray.selector));
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    /// @notice Mismatched array lengths
    function test_SetProfitsDistribution_RevertsForMismatchedArrays() public {
        address[] memory recipients = new address[](2);
        recipients[0] = treasury;
        recipients[1] = devFund;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;

        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidAssetArray.selector));
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    /// @notice Invalid percentage > 10000
    function test_SetProfitsDistribution_RevertsForPercentageAboveMax() public {
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = 10001; // 100.01%

        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidPercentage.selector));
        vm.prank(owner);
        vault.setProfitsDistribution(recipients, percents);
    }

    /// @notice Unauthorized caller
    function test_SetProfitsDistribution_RevertsForUnauthorizedCaller() public {
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;

        vm.expectRevert(); // Ownable2Step reverts with specific error
        vm.prank(unauthorized);
        vault.setProfitsDistribution(recipients, percents);
    }

    function test_SetProfitsDistribution_RevertsForKingVault() public {
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory percents = new uint16[](1);
        percents[0] = HUNDRED_PERCENT;

        vm.expectRevert(); // Only owner, not kingVault
        vm.prank(kingVault);
        vault.setProfitsDistribution(recipients, percents);
    }
}
