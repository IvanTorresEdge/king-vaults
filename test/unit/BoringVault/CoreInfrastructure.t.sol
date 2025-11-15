// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BoringVault} from "../../../src/vaults/BoringVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPriceProvider} from "../../mocks/MockPriceProvider.sol";
import {IKingVault} from "../../../src/interfaces/IKingVault.sol";

/**
 * @title CoreInfrastructureTest
 * @notice Comprehensive unit tests for BoringVault core infrastructure
 * @dev Tests initialization, access control, and pause functionality
 * @dev Covers Task 7.1 acceptance criteria:
 *      - Test initialize() function with valid and invalid parameters
 *      - Test that initialization cannot be called twice (reinitialize protection)
 *      - Test access control modifiers (onlyOwner, onlyKingVault, onlyOwnerOrKingVault)
 *      - Test pause/unpause functionality and state transitions
 *      - Test that paused state correctly blocks deposit/withdraw
 *      - Test that emergencyWithdraw works when paused
 *      - Verify event emissions for pause/unpause operations
 */
contract CoreInfrastructureTest is Test {
    // ============================================
    // Contracts
    // ============================================

    BoringVault public boringVault;
    BoringVault public implementation;
    MockERC20 public weth;
    MockERC20 public ethfi;
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

    event Paused(address account);
    event Unpaused(address account);
    event Deposited(address[] assets, uint256[] amounts, uint256 timestamp);
    event Withdrawn(address[] assets, uint256[] amounts, address receiver, uint256 timestamp);
    event EmergencyWithdraw(address[] assets, uint256[] amounts, uint256 timestamp);

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ethfi = new MockERC20("EtherFi Token", "ETHFI", 18);
        vaultToken = new MockERC20("Boring Vault Shares", "bvWETH", 18);

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(ethfi), 0.0005e18); // 1 ETHFI = 0.0005 ETH

        // Deploy mock Veda contracts
        teller = new MockTeller(address(vaultToken));
        accountant = new MockAccountant(address(weth), address(vaultToken));
        atomicQueue = new MockAtomicQueue();

        // Set up mock exchange rate in accountant (1 share = 1.2 WETH)
        accountant.setRate(1.2e18);

        // Deploy BoringVault implementation (with immutable addresses)
        implementation = new BoringVault(
            address(vaultToken), // vault
            address(teller), // teller
            address(accountant) // accountant
        );
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
            BoringVault.initialize.selector, _owner, _kingVault, _priceProvider, _atomicQueue, _tokens, _accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return BoringVault(address(proxy));
    }

    /**
     * @notice Deploy a properly initialized BoringVault for standard tests
     */
    function _deployStandardBoringVault() internal returns (BoringVault) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        return _deployBoringVault(owner, kingVault, address(priceProvider), address(atomicQueue), tokens, accepted);
    }

    // ============================================
    // Initialization Tests - Valid Parameters
    // ============================================

    function test_Initialize_SucceedsWithValidParameters() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        bool[] memory accepted = new bool[](1);
        accepted[0] = true;

        boringVault =
            _deployBoringVault(owner, kingVault, address(priceProvider), address(atomicQueue), tokens, accepted);

        // Verify owner set correctly
        assertEq(boringVault.owner(), owner);

        // Verify kingVault set correctly
        assertEq(boringVault.kingVault(), kingVault);

        // Verify priceProvider set correctly
        assertEq(boringVault.priceProvider(), address(priceProvider));

        // Verify atomicQueue set correctly
        assertEq(boringVault.atomicQueue(), address(atomicQueue));

        // Verify not paused initially
        assertFalse(boringVault.paused());

        // Verify default slippage set
        assertEq(boringVault.maxSlippageBPS(), 50); // DEFAULT_SLIPPAGE_BPS

        // Verify default withdrawal duration set
        assertEq(boringVault.withdrawalDuration(), 7 days);

        // Verify immutable addresses from constructor
        assertEq(boringVault.vault(), address(vaultToken));
        assertEq(boringVault.teller(), address(teller));
        assertEq(boringVault.accountant(), address(accountant));
    }

    function test_Initialize_SucceedsWithEmptyTokenArrays() public {
        address[] memory emptyTokens = new address[](0);
        bool[] memory emptyAccepted = new bool[](0);

        boringVault = _deployBoringVault(
            owner, kingVault, address(priceProvider), address(atomicQueue), emptyTokens, emptyAccepted
        );

        assertEq(boringVault.owner(), owner);
        assertEq(boringVault.kingVault(), kingVault);
    }

    function test_Initialize_SucceedsWithMultipleTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        boringVault =
            _deployBoringVault(owner, kingVault, address(priceProvider), address(atomicQueue), tokens, accepted);

        // Verify both tokens registered
        address[] memory registeredAssets = boringVault.assets();
        assertEq(registeredAssets.length, 2);
    }

    // ============================================
    // Initialization Tests - Invalid Parameters
    // ============================================

    function test_Initialize_RevertsWithZeroOwner() public {
        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert(IKingVault.ZeroAddress.selector);
        _deployBoringVault(address(0), kingVault, address(priceProvider), address(atomicQueue), tokens, accepted);
    }

    function test_Initialize_RevertsWithZeroKingVault() public {
        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert(IKingVault.ZeroAddress.selector);
        _deployBoringVault(owner, address(0), address(priceProvider), address(atomicQueue), tokens, accepted);
    }

    function test_Initialize_RevertsWithZeroPriceProvider() public {
        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert(IKingVault.ZeroAddress.selector);
        _deployBoringVault(owner, kingVault, address(0), address(atomicQueue), tokens, accepted);
    }

    function test_Initialize_RevertsWithZeroAtomicQueue() public {
        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        vm.expectRevert(IKingVault.ZeroAddress.selector);
        _deployBoringVault(owner, kingVault, address(priceProvider), address(0), tokens, accepted);
    }

    // ============================================
    // Reinitialization Protection Tests
    // ============================================

    function test_Initialize_CannotBeCalledTwice() public {
        boringVault = _deployStandardBoringVault();

        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        // Attempt to reinitialize should fail
        vm.expectRevert();
        boringVault.initialize(owner, kingVault, address(priceProvider), address(atomicQueue), tokens, accepted);
    }

    function test_Initialize_ImplementationCannotBeInitialized() public {
        address[] memory tokens = new address[](0);
        bool[] memory accepted = new bool[](0);

        // Implementation contract should have initializers disabled
        vm.expectRevert();
        implementation.initialize(owner, kingVault, address(priceProvider), address(atomicQueue), tokens, accepted);
    }

    // ============================================
    // Constructor Tests - Immutable Addresses
    // ============================================

    function test_Constructor_RevertsWithZeroVault() public {
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        new BoringVault(
            address(0), // zero vault
            address(teller),
            address(accountant)
        );
    }

    function test_Constructor_RevertsWithZeroTeller() public {
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        new BoringVault(
            address(vaultToken),
            address(0), // zero teller
            address(accountant)
        );
    }

    function test_Constructor_RevertsWithZeroAccountant() public {
        vm.expectRevert(IKingVault.ZeroAddress.selector);
        new BoringVault(
            address(vaultToken),
            address(teller),
            address(0) // zero accountant
        );
    }

    function test_Constructor_SetsImmutableAddresses() public {
        BoringVault vault = new BoringVault(address(vaultToken), address(teller), address(accountant));

        assertEq(vault.vault(), address(vaultToken));
        assertEq(vault.teller(), address(teller));
        assertEq(vault.accountant(), address(accountant));
    }

    // ============================================
    // Access Control Tests - onlyOwner
    // ============================================

    function test_AccessControl_OnlyOwner_SucceedsForOwner() public {
        boringVault = _deployStandardBoringVault();

        // Owner can call owner-only functions
        vm.prank(owner);
        boringVault.pause();
        assertTrue(boringVault.paused());
    }

    function test_AccessControl_OnlyOwner_RevertsForUnauthorized() public {
        boringVault = _deployStandardBoringVault();

        // Unauthorized caller cannot call owner-only functions
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", unauthorized));
        boringVault.setMaxSlippage(100);
    }

    function test_AccessControl_OnlyOwner_RevertsForKingVault() public {
        boringVault = _deployStandardBoringVault();

        // KingVault cannot call owner-only functions (like setMaxSlippage)
        vm.prank(kingVault);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", kingVault));
        boringVault.setMaxSlippage(100);
    }

    // ============================================
    // Access Control Tests - onlyKingVault
    // ============================================

    function test_AccessControl_OnlyKingVault_SucceedsForKingVault() public {
        boringVault = _deployStandardBoringVault();

        // Prepare deposit
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Mint and approve tokens
        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);

        // KingVault can call kingVault-only functions
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);
    }

    function test_AccessControl_OnlyKingVault_RevertsForOwner() public {
        boringVault = _deployStandardBoringVault();

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Owner cannot call kingVault-only functions
        vm.prank(owner);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        boringVault.deposit(tokens, amounts);
    }

    function test_AccessControl_OnlyKingVault_RevertsForUnauthorized() public {
        boringVault = _deployStandardBoringVault();

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Unauthorized caller cannot call kingVault-only functions
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyKingVault.selector);
        boringVault.deposit(tokens, amounts);
    }

    // ============================================
    // Access Control Tests - onlyOwnerOrKingVault
    // ============================================

    function test_AccessControl_OnlyOwnerOrKingVault_SucceedsForOwner() public {
        boringVault = _deployStandardBoringVault();

        // Owner can call owner-or-kingVault functions
        vm.prank(owner);
        boringVault.pause();
        assertTrue(boringVault.paused());
    }

    function test_AccessControl_OnlyOwnerOrKingVault_SucceedsForKingVault() public {
        boringVault = _deployStandardBoringVault();

        // KingVault can call owner-or-kingVault functions
        vm.prank(kingVault);
        boringVault.pause();
        assertTrue(boringVault.paused());
    }

    function test_AccessControl_OnlyOwnerOrKingVault_RevertsForUnauthorized() public {
        boringVault = _deployStandardBoringVault();

        // Unauthorized caller cannot call owner-or-kingVault functions
        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        boringVault.pause();
    }

    function test_AccessControl_OnlyOwnerOrKingVault_EmergencyWithdrawByOwner() public {
        boringVault = _deployStandardBoringVault();

        // Owner can call emergencyWithdraw
        vm.prank(owner);
        boringVault.emergencyWithdraw();
    }

    function test_AccessControl_OnlyOwnerOrKingVault_EmergencyWithdrawByKingVault() public {
        boringVault = _deployStandardBoringVault();

        // KingVault can call emergencyWithdraw
        vm.prank(kingVault);
        boringVault.emergencyWithdraw();
    }

    // ============================================
    // Pause Tests - State Transitions
    // ============================================

    function test_Pause_SetsPausedStatus() public {
        boringVault = _deployStandardBoringVault();

        // Initially not paused
        assertFalse(boringVault.paused());

        // Owner pauses
        vm.prank(owner);
        boringVault.pause();

        // Now paused
        assertTrue(boringVault.paused());
    }

    function test_Pause_EmitsEvent() public {
        boringVault = _deployStandardBoringVault();

        // Expect Paused event with owner as caller
        vm.expectEmit(true, false, false, true);
        emit Paused(owner);

        vm.prank(owner);
        boringVault.pause();
    }

    function test_Pause_CallableByOwner() public {
        boringVault = _deployStandardBoringVault();

        vm.prank(owner);
        boringVault.pause();
        assertTrue(boringVault.paused());
    }

    function test_Pause_CallableByKingVault() public {
        boringVault = _deployStandardBoringVault();

        vm.prank(kingVault);
        boringVault.pause();
        assertTrue(boringVault.paused());
    }

    function test_Pause_RevertsForUnauthorizedCaller() public {
        boringVault = _deployStandardBoringVault();

        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        boringVault.pause();
    }

    function test_Pause_RevertsWhenAlreadyPaused() public {
        boringVault = _deployStandardBoringVault();

        vm.prank(owner);
        boringVault.pause();

        // Cannot pause again
        vm.prank(owner);
        vm.expectRevert();
        boringVault.pause();
    }

    // ============================================
    // Unpause Tests - State Transitions
    // ============================================

    function test_Unpause_ResetsPausedStatus() public {
        boringVault = _deployStandardBoringVault();

        // Pause first
        vm.prank(owner);
        boringVault.pause();
        assertTrue(boringVault.paused());

        // Unpause
        vm.prank(owner);
        boringVault.unpause();
        assertFalse(boringVault.paused());
    }

    function test_Unpause_EmitsEvent() public {
        boringVault = _deployStandardBoringVault();

        // Pause first
        vm.prank(owner);
        boringVault.pause();

        // Expect Unpaused event
        vm.expectEmit(true, false, false, true);
        emit Unpaused(owner);

        vm.prank(owner);
        boringVault.unpause();
    }

    function test_Unpause_CallableByOwner() public {
        boringVault = _deployStandardBoringVault();

        vm.prank(owner);
        boringVault.pause();

        vm.prank(owner);
        boringVault.unpause();
        assertFalse(boringVault.paused());
    }

    function test_Unpause_CallableByKingVault() public {
        boringVault = _deployStandardBoringVault();

        vm.prank(owner);
        boringVault.pause();

        vm.prank(kingVault);
        boringVault.unpause();
        assertFalse(boringVault.paused());
    }

    function test_Unpause_RevertsForUnauthorizedCaller() public {
        boringVault = _deployStandardBoringVault();

        vm.prank(owner);
        boringVault.pause();

        vm.prank(unauthorized);
        vm.expectRevert(IKingVault.OnlyOwnerOrKingVault.selector);
        boringVault.unpause();
    }

    function test_Unpause_RevertsWhenNotPaused() public {
        boringVault = _deployStandardBoringVault();

        // Cannot unpause when not paused
        vm.prank(owner);
        vm.expectRevert();
        boringVault.unpause();
    }

    function test_PauseUnpause_Cycle() public {
        boringVault = _deployStandardBoringVault();

        // Start unpaused
        assertFalse(boringVault.paused());

        // Pause
        vm.prank(owner);
        boringVault.pause();
        assertTrue(boringVault.paused());

        // Unpause
        vm.prank(owner);
        boringVault.unpause();
        assertFalse(boringVault.paused());

        // Can pause again
        vm.prank(owner);
        boringVault.pause();
        assertTrue(boringVault.paused());
    }

    // ============================================
    // Paused State Tests - deposit() Blocked
    // ============================================

    function test_Paused_DepositRevertsWhenPaused() public {
        boringVault = _deployStandardBoringVault();

        // Prepare deposit
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Mint and approve tokens
        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);

        // Pause vault
        vm.prank(owner);
        boringVault.pause();

        // Deposit should revert
        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.deposit(tokens, amounts);
    }

    function test_Paused_DepositWorksWhenNotPaused() public {
        boringVault = _deployStandardBoringVault();

        // Prepare deposit
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        // Mint and approve tokens
        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);

        // Deposit should succeed when not paused
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        assertEq(boringVault.getBalance(address(weth)), 1000e18);
    }

    // ============================================
    // Paused State Tests - withdraw() Blocked
    // ============================================

    function test_Paused_WithdrawRevertsWhenPaused() public {
        boringVault = _deployStandardBoringVault();

        // First deposit some tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Pause vault
        vm.prank(owner);
        boringVault.pause();

        // Withdraw should revert
        amounts[0] = 500e18;
        vm.prank(kingVault);
        vm.expectRevert();
        boringVault.withdraw(tokens, amounts, kingVault);
    }

    function test_Paused_WithdrawWorksWhenNotPaused() public {
        boringVault = _deployStandardBoringVault();

        // Deposit tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Withdraw should succeed when not paused
        amounts[0] = 500e18;
        vm.prank(kingVault);
        boringVault.withdraw(tokens, amounts, kingVault);

        assertEq(boringVault.getBalance(address(weth)), 500e18);
    }

    // ============================================
    // Paused State Tests - emergencyWithdraw() Works
    // ============================================

    function test_Paused_EmergencyWithdrawWorksWhenPaused() public {
        boringVault = _deployStandardBoringVault();

        // Deposit tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Pause vault
        vm.prank(owner);
        boringVault.pause();

        // Emergency withdraw should work even when paused
        vm.prank(owner);
        boringVault.emergencyWithdraw();

        // Verify all tokens withdrawn
        assertEq(boringVault.getBalance(address(weth)), 0);
        assertEq(weth.balanceOf(kingVault), 1000e18); // All tokens returned
    }

    function test_Paused_EmergencyWithdrawWorksWhenNotPaused() public {
        boringVault = _deployStandardBoringVault();

        // Deposit tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Emergency withdraw should work when not paused
        vm.prank(owner);
        boringVault.emergencyWithdraw();

        assertEq(boringVault.getBalance(address(weth)), 0);
    }

    function test_Paused_EmergencyWithdrawEmitsEvent() public {
        boringVault = _deployStandardBoringVault();

        // Deposit tokens
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        weth.mint(kingVault, 1000e18);
        vm.prank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);

        // Pause vault
        vm.prank(owner);
        boringVault.pause();

        // Expect EmergencyWithdraw event
        vm.expectEmit(false, false, false, false);
        emit EmergencyWithdraw(tokens, amounts, block.timestamp);

        vm.prank(owner);
        boringVault.emergencyWithdraw();
    }

    // ============================================
    // Owner-only Functions When Paused
    // ============================================

    function test_Paused_OwnerFunctionsRevertWhenPaused() public {
        boringVault = _deployStandardBoringVault();

        vm.prank(owner);
        boringVault.pause();

        // Owner functions should revert when paused
        vm.prank(owner);
        vm.expectRevert();
        boringVault.setMaxSlippage(100);
    }

    function test_Paused_DepositToVaultRevertsWhenPaused() public {
        boringVault = _deployStandardBoringVault();

        // Deposit some funds first
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

        // depositToVault should revert when paused
        vm.prank(owner);
        vm.expectRevert();
        boringVault.depositToVault(address(weth), 100e18);
    }

    function test_Paused_WithdrawFromVaultRevertsWhenPaused() public {
        boringVault = _deployStandardBoringVault();

        // Pause
        vm.prank(owner);
        boringVault.pause();

        // withdrawFromVault should revert when paused
        vm.prank(owner);
        vm.expectRevert();
        boringVault.withdrawFromVault(address(weth), 100e18, 0);
    }
}

// ============================================
// Mock Contracts
// ============================================

/**
 * @notice Mock Teller contract for testing
 */
contract MockTeller {
    address public vault;
    bool public paused;

    constructor(address _vault) {
        vault = _vault;
    }

    function deposit(MockERC20 depositAsset, uint256 depositAmount, uint256 minimumMint)
        external
        returns (uint256 shares)
    {
        require(!paused, "Teller paused");

        // Transfer assets from caller to vault
        depositAsset.transferFrom(msg.sender, vault, depositAmount);

        // Mint shares to caller (simplified: 1:1 ratio for testing)
        shares = depositAmount >= minimumMint ? depositAmount : minimumMint;
        MockERC20(vault).mint(msg.sender, shares);

        return shares;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }
}

/**
 * @notice Mock Accountant contract for testing
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

    function updateAtomicRequest(MockERC20 offer, MockERC20 want, AtomicRequest calldata request) external {
        requests[msg.sender][address(offer)][address(want)] = request;
    }

    function getUserAtomicRequest(address user, MockERC20 offer, MockERC20 want)
        external
        view
        returns (AtomicRequest memory)
    {
        return requests[user][address(offer)][address(want)];
    }
}
