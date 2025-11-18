// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";

/**
 * @title IKingVault
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice Interface for King Protocol vault implementations
 * @dev Provides standardized interface for all vault types (KingBoringVault, KingTokenizedVault, etc.)
 */
interface IKingVault is IERC165 {
    // ============================================
    // Events
    // ============================================

    /**
     * @notice Emitted when King's core vault deposits assets to this vault
     * @param assets Array of asset addresses deposited
     * @param amounts Array of amounts deposited (matching assets array)
     * @param timestamp Block timestamp of deposit
     */
    event Deposited(address[] assets, uint256[] amounts, uint256 timestamp);

    /**
     * @notice Emitted when King's core vault withdraws assets from this vault
     * @param assets Array of asset addresses withdrawn
     * @param amounts Array of amounts withdrawn (matching assets array)
     * @param receiver Address receiving the withdrawn assets
     * @param timestamp Block timestamp of withdrawal
     */
    event Withdrawn(address[] assets, uint256[] amounts, address receiver, uint256 timestamp);

    /**
     * @notice Emitted when emergency withdrawal is executed
     * @param assets Array of asset addresses withdrawn
     * @param amounts Array of amounts withdrawn (matching assets array)
     * @param timestamp Block timestamp of emergency withdrawal
     */
    event EmergencyWithdraw(address[] assets, uint256[] amounts, uint256 timestamp);

    /**
     * @notice Emitted when vault harvests profits from underlying protocols
     * @param timestamp Block timestamp of harvest
     */
    event ProfitsHarvested(uint256 timestamp);

    /**
     * @notice Emitted when profits are distributed to recipients
     * @param recipients Array of recipient addresses
     * @param assets Array of asset addresses distributed
     * @param amounts 2D array of amounts distributed [recipient][asset]
     * @param timestamp Block timestamp of distribution
     */
    event ProfitsDistributed(address[] recipients, address[] assets, uint256[][] amounts, uint256 timestamp);

    /**
     * @notice Emitted when profit distribution percentages are updated
     * @dev Does not reveal recipients or percentages for privacy
     * @param timestamp Block timestamp of update
     */
    event ProfitsDistributionUpdated(uint256 timestamp);

    // NOTE: Paused and Unpaused events are not declared here because they are already
    // defined in PausableUpgradeable from OpenZeppelin

    /**
     * @notice Emitted when an asset is added to accepted assets
     * @param asset Address of the asset added
     */
    event AssetAdded(address asset);

    /**
     * @notice Emitted when an asset is removed from accepted assets
     * @param asset Address of the asset removed
     */
    event AssetRemoved(address asset);

    /**
     * @notice Emitted when price provider is updated
     * @param oldPriceProvider Previous price provider address
     * @param newPriceProvider New price provider address
     */
    event PriceProviderUpdated(address oldPriceProvider, address newPriceProvider);

    // ============================================
    // Custom Errors
    // ============================================

    /**
     * @notice Thrown when caller is not King's core vault
     */
    error OnlyKingVault();

    /**
     * @notice Thrown when caller is not the owner or King's core vault
     */
    error OnlyOwnerOrKingVault();

    /**
     * @notice Thrown when operation requires contract to be paused but it's not
     */
    error WhenPaused();

    /**
     * @notice Thrown when operation requires contract to not be paused but it is
     */
    error WhenNotPaused();

    /**
     * @notice Thrown when an asset is not accepted by this vault
     * @param asset Address of the asset that is not accepted
     */
    error AssetNotAccepted(address asset);

    /**
     * @notice Thrown when vault has insufficient balance for withdrawal
     * @param asset Address of the asset
     * @param requested Amount requested for withdrawal
     * @param available Amount available in vault
     */
    error InsufficientBalance(address asset, uint256 requested, uint256 available);

    /**
     * @notice Thrown when asset array is invalid (empty or mismatched lengths)
     */
    error InvalidAssetArray();

    /**
     * @notice Thrown when amount is zero
     */
    error ZeroAmount();

    /**
     * @notice Thrown when address is zero
     */
    error ZeroAddress();

    /**
     * @notice Thrown when profit distribution total does not equal 100%
     * @param actual The actual total percentage in BPS
     */
    error InvalidDistributionTotal(uint256 actual);

    /**
     * @notice Thrown when a percentage exceeds maximum allowed
     */
    error InvalidPercentage();

    /**
     * @notice Thrown when attempting to disable an asset that has active deposits
     * @param asset Address of the asset with deposits
     * @param depositAmount Amount of deposits that must be withdrawn first
     */
    error CannotDisableAssetWithDeposits(address asset, uint256 depositAmount);

    /**
     * @notice Thrown when TVL calculation encounters an asset without available price
     * @param asset Address of the asset without price data
     * @dev TVL calculation must revert rather than return partial/understated value
     */
    error PriceNotAvailable(address asset);

    // ============================================
    // Core Functions
    // ============================================

    /**
     * @notice Deposit assets from King's core vault to this vault
     * @dev Only callable by King's core vault address
     * @dev Requires vault to not be paused
     * @param _tokens Array of asset addresses to deposit
     * @param _amounts Array of amounts to deposit (must match assets length)
     */
    function deposit(address[] memory _tokens, uint256[] memory _amounts) external;

    /**
     * @notice Withdraw idle assets from this vault to receiver
     * @dev Only callable by King's core vault address
     * @dev Requires vault to not be paused
     * @param _tokens Array of asset addresses to withdraw
     * @param _amounts Array of amounts to withdraw (must match assets length)
     * @param _receiver Address to receive the withdrawn assets
     */
    function withdraw(address[] memory _tokens, uint256[] memory _amounts, address _receiver) external;

