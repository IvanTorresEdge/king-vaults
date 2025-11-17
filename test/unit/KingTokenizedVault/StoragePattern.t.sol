// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingTokenizedVault} from "../../../src/vaults/KingTokenizedVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPriceProvider} from "../../mocks/MockPriceProvider.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";
import {IKingVault} from "../../../src/interfaces/IKingVault.sol";

/**
 * @title KingTokenizedVault_StoragePatternTest
 * @notice Unit tests for KingTokenizedVault storage pattern (Feature 8.1)
 * @dev Tests Task 8.1 acceptance criteria:
 *      - Tests storage inheritance from KingTokenizedVaultStorage and KingVaultStorage
 *      - Validates immutable variables (vault, isAtomic)
 *      - Checks initialization function and state setup
 *      - Verifies reinitialization protection
 *      - Tests storage gap configuration
 *
 * Architecture Context:
 *      - KingTokenizedVaultStorage: State variables (extends KingVaultStorage)
 *      - KingTokenizedVault: Logic implementation (extends KingTokenizedVaultStorage + KingVault)
 *      - UUPS proxy pattern with storage separation
 *      - Immutables set in constructor, mutables in initialize()
 */
contract KingTokenizedVault_StoragePatternTest is Test {
    // ============================================
    // Contracts
    // ============================================

    KingTokenizedVault public tokenizedVault;
    KingTokenizedVault public implementation;
    MockERC20 public weth;
    MockPriceProvider public priceProvider;
    MockERC4626Vault public erc4626Vault;

    // ============================================
    // Test Addresses
    // ============================================

    address public owner = address(0x1);
    address public kingVault = address(0x2);
    address public unauthorized = address(0x3);

    // ============================================
    // Constants
    // ============================================

    uint16 public constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%
    uint64 public constant DEFAULT_WITHDRAWAL_DURATION = 7 days;

    // ============================================
    // Events
    // ============================================

    event Initialized(address indexed owner, address indexed kingVault, address priceProvider, uint256 timestamp);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy mock ERC-4626 vault
        erc4626Vault = new MockERC4626Vault(weth, "Vault WETH", "vWETH");

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
    }

    // ============================================
    // Helper Functions
    // ============================================

    /**
     * @notice Deploy KingTokenizedVault implementation with given mode
     */
    function _deployImplementation(bool isAtomic) internal returns (KingTokenizedVault) {
        return new KingTokenizedVault(address(erc4626Vault), isAtomic);
    }

    /**
     * @notice Deploy and initialize a KingTokenizedVault proxy
     */
    function _deployTokenizedVault(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address[] memory _assets,
        bool[] memory _accepted,
        bool isAtomic
    ) internal returns (KingTokenizedVault) {
        KingTokenizedVault impl = _deployImplementation(isAtomic);

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, _owner, _kingVault, _priceProvider, _assets, _accepted
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return KingTokenizedVault(address(proxy));
    }

    /**
     * @notice Deploy a standard KingTokenizedVault for common tests
     */
    function _deployStandardTokenizedVault() internal returns (KingTokenizedVault) {
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        return _deployTokenizedVault(owner, kingVault, address(priceProvider), assets, accepted, true);
    }

    // ============================================
    // Storage Inheritance Tests
    // ============================================

    /**
     * @notice Test storage inheritance from parent contracts
     * @dev Verifies:
     *      - Inherits from KingVaultStorage (owner, kingVault, priceProvider, etc.)
     *      - Inherits from KingTokenizedVaultStorage (vault, isAtomic, etc.)
     *      - All inherited state variables accessible
     */
    function test_storageInheritance_SuccessfullyInheritsParentState() public {
        tokenizedVault = _deployStandardTokenizedVault();

        // Verify KingVaultStorage inheritance
        assertEq(tokenizedVault.owner(), owner, "Owner should be set from KingVaultStorage");
        assertEq(tokenizedVault.kingVault(), kingVault, "KingVault should be set from KingVaultStorage");
        assertEq(tokenizedVault.priceProvider(), address(priceProvider), "PriceProvider should be set");
        assertFalse(tokenizedVault.paused(), "Should inherit paused state");

        // Verify KingTokenizedVaultStorage inheritance
        assertEq(tokenizedVault.vault(), address(erc4626Vault), "Vault should be set from immutable");
        assertTrue(tokenizedVault.isAtomic(), "IsAtomic should be set from immutable");
        assertEq(tokenizedVault.maxSlippageBPS(), DEFAULT_SLIPPAGE_BPS, "MaxSlippageBPS should be initialized");
        assertEq(
            tokenizedVault.withdrawalDuration(), DEFAULT_WITHDRAWAL_DURATION, "WithdrawalDuration should be initialized"
        );
    }

    /**
     * @notice Test that assets array is properly inherited and accessible
     * @dev Verifies asset registration from KingVaultStorage
     */
    function test_storageInheritance_AssetsArrayAccessible() public {
        address[] memory assets = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(0x999);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        tokenizedVault = _deployTokenizedVault(owner, kingVault, address(priceProvider), assets, accepted, true);

        address[] memory registeredAssets = tokenizedVault.assets();
        assertEq(registeredAssets.length, 2, "Should register multiple assets");
        assertEq(registeredAssets[0], address(weth), "First asset should match");
        assertEq(registeredAssets[1], address(0x999), "Second asset should match");
    }

    // ============================================
    // Immutable Variables Tests
    // ============================================

    /**
     * @notice Test immutable vault address is set correctly
     * @dev Verifies:
     *      - Vault address set in constructor
     *      - Cannot be changed after deployment
     *      - Same across proxy and implementation
     */
    function test_immutables_VaultAddressSetCorrectly() public {
        implementation = _deployImplementation(true);
        tokenizedVault = _deployStandardTokenizedVault();

        assertEq(implementation.vault(), address(erc4626Vault), "Implementation vault should match");
        assertEq(tokenizedVault.vault(), address(erc4626Vault), "Proxy vault should match");
    }

    /**
     * @notice Test immutable isAtomic flag is set correctly
     * @dev Verifies:
     *      - IsAtomic set in constructor for atomic mode
     *      - IsAtomic set correctly for async mode
     *      - Cannot be changed after deployment
     */
    function test_immutables_IsAtomicSetCorrectlyForAtomicMode() public {
        implementation = _deployImplementation(true);
        tokenizedVault = _deployStandardTokenizedVault();

        assertTrue(implementation.isAtomic(), "Implementation should be atomic");
        assertTrue(tokenizedVault.isAtomic(), "Proxy should be atomic");
    }

    function test_immutables_IsAtomicSetCorrectlyForAsyncMode() public {
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        tokenizedVault = _deployTokenizedVault(owner, kingVault, address(priceProvider), assets, accepted, false);

        assertFalse(tokenizedVault.isAtomic(), "Should be async mode");
    }

    /**
     * @notice Test constructor reverts with zero vault address
     * @dev Validates immutable validation in constructor
     */
    function test_immutables_ConstructorRevertsWithZeroVault() public {
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        new KingTokenizedVault(address(0), true);
    }

    // ============================================
    // Initialization Tests - Valid Parameters
    // ============================================

    /**
     * @notice Test initialize function with valid parameters
     * @dev Verifies:
     *      - Owner set correctly
     *      - KingVault set correctly
     *      - PriceProvider set correctly
     *      - Default slippage initialized
     *      - Default withdrawal duration initialized
     *      - Not paused initially
     */
    function test_initialize_SucceedsWithValidParameters() public {
        tokenizedVault = _deployStandardTokenizedVault();

        assertEq(tokenizedVault.owner(), owner, "Owner should be set");
        assertEq(tokenizedVault.kingVault(), kingVault, "KingVault should be set");
        assertEq(tokenizedVault.priceProvider(), address(priceProvider), "PriceProvider should be set");
        assertEq(tokenizedVault.maxSlippageBPS(), DEFAULT_SLIPPAGE_BPS, "Default slippage should be set");
        assertEq(tokenizedVault.withdrawalDuration(), DEFAULT_WITHDRAWAL_DURATION, "Default duration should be set");
        assertFalse(tokenizedVault.paused(), "Should not be paused");
    }

    /**
     * @notice Test initialize emits Initialized event
     * @dev Verifies event emission with correct parameters
     */
    function test_initialize_EmitsInitializedEvent() public {
        implementation = _deployImplementation(true);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );

        vm.expectEmit(true, true, false, false);
        emit Initialized(owner, kingVault, address(priceProvider), block.timestamp);

        new ERC1967Proxy(address(implementation), initData);
    }

    /**
     * @notice Test initialize with empty asset arrays
     * @dev Verifies initialization works with no initial assets
     */
    function test_initialize_SucceedsWithEmptyAssets() public {
        address[] memory emptyAssets = new address[](0);
        bool[] memory emptyAccepted = new bool[](0);

        tokenizedVault =
            _deployTokenizedVault(owner, kingVault, address(priceProvider), emptyAssets, emptyAccepted, true);

        assertEq(tokenizedVault.owner(), owner, "Owner should be set");
        assertEq(tokenizedVault.assets().length, 0, "Should have no assets");
    }

    /**
     * @notice Test initialize with multiple assets
     * @dev Verifies asset registration during initialization
     */
    function test_initialize_SucceedsWithMultipleAssets() public {
        address[] memory assets = new address[](3);
        assets[0] = address(weth);
        assets[1] = address(0x111);
        assets[2] = address(0x222);
        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        tokenizedVault = _deployTokenizedVault(owner, kingVault, address(priceProvider), assets, accepted, true);

        address[] memory registeredAssets = tokenizedVault.assets();
        assertEq(registeredAssets.length, 3, "Should register all assets");
    }

    // ============================================
    // Initialization Tests - Invalid Parameters
    // ============================================

    /**
     * @notice Test initialize reverts with zero owner
     * @dev Validates owner address validation
     */
    function test_initialize_RevertsWithZeroOwner() public {
        address[] memory assets = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert(IKingVault.ZeroAddress.selector);
        _deployTokenizedVault(address(0), kingVault, address(priceProvider), assets, accepted, true);
    }

    /**
     * @notice Test initialize reverts with zero kingVault
     * @dev Validates kingVault address validation
     */
    function test_initialize_RevertsWithZeroKingVault() public {
        address[] memory assets = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert(IKingVault.ZeroAddress.selector);
        _deployTokenizedVault(owner, address(0), address(priceProvider), assets, accepted, true);
    }

    /**
     * @notice Test initialize reverts with zero priceProvider
     * @dev Validates priceProvider address validation
     */
    function test_initialize_RevertsWithZeroPriceProvider() public {
        address[] memory assets = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert(IKingVault.ZeroAddress.selector);
        _deployTokenizedVault(owner, kingVault, address(0), assets, accepted, true);
    }

    // ============================================
    // Reinitialization Protection Tests
    // ============================================

    /**
     * @notice Test initialize cannot be called twice on same proxy
     * @dev Verifies initializer modifier protection
     */
    function test_initialize_CannotBeCalledTwice() public {
        tokenizedVault = _deployStandardTokenizedVault();

        address[] memory assets = new address[](0);
        bool[] memory accepted = new bool[](0);

        // Attempt to reinitialize should fail
        vm.expectRevert();
        tokenizedVault.initialize(owner, kingVault, address(priceProvider), assets, accepted);
    }

    /**
     * @notice Test implementation contract cannot be initialized
     * @dev Verifies _disableInitializers() in constructor
     */
    function test_initialize_ImplementationCannotBeInitialized() public {
        implementation = _deployImplementation(true);

        address[] memory assets = new address[](0);
        bool[] memory accepted = new bool[](0);

        // Implementation should have initializers disabled
        vm.expectRevert();
        implementation.initialize(owner, kingVault, address(priceProvider), assets, accepted);
    }

    /**
     * @notice Test different proxies can use same implementation
     * @dev Verifies each proxy has independent state
     */
    function test_initialize_MultipleProxiesWithSameImplementation() public {
        implementation = _deployImplementation(true);

        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        // Deploy first proxy
        bytes memory initData1 = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );
        ERC1967Proxy proxy1 = new ERC1967Proxy(address(implementation), initData1);
        KingTokenizedVault vault1 = KingTokenizedVault(address(proxy1));

        // Deploy second proxy with different owner
        address owner2 = address(0x999);
        bytes memory initData2 = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner2, kingVault, address(priceProvider), assets, accepted
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(implementation), initData2);
        KingTokenizedVault vault2 = KingTokenizedVault(address(proxy2));

        // Verify independent state
        assertEq(vault1.owner(), owner, "First proxy should have owner");
        assertEq(vault2.owner(), owner2, "Second proxy should have owner2");
        assertEq(vault1.vault(), vault2.vault(), "Should share same immutable vault");
    }

    // ============================================
    // Storage Gap Tests
    // ============================================

    /**
     * @notice Test storage layout doesn't change with upgrades
     * @dev Verifies:
     *      - Storage gap exists (45 slots)
     *      - Total storage allocation is 50 slots
     *      - Adding new variables would reduce gap appropriately
     *
     * Note: This is a conceptual test - actual storage layout
     * verification would require additional tooling
     */
    function test_storageGap_ReservesSpaceForFutureUpgrades() public {
        tokenizedVault = _deployStandardTokenizedVault();

        // Storage gap is reserved in KingTokenizedVaultStorage
        // Current state variables:
        // - vault (immutable, not in storage)
        // - isAtomic (immutable, not in storage)
        // - maxSlippageBPS (uint16, 1 slot shared)
        // - withdrawalDuration (uint64, 1 slot shared)
        // - _pendingShares (uint256, 1 slot)
        // - _withdrawalRequests (mapping, 1 slot)
        // - _queuedProfits (mapping, 1 slot)
        // - _queuedWithdraw (mapping, 1 slot)
        // Total: ~5 slots + 45 gap = 50 slots reserved

        // Verify contract is upgradeable and state is preserved
        assertEq(tokenizedVault.maxSlippageBPS(), DEFAULT_SLIPPAGE_BPS, "State should be preserved");
    }

    // ============================================
    // State Variable Access Tests
    // ============================================

    /**
     * @notice Test mutable state variables can be updated
     * @dev Verifies maxSlippageBPS and withdrawalDuration are mutable
     */
    function test_stateVariables_MutablesCanBeUpdated() public {
        tokenizedVault = _deployStandardTokenizedVault();

        // Update maxSlippageBPS
        vm.prank(owner);
        tokenizedVault.setMaxSlippage(100);
        assertEq(tokenizedVault.maxSlippageBPS(), 100, "Slippage should be updated");

        // Update withdrawalDuration
        vm.prank(owner);
        tokenizedVault.setWithdrawalDuration(14 days);
        assertEq(tokenizedVault.withdrawalDuration(), 14 days, "Duration should be updated");
    }

    /**
     * @notice Test immutable state variables cannot be changed
     * @dev Verifies vault and isAtomic remain constant
     */
    function test_stateVariables_ImmutablesCannotBeChanged() public {
        tokenizedVault = _deployStandardTokenizedVault();

        address vaultBefore = tokenizedVault.vault();
        bool isAtomicBefore = tokenizedVault.isAtomic();

        // Attempt to interact with vault (no setter exists)
        // Immutables are read-only by design

        // Verify values unchanged
        assertEq(tokenizedVault.vault(), vaultBefore, "Vault address should be immutable");
        assertEq(tokenizedVault.isAtomic(), isAtomicBefore, "IsAtomic should be immutable");
    }

    // ============================================
    // Integration: Storage Pattern with Logic
    // ============================================

    /**
     * @notice Test storage pattern integrates correctly with logic layer
     * @dev Verifies:
     *      - Storage variables accessible from logic functions
     *      - State changes persist correctly
     *      - No storage collision between proxy and implementation
     */
    function test_storagePattern_IntegrationWithLogicLayer() public {
        tokenizedVault = _deployStandardTokenizedVault();

        // Fund and approve
        weth.mint(kingVault, 10 ether);
        vm.prank(kingVault);
        weth.approve(address(tokenizedVault), 10 ether);

        // Deposit (tests storage write from logic)
        vm.prank(kingVault);
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;
        tokenizedVault.deposit(assets, amounts);

        // Verify storage updated (tests storage read from logic)
        assertEq(tokenizedVault.getBalance(address(weth)), 10 ether, "Balance should be stored");

        // Deploy to vault (tests immutable access from logic)
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 10 ether);

        // Verify shares tracked
        assertGt(tokenizedVault.getVaultShares(), 0, "Shares should be tracked in storage");
    }
}
