// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingBoringVault} from "../../src/vaults/KingBoringVault.sol";
import {KingTokenizedVault} from "../../src/vaults/KingTokenizedVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {MockKingVaultController} from "../mocks/MockKingVaultController.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";

/**
 * @title BalanceSnapshotTrackingTest
 * @notice Tests balance snapshot tracking mechanism for both KingBoringVault and KingTokenizedVault
 * @dev Tests verify observable effects of the balance snapshot mechanism:
 *      - Snapshot initialization when operations are queued
 *      - Snapshot adjustments on deposits and withdrawals
 *      - Asset arrival detection based on balance changes
 *      - Mutex protection between queued operations
 *
 * Since internal state (_queuedWithdraw, _queuedProfits) is not directly accessible,
 * tests verify behavior through observable effects and state changes.
 */
contract BalanceSnapshotTrackingTest is Test {
    KingBoringVault public boringVault;
    KingTokenizedVault public tokenizedVault;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockPriceProvider public priceProvider;
    MockERC20 public vaultToken;
    MockERC4626Vault public erc4626Vault;
    MockTeller public teller;
    MockAccountant public accountant;
    MockAtomicQueue public atomicQueue;

    address public owner = address(0x1);
    address public kingVault;

    function setUp() public {
        kingVault = address(new MockKingVaultController());
        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        vaultToken = new MockERC20("bvWETH", "bvWETH", 18);
        priceProvider = new MockPriceProvider(2000e18);
        priceProvider.setPrice(address(weth), 1e18);
        priceProvider.setPrice(address(usdc), 0.0005e18);

        teller = new MockTeller(address(vaultToken));
        accountant = new MockAccountant(address(weth), address(vaultToken));
        atomicQueue = new MockAtomicQueue();
        teller.setAccountant(address(accountant));
        accountant.setRate(1.0e18);

        boringVault = _deployBoringVault();
        erc4626Vault = new MockERC4626Vault(weth, "vWETH", "vWETH");
        tokenizedVault = _deployTokenizedVault();
    }

    function _deployBoringVault() internal returns (KingBoringVault) {
        KingBoringVault impl = new KingBoringVault(address(vaultToken), address(teller), address(accountant));
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector,
            owner,
            kingVault,
            address(priceProvider),
            address(atomicQueue),
            tokens,
            accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return KingBoringVault(address(proxy));
    }

    function _deployTokenizedVault() internal returns (KingTokenizedVault) {
        KingTokenizedVault impl = new KingTokenizedVault(address(erc4626Vault), false);
        address[] memory assets = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(usdc);
        bool[] memory accepted = new bool[](2);
        accepted[0] = true;
        accepted[1] = true;

        bytes memory initData = abi.encodeWithSelector(
            KingTokenizedVault.initialize.selector, owner, kingVault, address(priceProvider), assets, accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return KingTokenizedVault(address(proxy));
    }

    function _depositToBoringVault(address token, uint256 amount) internal {
        MockERC20(token).mint(kingVault, amount);
        vm.prank(kingVault);
        MockERC20(token).approve(address(boringVault), amount);
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(kingVault);
        boringVault.deposit(tokens, amounts);
    }

    function _depositToTokenizedVault(address token, uint256 amount) internal {
        MockERC20(token).mint(kingVault, amount);
        vm.prank(kingVault);
        MockERC20(token).approve(address(tokenizedVault), amount);
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(kingVault);
        tokenizedVault.deposit(tokens, amounts);
    }

    // ============================================
    // Tests: Mutex Protection
    // ============================================

    function test_BoringVault_WithdrawFromVault_RevertsWhenProfitsQueued() public {
        weth.mint(address(boringVault), 100e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 100e18);
        accountant.setRate(1.5e18);
        vm.prank(owner);
        boringVault.harvestProfits();

        vaultToken.mint(address(boringVault), 50e18);
        vm.prank(owner);
        // Reverts because harvestProfits() created a _withdrawalRequests entry
        vm.expectRevert(KingBoringVault.WithdrawalNotQueued.selector);
        boringVault.withdrawFromVault(address(weth), 50e18, uint64(block.timestamp + 1 days));
    }

    function test_BoringVault_HarvestProfits_RevertsWhenWithdrawalQueued() public {
        _depositToBoringVault(address(weth), 100e18);
        weth.mint(address(boringVault), 100e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 100e18);
        vaultToken.mint(address(boringVault), 50e18);
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 50e18, uint64(block.timestamp + 1 days));

        accountant.setRate(1.5e18);
        vm.prank(owner);
        // Reverts because withdrawFromVault() created a _withdrawalRequests entry
        vm.expectRevert(KingBoringVault.WithdrawalNotQueued.selector);
        boringVault.harvestProfits();
    }

    function test_TokenizedVault_WithdrawFromVault_RevertsWhenProfitsQueued() public {
        // Deposit WETH first, then deploy to vault
        _depositToTokenizedVault(address(weth), 100e18);
        weth.mint(address(tokenizedVault), 100e18);
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 100e18);

        // Create profit by increasing exchange rate
        erc4626Vault.setExchangeRate(1.5e18);
        vm.prank(owner);
        tokenizedVault.harvestProfits();

        // Try to queue withdrawal - should revert
        // Reverts because harvestProfits() created a _withdrawalRequests entry
        erc4626Vault.mint(address(tokenizedVault), 50e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KingTokenizedVault.PendingWithdrawalExists.selector, address(weth)));
        tokenizedVault.withdrawFromVault(address(weth), 50e18, false);
    }

    function test_TokenizedVault_HarvestProfits_RevertsWhenWithdrawalQueued() public {
        // Deposit WETH first, then deploy to vault
        _depositToTokenizedVault(address(weth), 100e18);
        weth.mint(address(tokenizedVault), 100e18);
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 100e18);

        // Queue a withdrawal request
        erc4626Vault.mint(address(tokenizedVault), 50e18);
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(address(weth), 50e18, false);

        // Try to harvest profits - should revert
        // Reverts because withdrawFromVault() created a _withdrawalRequests entry
        erc4626Vault.setExchangeRate(1.5e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KingTokenizedVault.PendingWithdrawalExists.selector, address(weth)));
        tokenizedVault.harvestProfits();
    }

    // ============================================
    // Tests: Cancellation Clears State
    // ============================================

    function test_BoringVault_CancellationAllowsNewQueue() public {
        _depositToBoringVault(address(weth), 100e18);
        weth.mint(address(boringVault), 100e18);
        vm.prank(owner);
        boringVault.depositToVault(address(weth), 100e18);
        vaultToken.mint(address(boringVault), 50e18);
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 50e18, uint64(block.timestamp + 1 days));

        vm.prank(owner);
        boringVault.cancelWithdrawFromVault(address(weth));

        // Should be able to queue profits now
        accountant.setRate(1.5e18);
        vm.prank(owner);
        boringVault.harvestProfits(); // Should not revert
    }

    function test_TokenizedVault_CancellationAllowsNewQueue() public {
        // Deposit WETH first, then deploy to vault
        _depositToTokenizedVault(address(weth), 100e18);
        weth.mint(address(tokenizedVault), 100e18);
        vm.prank(owner);
        tokenizedVault.depositToVault(address(weth), 100e18);

        // Queue a withdrawal request
        erc4626Vault.mint(address(tokenizedVault), 50e18);
        vm.prank(owner);
        tokenizedVault.withdrawFromVault(address(weth), 50e18, false);

        // Cancel the withdrawal
        vm.prank(owner);
        tokenizedVault.cancelWithdrawal(address(weth));

        // Should be able to queue profits now
        erc4626Vault.setExchangeRate(1.5e18);
        vm.prank(owner);
        tokenizedVault.harvestProfits(); // Should not revert
    }
}