    /**
     * @notice Emergency withdrawal of all idle assets
     * @dev Callable by owner OR King's core vault
     * @dev Works even when paused
     */
    function emergencyWithdraw() external;

    /**
     * @notice Pause vault operations
     * @dev Callable by owner OR King's core vault
     * @dev Blocks deposit() and withdraw() but allows emergencyWithdraw()
     */
    function pause() external;

    /**
     * @notice Resume vault operations
     * @dev Callable by owner OR King's core vault
     */
    function unpause() external;

    /**
     * @notice Harvest profits from underlying protocols
     * @dev Only callable by owner
     * @dev Vault-specific implementation (e.g., claim from BoringVault)
     * @dev Does NOT distribute - call distributeProfits() separately
     * @dev Abstract function - must be implemented by specialized vaults
     */
    function harvestProfits() external;

    /**
     * @notice Registers assets (ERC-20)
     * @dev Only callable by owner
     * @param _tokens Array of asset addresses to register
     * @param _accepted Array of acceptance status (true = accepted, false = not accepted)
     */
    function registerAssets(address[] memory _tokens, bool[] memory _accepted) external;

    /**
     * @notice Set profit distribution percentages for recipients
     * @dev Only callable by owner (governance)
     * @dev Total of ALL recipients must equal 100% (10000 BPS)
     * @param _recipients Array of recipient addresses to update
     * @param _percentsBPS Array of percentages in basis points (10000 = 100%)
     */
    function setProfitsDistribution(address[] memory _recipients, uint16[] memory _percentsBPS) external;

    /**
     * @notice Distribute profits to configured recipients
     * @dev Only callable by owner (governance)
     * @dev Distributes profit (balance - principal) for all assets
     */
    function distributeProfits() external;

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get total value locked in this vault
     * @return ethValue Total value in ETH (18 decimals)
     * @return usdValue Total value in USD (18 decimals)
     */
    function tvl() external view returns (uint256 ethValue, uint256 usdValue);

    /**
     * @notice Get array of all registered and accepted assets
     * @return Array of accepted asset addresses (filters _assets where _registeredTokens[token] == true)
     */
    function assets() external view returns (address[] memory);

    /**
     * @notice Get balances of all registered assets
     * @dev Returns parallel arrays of assets and their balances (idle + deployed)
     * @dev Used by King Protocol core contract for:
     *      - Maximum weight validation (position limit checks)
     *      - Redemption liquidity calculations
     *      - Minting asset ratio verification
     * @dev Arrays are parallel: _assets[i] corresponds to _amounts[i]
     * @dev Balances include both idle assets in vault and assets deployed to underlying protocols
     * @dev For KingBoringVault: returns principal tracked in _deposits mapping (not share value)
     * @dev For KingTokenizedVault: may calculate differently based on internal mechanics
     * @return _assets Array of registered asset addresses
     * @return _amounts Array of corresponding balances for each asset
     *
     * @custom:example
     * ```solidity
     * (address[] memory assets, uint256[] memory amounts) = vault.getBalances();
     * // assets[0] = 0xETHFI, amounts[0] = 1000e18 (1000 ETHFI principal)
     * // assets[1] = 0xWETH, amounts[1] = 5e18 (5 WETH principal)
     * ```
     */
    function getBalances() external view returns (address[] memory _assets, uint256[] memory _amounts);

    /**
     * @notice Get balance of a specific asset
     * @dev Returns balance (idle + deployed) for the specified asset
     * @dev Convenience method for querying single asset balance
     * @dev Returns 0 if asset not registered in vault
     * @dev Used by King Protocol core contract for asset-specific balance checks
     * @dev For KingBoringVault: returns principal from _deposits[_asset]
     * @dev For KingTokenizedVault: may calculate differently based on internal mechanics
     * @param _asset Address of the asset to query
     * @return _amount Balance of the specified asset
     *
     * @custom:example
     * ```solidity
     * uint256 ethfiBalance = vault.getBalance(0xETHFI);
     * // Returns: 1000e18 (1000 ETHFI principal)
     *
     * uint256 unknownBalance = vault.getBalance(0xUnknownToken);
     * // Returns: 0 (not registered)
     * ```
     */
    function getBalance(address _asset) external view returns (uint256 _amount);

    /**
     * @notice Calculate available balance for withdrawals to main vault
     * @dev Returns idle balance minus queued operations (principal + profit withdrawals)
     * @dev Protects assets reserved for pending async withdrawal operations
     * @dev Used by withdraw() to prevent withdrawal of reserved assets
     * @param asset Asset address to check
     * @return Available amount that can be safely withdrawn to main vault
     *
     * @custom:formula available = idle - queuedPrincipal - queuedProfit
     * @custom:example
     * ```solidity
     * // Scenario: 100 WETH idle, 20 queued for principal withdrawal, 10 queued for profit
     * uint256 available = vault.availableForWithdraw(WETH);
     * // Returns: 70 WETH (100 - 20 - 10)
     * ```
     */
    function availableForWithdraw(address asset) external view returns (uint256);

    // NOTE: The following view functions are not declared here because they are already
    // provided by parent contracts or public state variables:
    // - kingVault() - public state variable in KingVaultStorage
    // - priceProvider() - public state variable in KingVaultStorage
    // - owner() - provided by Ownable2StepUpgradeable
    // - paused() - provided by PausableUpgradeable
}
