// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IKingVault
 * @notice Interface for King Protocol vault implementations
 * @dev Provides standardized interface for all vault types (BoringVault, TokenizedVault, etc.)
 */
interface IKingVault {
    // ============================================
    // Events
    // ============================================

    /**
     * @notice Emitted when King's core vault deposits tokens to this vault
     * @param tokens Array of token addresses deposited
     * @param amounts Array of amounts deposited (matching tokens array)
     * @param timestamp Block timestamp of deposit
     */
    event Deposited(address[] tokens, uint256[] amounts, uint256 timestamp);

    /**
     * @notice Emitted when King's core vault withdraws tokens from this vault
     * @param tokens Array of token addresses withdrawn
     * @param amounts Array of amounts withdrawn (matching tokens array)
     * @param receiver Address receiving the withdrawn tokens
     * @param timestamp Block timestamp of withdrawal
     */
    event Withdrawn(address[] tokens, uint256[] amounts, address receiver, uint256 timestamp);

    /**
     * @notice Emitted when emergency withdrawal is executed
     * @param tokens Array of token addresses withdrawn
     * @param amounts Array of amounts withdrawn (matching tokens array)
     * @param timestamp Block timestamp of emergency withdrawal
     */
    event EmergencyWithdraw(address[] tokens, uint256[] amounts, uint256 timestamp);

    /**
     * @notice Emitted when vault harvests profits from underlying protocols
     * @param timestamp Block timestamp of harvest
     */
    event ProfitsHarvested(uint256 timestamp);

    /**
     * @notice Emitted when profits are distributed to recipients
     * @param recipients Array of recipient addresses
     * @param tokens Array of token addresses distributed
     * @param amounts 2D array of amounts distributed [recipient][token]
     * @param timestamp Block timestamp of distribution
     */
    event ProfitsDistributed(
        address[] recipients,
        address[] tokens,
        uint256[][] amounts,
        uint256 timestamp
    );

    /**
     * @notice Emitted when profit distribution percentages are updated
     * @param recipient Address of the recipient
     * @param percentBPS Percentage in basis points (10000 = 100%)
     * @param timestamp Block timestamp of update
     */
    event ProfitsDistributionUpdated(
        address indexed recipient,
        uint16 percentBPS,
        uint256 timestamp
    );

    // NOTE: Paused and Unpaused events are not declared here because they are already
    // defined in PausableUpgradeable from OpenZeppelin

    /**
     * @notice Emitted when a token is added to accepted tokens
     * @param token Address of the token added
     */
    event TokenAdded(address token);

    /**
     * @notice Emitted when a token is removed from accepted tokens
     * @param token Address of the token removed
     */
    event TokenRemoved(address token);

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
     * @notice Thrown when a token is not accepted by this vault
     * @param token Address of the token that is not accepted
     */
    error TokenNotAccepted(address token);

    /**
     * @notice Thrown when vault has insufficient balance for withdrawal
     * @param token Address of the token
     * @param requested Amount requested for withdrawal
     * @param available Amount available in vault
     */
    error InsufficientBalance(address token, uint256 requested, uint256 available);

    /**
     * @notice Thrown when token array is invalid (empty or mismatched lengths)
     */
    error InvalidTokenArray();

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

    // ============================================
    // Core Functions
    // ============================================

    /**
     * @notice Deposit tokens from King's core vault to this vault
     * @dev Only callable by King's core vault address
     * @dev Requires vault to not be paused
     * @param _tokens Array of token addresses to deposit
     * @param _amounts Array of amounts to deposit (must match tokens length)
     */
    function deposit(address[] memory _tokens, uint256[] memory _amounts) external;

    /**
     * @notice Withdraw idle tokens from this vault to receiver
     * @dev Only callable by King's core vault address
     * @dev Requires vault to not be paused
     * @param _tokens Array of token addresses to withdraw
     * @param _amounts Array of amounts to withdraw (must match tokens length)
     * @param _receiver Address to receive the withdrawn tokens
     */
    function withdraw(
        address[] memory _tokens,
        uint256[] memory _amounts,
        address _receiver
    ) external;

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
     * @notice Registers asset tokens (ERC-20)
     * @dev Only callable by owner
     * @param _tokens Array of token addresses to register
     * @param _accepted Array of acceptance status (true = accepted, false = not accepted)
     */
    function registerAssets(address[] memory _tokens, bool[] memory _accepted) external;

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
     * @return Array of accepted token addresses (filters _assets where _registeredTokens[token] == true)
     */
    function assets() external view returns (address[] memory);

    // NOTE: The following view functions are not declared here because they are already
    // provided by parent contracts or public state variables:
    // - kingVault() - public state variable in KingVaultStorage
    // - priceProvider() - public state variable in KingVaultStorage
    // - owner() - provided by Ownable2StepUpgradeable
    // - paused() - provided by PausableUpgradeable
}