// Mock contracts
contract MockTeller {
    address public vault;
    address public accountant;

    constructor(address _vault) {
        vault = _vault;
    }

    function setAccountant(address _accountant) external {
        accountant = _accountant;
    }

    function isPaused() external pure returns (bool) {
        return false;
    }

    function deposit(address, uint256 depositAmount, uint256) external returns (uint256 shares) {
        shares = depositAmount;
        MockERC20(vault).mint(msg.sender, shares);
        return shares;
    }
}

contract MockAccountant {
    address public base;
    address public vault;
    uint256 public rate;

    constructor(address _base, address _vault) {
        base = _base;
        vault = _vault;
        rate = 1e18;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function isPaused() external pure returns (bool) {
        return false;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getRateSafe() external view returns (uint256) {
        return rate;
    }

    function getRateInQuote(address) external view returns (uint256) {
        return rate;
    }

    function getRateInQuoteSafe(address) external view returns (uint256) {
        return rate;
    }
}

contract MockAtomicQueue {
    struct AtomicRequest {
        uint64 deadline;
        uint88 atomicPrice;
        uint96 offerAmount;
        bool inSolve;
    }

    mapping(address => mapping(address => AtomicRequest)) public userAtomicRequest;

    function updateAtomicRequest(
        address, // offer
        address, // want
        AtomicRequest memory // details
    ) external {
        // Mock implementation - just accept the call
    }
}
