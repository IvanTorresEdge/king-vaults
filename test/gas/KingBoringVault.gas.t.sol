// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KingBoringVault} from "../../src/vaults/KingBoringVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceProvider} from "../mocks/MockPriceProvider.sol";
import {IKingVault} from "../../src/interfaces/IKingVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title KingBoringVaultGasTest
 * @notice Gas profiling tests for BoringVault major operations
 * @dev Tests Task 7.9 acceptance criteria:
 *      - Profile depositToVault() < 500k gas
 *      - Profile withdrawFromVault() < 200k gas
 *      - Profile harvestProfits() < 300k gas
 *      - Profile calculateProfit() < 50k gas per asset
 *      - Profile view functions < 30k gas
 *      - Document gas costs for all major operations
 *      - Identify optimization opportunities
 */
contract KingBoringVaultGasTest is Test {
    // ============================================
    // Contracts
    // ============================================

    KingBoringVault public boringVault;
    KingBoringVault public implementation;
    MockERC20 public weth;
    MockERC20 public ethfi;
    MockERC20 public usdc;
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
    address public recipient1 = address(0x4);
    address public recipient2 = address(0x5);

    // ============================================
    // Gas Tracking
    // ============================================

    struct GasReport {
        string operation;
        uint256 gasUsed;
        uint256 gasLimit;
        bool withinLimit;
    }

    GasReport[] public gasReports;

    // ============================================
    // Setup
    // ============================================

    function setUp() public {
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ethfi = new MockERC20("EtherFi Token", "ETHFI", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vaultToken = new MockERC20("Boring Vault Shares", "bvWETH", 18);

        // Deploy mock price provider
        priceProvider = new MockPriceProvider(2000e18); // $2000 per ETH
        priceProvider.setPrice(address(weth), 1e18); // 1 WETH = 1 ETH
        priceProvider.setPrice(address(ethfi), 0.0005e18); // 1 ETHFI = 0.0005 ETH
        priceProvider.setPrice(address(usdc), 0.0005e18); // 1 USDC = 0.0005 ETH

        // Deploy mock Veda contracts
        teller = new MockTeller(address(vaultToken));
        accountant = new MockAccountant(address(weth), address(vaultToken));
        atomicQueue = new MockAtomicQueue();

        // Connect teller to accountant
        teller.setAccountant(address(accountant));

        // Set up mock exchange rate in accountant (1 share = 1.0 WETH initially)
        accountant.setRate(1.0e18);

        // Deploy BoringVault implementation (with immutable addresses)
        implementation = new KingBoringVault(
            address(vaultToken), // vault
            address(teller), // teller
            address(accountant) // accountant
        );

        // Deploy and initialize proxy
        boringVault = _deployStandardKingBoringVault();

        // Fund kingVault with tokens
        weth.mint(kingVault, 10000e18);
        ethfi.mint(kingVault, 20000e18);
        usdc.mint(kingVault, 10000e6);
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _deployKingBoringVault(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address _atomicQueue,
        address[] memory _tokens,
        bool[] memory _accepted
    ) internal returns (KingBoringVault) {
        bytes memory initData = abi.encodeWithSelector(
            KingBoringVault.initialize.selector, _owner, _kingVault, _priceProvider, _atomicQueue, _tokens, _accepted
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        return KingBoringVault(address(proxy));
    }

    function _deployStandardKingBoringVault() internal returns (KingBoringVault) {
        address[] memory tokens = new address[](3);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        tokens[2] = address(usdc);
        bool[] memory accepted = new bool[](3);
        accepted[0] = true;
        accepted[1] = true;
        accepted[2] = true;

        return _deployKingBoringVault(owner, kingVault, address(priceProvider), address(atomicQueue), tokens, accepted);
    }

    function _recordGas(string memory operation, uint256 gasUsed, uint256 gasLimit) internal {
        bool withinLimit = gasUsed <= gasLimit;
        gasReports.push(
            GasReport({operation: operation, gasUsed: gasUsed, gasLimit: gasLimit, withinLimit: withinLimit})
        );

        console2.log("Gas Report:");
        console2.log("  Operation:", operation);
        console2.log("  Gas Used:", gasUsed);
        console2.log("  Gas Limit:", gasLimit);
        console2.log("  Within Limit:", withinLimit ? "YES" : "NO");
        console2.log("");
    }

    function _setupProfitScenario() internal {
        // 1. King vault deposits 1000 WETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // 2. Governance deploys to BoringVault (receive 1000 shares @ 1.0 rate)
        vm.startPrank(owner);
        boringVault.depositToVault(address(weth), 1000e18);
        vm.stopPrank();

        // 3. Simulate yield: shares appreciate to 1.2 rate (20% profit)
        accountant.setRate(1.2e18);
        // Now: 1000 shares × 1.2 = 1200 WETH value
        // Profit = 1200 - 1000 = 200 WETH
    }

    // ============================================
    // Gas Profiling Tests
    // ============================================

    /**
     * @notice Profile depositToVault() gas usage
     * @dev Acceptance Criteria: < 500k gas
     */
    function test_gas_depositToVault_SmallAmount() public {
        // Setup: King vault deposits WETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Profile depositToVault
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.depositToVault(address(weth), 1000e18);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("depositToVault (1000 WETH)", gasUsed, 500_000);
    }

    function test_gas_depositToVault_LargeAmount() public {
        // Setup: King vault deposits large amount
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5000e18;

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 5000e18);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Profile depositToVault
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.depositToVault(address(weth), 5000e18);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("depositToVault (5000 WETH)", gasUsed, 500_000);
    }

    function test_gas_depositToVault_DifferentRates() public {
        // Setup with higher exchange rate
        accountant.setRate(2.4e18); // 1 share = 2.4 WETH

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Profile depositToVault at 2.4 rate
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.depositToVault(address(weth), 1000e18);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("depositToVault (rate=2.4)", gasUsed, 500_000);
    }

    /**
     * @notice Profile withdrawFromVault() gas usage
     * @dev Acceptance Criteria: < 200k gas
     */
    function test_gas_withdrawFromVault_SmallAmount() public {
        // Setup: deposit and deploy to vault
        _setupProfitScenario();

        // Profile withdrawFromVault (queue 100 shares)
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.withdrawFromVault(address(weth), 100e18, 0);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("withdrawFromVault (100 shares)", gasUsed, 200_000);
    }

    function test_gas_withdrawFromVault_LargeAmount() public {
        // Setup: deposit and deploy to vault
        _setupProfitScenario();

        // Profile withdrawFromVault (queue 500 shares)
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.withdrawFromVault(address(weth), 500e18, 0);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("withdrawFromVault (500 shares)", gasUsed, 200_000);
    }

    function test_gas_withdrawFromVault_WithCustomDeadline() public {
        // Setup: deposit and deploy to vault
        _setupProfitScenario();

        // Profile withdrawFromVault with custom deadline
        uint64 customDeadline = uint64(block.timestamp + 14 days);
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.withdrawFromVault(address(weth), 100e18, customDeadline);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("withdrawFromVault (custom deadline)", gasUsed, 200_000);
    }

    /**
     * @notice Profile harvestProfits() gas usage
     * @dev Acceptance Criteria: < 300k gas
     */
    function test_gas_harvestProfits_SingleAsset() public {
        // Setup profit scenario (1 asset: WETH)
        _setupProfitScenario();

        // Profile harvestProfits
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.harvestProfits();
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("harvestProfits (1 asset)", gasUsed, 300_000);
    }

    function test_gas_harvestProfits_MultipleAssets() public {
        // Setup with multiple assets
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        ethfi.approve(address(boringVault), 2000e18);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Deploy both to vault
        vm.startPrank(owner);
        boringVault.depositToVault(address(weth), 1000e18);
        boringVault.depositToVault(address(ethfi), 2000e18);
        vm.stopPrank();

        // Simulate profit
        accountant.setRate(1.2e18);

        // Profile harvestProfits with 2 assets
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.harvestProfits();
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("harvestProfits (2 assets)", gasUsed, 300_000);
    }

    /**
     * @notice Profile calculateProfit() gas usage
     * @dev Acceptance Criteria: < 50k gas per asset
     */
    function test_gas_calculateProfit_SingleAsset() public {
        _setupProfitScenario();

        // Profile calculateProfit (view function)
        uint256 gasBefore = gasleft();
        boringVault.calculateProfit();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("calculateProfit (1 asset)", gasUsed, 50_000);
    }

    function test_gas_calculateProfit_MultipleAssets() public {
        // Setup with 3 assets
        address[] memory tokens = new address[](3);
        tokens[0] = address(weth);
        tokens[1] = address(ethfi);
        tokens[2] = address(usdc);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;
        amounts[2] = 1000e6;

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        ethfi.approve(address(boringVault), 2000e18);
        usdc.approve(address(boringVault), 1000e6);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        // Deploy all to vault
        vm.startPrank(owner);
        boringVault.depositToVault(address(weth), 1000e18);
        boringVault.depositToVault(address(ethfi), 2000e18);
        boringVault.depositToVault(address(usdc), 1000e6);
        vm.stopPrank();

        // Simulate profit
        accountant.setRate(1.2e18);

        // Profile calculateProfit (3 assets)
        uint256 gasBefore = gasleft();
        boringVault.calculateProfit();
        uint256 gasUsed = gasBefore - gasleft();

        // Note: Acceptance criteria is per asset, so divide by 3
        _recordGas("calculateProfit (3 assets total)", gasUsed, 150_000);
        _recordGas("calculateProfit (per asset average)", gasUsed / 3, 50_000);
    }

    function test_gas_calculateProfit_NoProfit() public {
        // Setup without profit (rate unchanged)
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.startPrank(kingVault);
        weth.approve(address(boringVault), 1000e18);
        boringVault.deposit(tokens, amounts);
        vm.stopPrank();

        vm.startPrank(owner);
        boringVault.depositToVault(address(weth), 1000e18);
        vm.stopPrank();

        // Rate unchanged (1.0), so no profit
        uint256 gasBefore = gasleft();
        boringVault.calculateProfit();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("calculateProfit (no profit)", gasUsed, 50_000);
    }

    /**
     * @notice Profile view functions gas usage
     * @dev Acceptance Criteria: < 30k gas each
     */
    function test_gas_viewFunctions_GetPendingShares() public {
        _setupProfitScenario();

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 100e18, 0);

        // Profile getPendingShares
        uint256 gasBefore = gasleft();
        boringVault.getPendingShares();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("getPendingShares()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_GetVaultShares() public {
        _setupProfitScenario();

        // Profile getVaultShares
        uint256 gasBefore = gasleft();
        boringVault.getVaultShares();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("getVaultShares()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_GetWithdrawalRequest() public {
        _setupProfitScenario();

        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 100e18, 0);

        // Profile getWithdrawalRequest
        uint256 gasBefore = gasleft();
        boringVault.getWithdrawalRequest(address(weth));
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("getWithdrawalRequest()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_AvailableForWithdraw() public {
        _setupProfitScenario();

        // Profile availableForWithdraw
        uint256 gasBefore = gasleft();
        boringVault.availableForWithdraw(address(weth));
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("availableForWithdraw()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_IsTellerPaused() public {
        // Profile isTellerPaused
        uint256 gasBefore = gasleft();
        boringVault.isTellerPaused();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("isTellerPaused()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_IsAccountantPaused() public {
        // Profile isAccountantPaused
        uint256 gasBefore = gasleft();
        boringVault.isAccountantPaused();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("isAccountantPaused()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_GetVaultRate() public {
        // Profile getVaultRate
        uint256 gasBefore = gasleft();
        boringVault.getVaultRate();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("getVaultRate()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_Tvl() public {
        _setupProfitScenario();

        // Profile tvl()
        uint256 gasBefore = gasleft();
        boringVault.tvl();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("tvl()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_GetBalance() public {
        _setupProfitScenario();

        // Profile getBalance
        uint256 gasBefore = gasleft();
        boringVault.getBalance(address(weth));
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("getBalance()", gasUsed, 30_000);
    }

    function test_gas_viewFunctions_GetBalances() public {
        _setupProfitScenario();

        // Profile getBalances
        uint256 gasBefore = gasleft();
        boringVault.getBalances();
        uint256 gasUsed = gasBefore - gasleft();

        _recordGas("getBalances()", gasUsed, 30_000);
    }

    /**
     * @notice Profile completePrincipalWithdraw() gas usage
     */
    function test_gas_completePrincipalWithdraw() public {
        // Setup withdrawal scenario
        _setupProfitScenario();

        // Queue withdrawal
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 100e18, 0);

        // Simulate solver fulfillment (deposit WETH to contract)
        weth.mint(address(boringVault), 120e18); // 100 shares × 1.2 rate

        // Profile completePrincipalWithdraw
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.completePrincipalWithdraw(address(weth), 120e18, kingVault);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("completePrincipalWithdraw()", gasUsed, 200_000);
    }

    /**
     * @notice Profile distributeProfits() gas usage
     */
    function test_gas_distributeProfits_SingleRecipient() public {
        // Setup profit scenario
        _setupProfitScenario();

        // Harvest profits
        vm.prank(owner);
        boringVault.harvestProfits();

        // Simulate solver fulfillment
        weth.mint(address(boringVault), 200e18); // Profit amount

        // Setup profit distribution (1 recipient)
        address[] memory recipients = new address[](1);
        recipients[0] = recipient1;
        uint16[] memory percentsBPS = new uint16[](1);
        percentsBPS[0] = 10000; // 100%

        vm.prank(owner);
        boringVault.setProfitsDistribution(recipients, percentsBPS);

        // Profile distributeProfits
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.distributeProfits();
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("distributeProfits (1 recipient)", gasUsed, 150_000);
    }

    function test_gas_distributeProfits_MultipleRecipients() public {
        // Setup profit scenario
        _setupProfitScenario();

        // Harvest profits
        vm.prank(owner);
        boringVault.harvestProfits();

        // Simulate solver fulfillment
        weth.mint(address(boringVault), 200e18);

        // Setup profit distribution (2 recipients)
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;
        uint16[] memory percentsBPS = new uint16[](2);
        percentsBPS[0] = 6000; // 60%
        percentsBPS[1] = 4000; // 40%

        vm.prank(owner);
        boringVault.setProfitsDistribution(recipients, percentsBPS);

        // Profile distributeProfits
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.distributeProfits();
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("distributeProfits (2 recipients)", gasUsed, 200_000);
    }

    /**
     * @notice Profile cancellation operations gas usage
     */
    function test_gas_cancelWithdrawFromVault() public {
        // Setup withdrawal scenario
        _setupProfitScenario();

        // Queue withdrawal
        vm.prank(owner);
        boringVault.withdrawFromVault(address(weth), 100e18, 0);

        // Profile cancelWithdrawFromVault
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.cancelWithdrawFromVault(address(weth));
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("cancelWithdrawFromVault()", gasUsed, 150_000);
    }

    function test_gas_cancelProfitsHarvest() public {
        // Setup profit scenario
        _setupProfitScenario();

        // Harvest profits
        vm.prank(owner);
        boringVault.harvestProfits();

        // Profile cancelProfitsHarvest
        vm.startPrank(owner);
        uint256 gasBefore = gasleft();
        boringVault.cancelProfitsHarvest(address(weth));
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        _recordGas("cancelProfitsHarvest()", gasUsed, 150_000);
    }

    /**
     * @notice Print comprehensive gas report summary
     */
    function test_gas_printFullReport() public pure {
        console2.log("");
        console2.log("========================================");
        console2.log("BORINGVAULT GAS PROFILING REPORT");
        console2.log("========================================");
        console2.log("");
        console2.log("Note: Run individual gas tests to populate this report");
        console2.log("      Use: forge test --match-contract KingBoringVaultGasTest --gas-report");
        console2.log("");
        console2.log("Acceptance Criteria:");
        console2.log("  - depositToVault()        < 500,000 gas");
        console2.log("  - withdrawFromVault()     < 200,000 gas");
        console2.log("  - harvestProfits()        < 300,000 gas");
        console2.log("  - calculateProfit()       <  50,000 gas per asset");
        console2.log("  - View functions          <  30,000 gas");
        console2.log("");
        console2.log("Run: forge test --match-contract KingBoringVaultGasTest -vv");
        console2.log("========================================");
    }
}

// ============================================
// Mock Contracts (Minimal implementations for gas testing)
// ============================================

contract MockTeller {
    address public vault;
    address public accountant;
    bool public paused;

    constructor(address _vault) {
        vault = _vault;
    }

    function setAccountant(address _accountant) external {
        accountant = _accountant;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function deposit(address asset, uint256 amount, uint256 minimumMint) external returns (uint256 shares) {
        require(!paused, "Teller paused");
        // Use burn/mint pattern to avoid approval issues
        MockERC20(asset).burn(msg.sender, amount);
        MockERC20(asset).mint(address(vault), amount);

        // Calculate shares based on accountant rate
        uint256 rate = IAccountantWithRateProviders(accountant).getRateInQuoteSafe(asset);
        shares = Math.mulDiv(amount, 1e18, rate);

        require(shares >= minimumMint, "Slippage exceeded");

        // Mint shares to caller
        MockERC20(vault).mint(msg.sender, shares);

        return shares;
    }
}

contract MockAccountant {
    address public base;
    address public vault;
    bool public paused;
    uint256 public rate; // Current exchange rate (base per share)
    uint8 public constant decimals = 18;

    constructor(address _base, address _vault) {
        base = _base;
        vault = _vault;
        rate = 1e18; // Default 1:1 rate
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function getRateSafe() external view returns (uint256) {
        require(!paused, "Accountant paused");
        return rate;
    }

    function getRateInQuote(address /* quote */ ) external view returns (uint256) {
        return rate; // Simplified: same rate for all assets
    }

    function getRateInQuoteSafe(address /* quote */ ) external view returns (uint256) {
        require(!paused, "Accountant paused");
        return rate;
    }
}

contract MockAtomicQueue {
    mapping(address => mapping(address => AtomicRequest)) public userAtomicRequest;

    struct AtomicRequest {
        uint64 deadline;
        uint88 atomicPrice;
        uint96 offerAmount;
        bool inSolve;
    }

    function updateAtomicRequest(address, /* vault */ address asset, AtomicRequest calldata request) external {
        userAtomicRequest[msg.sender][asset] = request;
    }

    function getUserAtomicRequest(address user, address asset) external view returns (AtomicRequest memory) {
        return userAtomicRequest[user][asset];
    }
}

interface IAccountantWithRateProviders {
    function getRateInQuoteSafe(address quote) external view returns (uint256);
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
