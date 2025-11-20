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

/**
 * @title KingVaultContractValidationTest
 * @notice Tests for HIGH-5 Missing Contract Validation for kingVault Address fix
 * @dev Verifies that kingVault address is validated to be a contract during initialization
 */
contract KingVaultContractValidationTest is Test {
    MockERC20 public weth;
    MockERC20 public vaultToken;
    MockPriceProvider public priceProvider;
    MockTeller public teller;
    MockAccountant public accountant;
    MockAtomicQueue public atomicQueue;

    address public owner = address(0x1);
    address public kingVaultContract = address(0x2); // Will be set to a contract
    address public kingVaultEOA = address(0x3); // EOA address (no code)

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

        // Deploy a simple contract to use as kingVault (mock contract with code)
        kingVaultContract = address(new MockERC20("King", "KING", 18));
    }

    /**
     * @notice Test that KingBoringVault initialization succeeds when kingVault is a contract
     */
    function test_ContractValidation_BoringVaultInitSucceedsWithContract() public {
        KingBoringVault implementation = new KingBoringVault(address(vaultToken), address(teller), address(accountant));

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector,
            owner,
            kingVaultContract, // Using contract address
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );

        // Should succeed
        KingBoringVault vault = KingBoringVault(address(new ERC1967Proxy(address(implementation), initData)));

        assertEq(vault.kingVault(), kingVaultContract, "kingVault should be set correctly");
    }

    /**
     * @notice Test that KingBoringVault initialization reverts when kingVault is an EOA
     */
    function test_ContractValidation_BoringVaultInitRevertsWithEOA() public {
        KingBoringVault implementation = new KingBoringVault(address(vaultToken), address(teller), address(accountant));

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector,
            owner,
            kingVaultEOA, // Using EOA address
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );

        // Should revert with InvalidContract error
        vm.expectRevert(IKingVault.InvalidContract.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /**
     * @notice Test that KingTokenizedVault initialization succeeds when kingVault is a contract
     */
    function test_ContractValidation_TokenizedVaultInitSucceedsWithContract() public {
        // Deploy a mock ERC4626 vault
        MockERC20 erc4626Vault = new MockERC20("ERC4626", "V4626", 18);

        KingTokenizedVault implementation = new KingTokenizedVault(address(erc4626Vault), true);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector,
            owner,
            kingVaultContract, // Using contract address
            address(priceProvider),
            tokens,
            accepted
        );

        // Should succeed
        KingTokenizedVault vault = KingTokenizedVault(address(new ERC1967Proxy(address(implementation), initData)));

        assertEq(vault.kingVault(), kingVaultContract, "kingVault should be set correctly");
    }

    /**
     * @notice Test that KingTokenizedVault initialization reverts when kingVault is an EOA
     */
    function test_ContractValidation_TokenizedVaultInitRevertsWithEOA() public {
        // Deploy a mock ERC4626 vault
        MockERC20 erc4626Vault = new MockERC20("ERC4626", "V4626", 18);

        KingTokenizedVault implementation = new KingTokenizedVault(address(erc4626Vault), true);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector,
            owner,
            kingVaultEOA, // Using EOA address
            address(priceProvider),
            tokens,
            accepted
        );

        // Should revert with InvalidContract error
        vm.expectRevert(IKingVault.InvalidContract.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /**
     * @notice Test that validation happens after zero address check
     * @dev Zero address should fail first with ZeroAddress error
     */
    function test_ContractValidation_ZeroAddressCheckPrecedence() public {
        KingBoringVault implementation = new KingBoringVault(address(vaultToken), address(teller), address(accountant));

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector,
            owner,
            address(0), // Zero address
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );

        // Should revert with ZeroAddress error (checked before InvalidContract)
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    /**
     * @notice Test that validation prevents accidental EOA configuration
     * @dev Simulates real-world scenario where an EOA address is accidentally used
     */
    function test_ContractValidation_PreventsAccidentalEOAConfig() public {
        // Create a fresh EOA address (simulating human error)
        address accidentalEOA = address(0x999999);

        // Verify it's not a contract
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(accidentalEOA)
        }
        assertEq(codeSize, 0, "EOA should have no code");

        KingBoringVault implementation = new KingBoringVault(address(vaultToken), address(teller), address(accountant));

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector,
            owner,
            accidentalEOA, // Accidental EOA address
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );

        // Should prevent deployment with InvalidContract error
        vm.expectRevert(IKingVault.InvalidContract.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
}
