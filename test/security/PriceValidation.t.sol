// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingBoringVault} from "../../src/vaults/KingBoringVault.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockTeller, MockAccountant, MockAtomicQueue} from "./KingBoringVault.security.t.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";

/**
 * @title PriceValidationTest
 * @notice Tests for HIGH-2 Oracle Price Manipulation fix
 * @dev Verifies price staleness and validity checks prevent manipulation
 */
contract PriceValidationTest is Test {
    KingBoringVault public vault;
    MockERC20 public weth;
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
        vaultToken = new MockERC20("Vault", "VLT", 18);

        // Deploy price provider with default ETH/USD price
        priceProvider = new MockPriceProvider(2000e18);
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH

        // Deploy mock Veda contracts
        MockTeller teller = new MockTeller(address(vaultToken));
        MockAccountant accountant = new MockAccountant(address(weth), address(vaultToken));
        teller.setAccountant(address(accountant));
        accountant.setRate(1.0e18);
        MockAtomicQueue queue = new MockAtomicQueue();

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
            address(queue),
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
    }

    /**
     * @notice Test that fresh prices work correctly
     */
    function test_PriceValidation_FreshPriceWorks() public {
        // Deposit some tokens
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // TVL should work with fresh price
        (uint256 ethValue, uint256 usdValue) = vault.tvl();
        assertEq(ethValue, 100e18, "ETH value should match deposit");
        assertGt(usdValue, 0, "USD value should be calculated");
    }

    /**
     * @notice Test that stale prices are rejected
     */
    function test_PriceValidation_RevertsOnStalePrice() public {
        // Deposit some tokens
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Set price timestamp to 7 hours ago (older than 6 hour max)
        priceProvider.setPriceTimestamp(address(weth), block.timestamp - 7 hours);

        // TVL should revert due to stale price
        vm.expectRevert(abi.encodeWithSelector(IKingVault.PriceStale.selector, address(weth), 7 hours, 6 hours));
        vault.tvl();
    }

    /**
     * @notice Test that prices within staleness threshold work
     */
    function test_PriceValidation_AcceptsPriceWithinThreshold() public {
        // Deposit some tokens
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Set price timestamp to 5 hours ago (within 6 hour max)
        priceProvider.setPriceTimestamp(address(weth), block.timestamp - 5 hours);

        // TVL should work with price within threshold
        (uint256 ethValue,) = vault.tvl();
        assertEq(ethValue, 100e18, "Should accept price within staleness threshold");
    }

    /**
     * @notice Test that invalid prices are rejected
     */
    function test_PriceValidation_RevertsOnInvalidPrice() public {
        // Deposit some tokens
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Mark price as invalid
        priceProvider.setPriceInvalid(address(weth), true);

        // TVL should revert due to invalid price
        vm.expectRevert(abi.encodeWithSelector(IKingVault.PriceInvalid.selector, address(weth)));
        vault.tvl();
    }

    /**
     * @notice Test setMaxPriceAge function
     */
    function test_PriceValidation_SetMaxPriceAge() public {
        // Only owner can set max price age
        vm.expectRevert();
        vm.prank(kingVault);
        vault.setMaxPriceAge(12 hours);

        // Owner can set max price age
        vm.prank(owner);
        vault.setMaxPriceAge(12 hours);
        assertEq(vault.maxPriceAge(), 12 hours, "Max price age should be updated");

        // Cannot set to 0
        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidMaxPriceAge.selector, 0));
        vm.prank(owner);
        vault.setMaxPriceAge(0);

        // Cannot set to > 1 day
        vm.expectRevert(abi.encodeWithSelector(IKingVault.InvalidMaxPriceAge.selector, 2 days));
        vm.prank(owner);
        vault.setMaxPriceAge(2 days);
    }

    /**
     * @notice Test that updated max price age is applied
     */
    function test_PriceValidation_UpdatedMaxPriceAgeApplied() public {
        // Deposit some tokens
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Set price timestamp to 10 hours ago
        priceProvider.setPriceTimestamp(address(weth), block.timestamp - 10 hours);

        // Should revert with default 6 hour max
        vm.expectRevert();
        vault.tvl();

        // Increase max price age to 12 hours
        vm.prank(owner);
        vault.setMaxPriceAge(12 hours);

        // Now should work
        (uint256 ethValue,) = vault.tvl();
        assertEq(ethValue, 100e18, "Should accept price with updated threshold");
    }

    /**
     * @notice Test that stale ETH/USD price is also rejected
     */
    function test_PriceValidation_RevertsOnStaleEthUsdPrice() public {
        // Deposit some tokens
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Set ETH/USD price timestamp to 7 hours ago
        priceProvider.setEthUsdTimestamp(block.timestamp - 7 hours);

        // TVL should revert due to stale ETH/USD price
        vm.expectRevert(
            abi.encodeWithSelector(
                IKingVault.PriceStale.selector,
                address(0), // address(0) indicates ETH/USD
                7 hours,
                6 hours
            )
        );
        vault.tvl();
    }

    /**
     * @notice Test that invalid ETH/USD price is rejected
     */
    function test_PriceValidation_RevertsOnInvalidEthUsdPrice() public {
        // Deposit some tokens
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Mark ETH/USD price as invalid
        priceProvider.setEthUsdInvalid(true);

        // TVL should revert due to invalid ETH/USD price
        vm.expectRevert(abi.encodeWithSelector(IKingVault.PriceInvalid.selector, address(0)));
        vault.tvl();
    }

    /**
     * @notice Test that calculateProfit also validates prices
     */
    function test_PriceValidation_CalculateProfitValidatesPrices() public {
        // Deposit some tokens
        weth.mint(kingVault, 100e18);
        vm.prank(kingVault);
        weth.approve(address(vault), 100e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.prank(kingVault);
        vault.deposit(tokens, amounts);

        // Set stale price
        priceProvider.setPriceTimestamp(address(weth), block.timestamp - 7 hours);

        // calculateProfit should also revert on stale price
        vm.expectRevert();
        vault.calculateProfit();
    }
}
