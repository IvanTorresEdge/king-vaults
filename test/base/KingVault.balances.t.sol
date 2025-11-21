// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingVaultHarness} from "./KingVaultHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title KingVaultBalancesTest
 * @notice Tests for getBalances() and getBalance() view functions (Tasks 1.4-1.5)
 */
contract KingVaultBalancesTest is Test {
    KingVaultHarness public vault;
    KingVaultHarness public implementation;

    MockERC20 public token1; // 18 decimals
    MockERC20 public token2; // 18 decimals
    MockERC20 public token3; // 6 decimals

    address public owner = address(0x1);
    address public kingVault;
    address public priceProvider = address(0x3);

    function setUp() public {
        kingVault = address(new MockKingVaultController());
        // Deploy implementation
        implementation = new KingVaultHarness();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(KingVaultHarness.initialize.selector, owner, kingVault, priceProvider);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = KingVaultHarness(address(proxy));

        // Deploy mock tokens
        token1 = new MockERC20("Token1", "TK1", 18);
        token2 = new MockERC20("Token2", "TK2", 18);
        token3 = new MockERC20("Token3", "TK3", 6);

        // Register tokens as accepted
        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token3);

        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        vm.prank(owner);
        vault.registerAssets(tokens, accepted);

        // Mint tokens to kingVault for deposits
        token1.mint(kingVault, 1000e18);
        token2.mint(kingVault, 500e18);
        token3.mint(kingVault, 100e6);
    }

    function test_getBalances_empty() public view {
        (address[] memory assets, uint256[] memory amounts) = vault.getBalances();

        assertEq(assets.length, 3, "Should return 3 assets");
        assertEq(amounts.length, 3, "Should return 3 amounts");
        assertEq(amounts[0], 0, "Token1 balance should be 0");
        assertEq(amounts[1], 0, "Token2 balance should be 0");
        assertEq(amounts[2], 0, "Token3 balance should be 0");
    }

    function test_getBalances_afterDeposit() public {
        // Deposit tokens
        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 50e18;

        vm.startPrank(kingVault);
        token1.approve(address(vault), 100e18);
        token2.approve(address(vault), 50e18);
        vault.deposit(tokens, amounts);
        vm.stopPrank();

        // Check balances
        (address[] memory returnedAssets, uint256[] memory returnedAmounts) = vault.getBalances();

        assertEq(returnedAssets.length, 3, "Should return 3 assets");
        assertEq(returnedAmounts.length, 3, "Should return 3 amounts");

        // Find token1 and token2 in returned arrays
        for (uint256 i = 0; i < returnedAssets.length; i++) {
            if (returnedAssets[i] == address(token1)) {
                assertEq(returnedAmounts[i], 100e18, "Token1 balance incorrect");
            } else if (returnedAssets[i] == address(token2)) {
                assertEq(returnedAmounts[i], 50e18, "Token2 balance incorrect");
            } else if (returnedAssets[i] == address(token3)) {
                assertEq(returnedAmounts[i], 0, "Token3 balance should be 0");
            }
        }
    }

    function test_getBalances_parallelArrays() public {
        // Deposit all tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token3);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18;
        amounts[1] = 50e18;
        amounts[2] = 25e6;

        vm.startPrank(kingVault);
        token1.approve(address(vault), 100e18);
        token2.approve(address(vault), 50e18);
        token3.approve(address(vault), 25e6);
        vault.deposit(tokens, amounts);
        vm.stopPrank();

        // Get balances
        (address[] memory returnedAssets, uint256[] memory returnedAmounts) = vault.getBalances();

        // Verify parallel arrays
        assertEq(returnedAssets.length, returnedAmounts.length, "Arrays must be same length");

        // Verify each asset matches its amount
        for (uint256 i = 0; i < returnedAssets.length; i++) {
            if (returnedAssets[i] == address(token1)) {
                assertEq(returnedAmounts[i], 100e18, "Token1 mismatch");
            } else if (returnedAssets[i] == address(token2)) {
                assertEq(returnedAmounts[i], 50e18, "Token2 mismatch");
            } else if (returnedAssets[i] == address(token3)) {
                assertEq(returnedAmounts[i], 25e6, "Token3 mismatch");
            }
        }
    }

    function test_getBalance_single() public {
        // Initially zero
        assertEq(vault.getBalance(address(token1)), 0, "Should be 0 before deposit");

        // Deposit token1
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.startPrank(kingVault);
        token1.approve(address(vault), 100e18);
        vault.deposit(tokens, amounts);
        vm.stopPrank();

        // Check balance
        assertEq(vault.getBalance(address(token1)), 100e18, "Token1 balance incorrect");
        assertEq(vault.getBalance(address(token2)), 0, "Token2 should still be 0");
    }

    function test_getBalance_unregisteredAsset() public {
        address unknownToken = makeAddr("unknownToken");
        assertEq(vault.getBalance(unknownToken), 0, "Unregistered asset should return 0");
    }

    function test_getBalance_afterWithdrawal() public {
        // Deposit
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        vm.startPrank(kingVault);
        token1.approve(address(vault), 100e18);
        vault.deposit(tokens, amounts);

        // Check balance
        assertEq(vault.getBalance(address(token1)), 100e18, "Balance after deposit");

        // Withdraw
        amounts[0] = 30e18;
        vault.withdraw(tokens, amounts, kingVault);
        vm.stopPrank();

        // Check balance reduced
        assertEq(vault.getBalance(address(token1)), 70e18, "Balance after withdrawal");
    }

    function test_getBalances_consistency_with_getBalance() public {
        // Deposit multiple tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token3);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18;
        amounts[1] = 50e18;
        amounts[2] = 25e6;

        vm.startPrank(kingVault);
        token1.approve(address(vault), 100e18);
        token2.approve(address(vault), 50e18);
        token3.approve(address(vault), 25e6);
        vault.deposit(tokens, amounts);
        vm.stopPrank();

        // Get balances via both methods
        (address[] memory returnedAssets, uint256[] memory returnedAmounts) = vault.getBalances();

        // Verify consistency
        for (uint256 i = 0; i < returnedAssets.length; i++) {
            uint256 singleBalance = vault.getBalance(returnedAssets[i]);
            assertEq(
                singleBalance,
                returnedAmounts[i],
                string(abi.encodePacked("Balance mismatch for asset ", vm.toString(returnedAssets[i])))
            );
        }
    }

    function test_getBalance_tracksDeposits() public {
        // Multiple deposits should accumulate
        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);

        uint256[] memory amounts = new uint256[](1);

        vm.startPrank(kingVault);

        // First deposit
        amounts[0] = 100e18;
        token1.approve(address(vault), 100e18);
        vault.deposit(tokens, amounts);
        assertEq(vault.getBalance(address(token1)), 100e18, "After first deposit");

        // Second deposit
        amounts[0] = 50e18;
        token1.approve(address(vault), 50e18);
        vault.deposit(tokens, amounts);
        assertEq(vault.getBalance(address(token1)), 150e18, "After second deposit");

        vm.stopPrank();
    }
}
