// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {KingVaultStorage} from "./KingVaultStorage.sol";
import {IKingVault} from "../interfaces/IKingVault.sol";
import {IPriceProvider} from "../interfaces/IPriceProvider.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title KingVault
 * @notice Abstract base contract for King Protocol vault implementations
 * @dev Provides common vault infrastructure for multi-token deposits, withdrawals, TVL tracking
 * @dev Specialized vaults (BoringVault, TokenizedVault) extend this contract
 */
abstract contract KingVault is KingVaultStorage, IKingVault {
    // ============================================
    // Initialization
    // ============================================

    /**
     * @notice Initialize the vault with required addresses
     * @dev Called once during proxy deployment
     * @dev Initializes parent contracts and sets core addresses
     * @param _owner Address of the owner (governance)
     * @param _kingVault Address of King's core vault (immutable after init)
     * @param _priceProvider Address of the price provider for TVL calculation
     * @param _tokens Optional array of initial assets to register
     * @param _accepted Optional array of acceptance status for initial assets
     */
    function __KingVault_init(
        address _owner,
        address _kingVault,
        address _priceProvider,
        address[] memory _tokens,
        bool[] memory _accepted
    ) internal onlyInitializing {
        // Validate core addresses
        if (_owner == address(0)) revert ZeroAddress();
        if (_kingVault == address(0)) revert ZeroAddress();
        if (_priceProvider == address(0)) revert ZeroAddress();

        // Initialize parent contracts
        __Ownable2Step_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Transfer ownership to specified owner
        _transferOwnership(_owner);

        // Set core addresses (kingVault is immutable by design - Decision 11)
        kingVault = _kingVault;
        priceProvider = _priceProvider;

        // Register initial tokens if provided
        if (_tokens.length > 0) {
            _registerAssets(_tokens, _accepted);
        }
    }

    // ============================================
    // Deposit Management
    // ============================================

    /**
     * @notice Deposit assets from King's core vault to this vault
     * @dev Only callable by King's core vault (kingVault address)
     * @dev Validates arrays, asset acceptance, and amounts before transferring
     * @param _tokens Array of asset addresses to deposit
     * @param _amounts Array of amounts to deposit (must match assets length)
     */
    function deposit(address[] memory _tokens, uint256[] memory _amounts) external override {
        // Access control: only kingVault can call
        _requireKingVault();

        // Pause check: cannot deposit when paused
        _requireNotPaused();

        // Validate arrays non-empty and matching length
        if (_tokens.length == 0 || _tokens.length != _amounts.length) {
            revert InvalidAssetArray();
        }

        // Process each token deposit
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 amount = _amounts[i];

            // Validate amount > 0
            if (amount == 0) revert ZeroAmount();

            // Validate token is accepted
            if (!_registeredTokens[token]) revert AssetNotAccepted(token);

            // Transfer tokens from kingVault to this contract
            SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);

            // Update deposits mapping (principal tracking)
            _deposits[token] += amount;
        }

        // Emit event with all tokens and amounts
        emit Deposited(_tokens, _amounts, block.timestamp);
    }

    // ============================================
    // Withdrawal Management
    // ============================================

    /**
     * @notice Withdraw idle assets from this vault to receiver
     * @dev Only callable by King's core vault (kingVault address)
     * @dev Validates arrays, amounts, and balance before transferring
     * @param _tokens Array of asset addresses to withdraw
     * @param _amounts Array of amounts to withdraw (must match assets length)
     * @param _receiver Address to receive the withdrawn assets
     */
    function withdraw(
        address[] memory _tokens,
        uint256[] memory _amounts,
        address _receiver
    ) external virtual override {
        // Access control: only kingVault can call
        _requireKingVault();

        // Pause check: cannot withdraw when paused
        _requireNotPaused();

        // Validate receiver address
        if (_receiver == address(0)) revert ZeroAddress();

        // Validate arrays non-empty and matching length
        if (_tokens.length == 0 || _tokens.length != _amounts.length) {
            revert InvalidAssetArray();
        }

        // Process each token withdrawal
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            uint256 amount = _amounts[i];

            // Validate amount > 0
            if (amount == 0) revert ZeroAmount();

            // Check sufficient balance
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < amount) {
                revert InsufficientBalance(token, amount, balance);
            }

            // Transfer tokens from this contract to receiver
            SafeERC20.safeTransfer(IERC20(token), _receiver, amount);

            // Update deposits mapping (decrement principal tracking)
            _deposits[token] -= amount;
        }

        // Emit event with all tokens, amounts, and receiver
        emit Withdrawn(_tokens, _amounts, _receiver, block.timestamp);
    }

    /**
     * @notice Emergency withdrawal of all idle assets
     * @dev Callable by owner OR King's core vault
     * @dev Works even when paused (no pause check)
     * @dev Transfers all idle balances back to kingVault and resets deposits
     */
    function emergencyWithdraw() external override {
        // Access control: owner or kingVault can call
        _requireOwnerOrKingVault();

        // No pause check - works even when paused

        // Prepare arrays for event
        address[] memory tokens = new address[](_assets.length);
        uint256[] memory amounts = new uint256[](_assets.length);
        uint256 count = 0;

        // Loop through all registered tokens
        for (uint256 i = 0; i < _assets.length; i++) {
            address token = _assets[i];

            // Skip if token is not registered/accepted
            if (!_registeredTokens[token]) {
                continue;
            }

            // Get current balance of this contract
            uint256 balance = IERC20(token).balanceOf(address(this));

            // Only process if balance > 0
            if (balance > 0) {
                // Transfer balance to kingVault
                SafeERC20.safeTransfer(IERC20(token), kingVault, balance);

                // Reset deposits tracking for this token
                _deposits[token] = 0;

                // Add to event arrays
                tokens[count] = token;
                amounts[count] = balance;
                count++;
            }
        }

        // Resize arrays to actual count (remove empty slots)
        address[] memory finalTokens = new address[](count);
        uint256[] memory finalAmounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            finalTokens[i] = tokens[i];
            finalAmounts[i] = amounts[i];
        }

        // Emit event with withdrawn tokens and amounts
        emit EmergencyWithdraw(finalTokens, finalAmounts, block.timestamp);
    }

    // ============================================
    // Pause Management
    // ============================================

    /**
     * @notice Pause vault operations
     * @dev Callable by owner OR King's core vault
     * @dev Blocks deposit() and withdraw() but allows emergencyWithdraw()
     * @dev Uses OpenZeppelin PausableUpgradeable inherited from KingVaultStorage
     */
    function pause() external virtual override {
        // Access control: owner or kingVault can call
        _requireOwnerOrKingVault();

        // Call OpenZeppelin's internal _pause()
        _pause();

        // Note: Paused(msg.sender) event is emitted by PausableUpgradeable
    }

    /**
     * @notice Resume vault operations
     * @dev Callable by owner OR King's core vault
     * @dev Re-enables deposit() and withdraw() operations
     */
    function unpause() external virtual override {
        // Access control: owner or kingVault can call
        _requireOwnerOrKingVault();

        // Call OpenZeppelin's internal _unpause()
        _unpause();

        // Note: Unpaused(msg.sender) event is emitted by PausableUpgradeable
    }

    // ============================================
    // Profit Management (Abstract)
    // ============================================

    /**
     * @notice Harvest profits from underlying protocols
     * @dev Only callable by owner (governance)
     * @dev Vault-specific implementation required (abstract)
     * @dev Specialized vaults MUST override to implement protocol-specific profit harvesting
     * @dev Does NOT distribute profits - call distributeProfits() separately
     * @dev Example: BoringVault claims rewards from Veda protocol
     */
    function harvestProfits() external virtual override {
        // Access control: only owner can harvest
        _requireOwner();

        // Emit harvest event
        emit ProfitsHarvested(block.timestamp);

        // Note: Specialized implementations MUST override this function
        // to add protocol-specific harvesting logic before calling super.harvestProfits()
    }

    // ============================================
    // Profit Distribution Management
    // ============================================

    /**
     * @notice Set profit distribution percentages for recipients
     * @dev Only callable by owner (governance)
     * @dev Updates specified recipients. Total of ALL recipients must equal 100%.
     * @dev Setting to 0 removes from distributions but keeps audit trail in mapping
     * @dev Manages _profitsRecipients array: adds if new & >0, removes if exists & =0
     * @param _recipients Array of recipient addresses to update
     * @param _percentsBPS Array of percentages in basis points (10000 = 100%)
     */
    function setProfitsDistribution(
        address[] memory _recipients,
        uint16[] memory _percentsBPS
    ) external virtual override {
        // Access control: only owner can set distribution
        _requireOwner();

        // Validate arrays non-empty and matching length
        if (_recipients.length == 0 || _recipients.length != _percentsBPS.length) {
            revert InvalidAssetArray();
        }

        // Process each recipient update
        for (uint256 i = 0; i < _recipients.length; i++) {
            address recipient = _recipients[i];
            uint16 percentBPS = _percentsBPS[i];

            // Validate recipient address
            if (recipient == address(0)) revert ZeroAddress();

            // Validate percentage is within bounds
            if (percentBPS > HUNDRED_PERCENT_IN_BPS) revert InvalidPercentage();

            // Track previous distribution percentage
            uint16 oldPercent = _profitsDistribution[recipient];

            // Update distribution mapping
            _profitsDistribution[recipient] = percentBPS;

            // Manage _profitsRecipients array
            if (percentBPS > 0) {
                // Add to recipients array if new (percentage was 0 before)
                if (oldPercent == 0) {
                    _addToProfitsRecipients(recipient);
                }
            } else {
                // Remove from recipients array if setting to 0
                if (oldPercent > 0) {
                    _removeFromProfitsRecipients(recipient);
                }
            }
        }

        // Validate total distribution equals 100% (10000 BPS)
        uint256 totalDistribution = 0;
        for (uint256 i = 0; i < _profitsRecipients.length; i++) {
            totalDistribution += _profitsDistribution[_profitsRecipients[i]];
        }

        // Revert if total doesn't equal exactly 100%
        if (totalDistribution != HUNDRED_PERCENT_IN_BPS) {
            revert InvalidDistributionTotal(totalDistribution);
        }

        // Emit event after validation passes (privacy: no recipient details)
        emit ProfitsDistributionUpdated(block.timestamp);
    }

    /**
     * @notice Distribute profits to configured recipients
     * @dev Only callable by owner (governance)
     * @dev Distributes profit (balance - principal) for all assets
     * @dev Same percentages apply to all tokens (not per-token distribution)
     * @dev Iterates through _assets array for tokens, _profitsRecipients array for recipients
     */
    function distributeProfits() external virtual override {
        // Access control: only owner can distribute
        _requireOwner();

        // Validate we have at least one recipient configured
        if (_profitsRecipients.length == 0) {
            revert InvalidAssetArray(); // No recipients configured
        }

        // Prepare event data structures
        address[] memory distributedTokens = new address[](_assets.length);
        uint256[] memory tokenTotalAmounts = new uint256[](_assets.length);
        uint256 tokenCount = 0;

        // 2D array for amounts per recipient per token
        uint256[][] memory recipientAmounts = new uint256[][](_profitsRecipients.length);
        for (uint256 i = 0; i < _profitsRecipients.length; i++) {
            recipientAmounts[i] = new uint256[](_assets.length);
        }

        // Iterate through all assets
        for (uint256 i = 0; i < _assets.length; i++) {
            address token = _assets[i];

            // Skip if token is not registered/accepted
            if (!_registeredTokens[token]) {
                continue;
            }

            // Get current balance and deposited principal
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 principal = _deposits[token];

            // Calculate profit (only distribute if balance > principal)
            if (balance <= principal) {
                continue; // No profit to distribute
            }

            uint256 profit = balance - principal;

            // Track token for event
            distributedTokens[tokenCount] = token;
            tokenTotalAmounts[tokenCount] = profit;

            // Distribute profit to each recipient
            for (uint256 j = 0; j < _profitsRecipients.length; j++) {
                address recipient = _profitsRecipients[j];
                uint16 percentBPS = _profitsDistribution[recipient];

                // Calculate recipient's share using mulDiv for precision
                // share = (profit * percentBPS) / HUNDRED_PERCENT_IN_BPS
                uint256 share = Math.mulDiv(profit, uint256(percentBPS), HUNDRED_PERCENT_IN_BPS);

                // Transfer share to recipient (skip if share is 0)
                if (share > 0) {
                    SafeERC20.safeTransfer(IERC20(token), recipient, share);
                    recipientAmounts[j][tokenCount] = share;
                }
            }

            tokenCount++;
        }

        // Resize arrays to actual count (remove empty slots)
        address[] memory finalTokens = new address[](tokenCount);
        uint256[] memory finalTotalAmounts = new uint256[](tokenCount);
        uint256[][] memory finalRecipientAmounts = new uint256[][](_profitsRecipients.length);

        for (uint256 i = 0; i < tokenCount; i++) {
            finalTokens[i] = distributedTokens[i];
            finalTotalAmounts[i] = tokenTotalAmounts[i];
        }

        for (uint256 i = 0; i < _profitsRecipients.length; i++) {
            finalRecipientAmounts[i] = new uint256[](tokenCount);
            for (uint256 j = 0; j < tokenCount; j++) {
                finalRecipientAmounts[i][j] = recipientAmounts[i][j];
            }
        }

        // Emit event with all distribution details
        emit ProfitsDistributed(
            _profitsRecipients,
            finalTokens,
            finalRecipientAmounts,
            block.timestamp
        );
    }

    // ============================================
    // Internal Asset Registration
    // ============================================

    /**
     * @notice Internal function to register assets
     * @dev Validates assets and updates storage mappings
     * @param _tokens Array of asset addresses to register
     * @param _accepted Array of acceptance status for assets
     */
    function _registerAssets(address[] memory _tokens, bool[] memory _accepted) internal virtual {
        // Validate arrays non-empty and matching length
        if (_tokens.length == 0 || _tokens.length != _accepted.length) {
            revert InvalidAssetArray();
        }

        // Loop through tokens and update registration
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            bool accepted = _accepted[i];

            // Validate asset address
            if (token == address(0)) revert ZeroAddress();

            // Validate asset has price available (ensures it's a valid asset)
            if (!IPriceProvider(priceProvider).isPriceAvailable(token)) {
                revert AssetNotAccepted(token);
            }

            // Track previous registration status
            bool wasRegistered = _registeredTokens[token];

            // Safety check: Prevent disabling asset if deposits exist
            if (!accepted && _deposits[token] > 0) {
                revert CannotDisableAssetWithDeposits(token, _deposits[token]);
            }

            // Update registration status
            _registeredTokens[token] = accepted;

            // Add to assets array if accepted (only if not already present)
            if (accepted) {
                _addToAssets(token);
                // Emit AssetAdded if newly accepted
                if (!wasRegistered) {
                    emit AssetAdded(token);
                }
            } else {
                // Emit AssetRemoved if was previously registered
                if (wasRegistered) {
                    emit AssetRemoved(token);
                }
                // Note: Asset stays in _assets array for audit trail
            }
        }
    }

    // ============================================
    // Token Management
    // ============================================

    /**
     * @notice Register or update assets (ERC-20)
     * @dev Only callable by owner (governance)
     * @param _tokens Array of asset addresses to register
     * @param _accepted Array of acceptance status (true = accepted, false = not accepted)
     */
    function registerAssets(address[] memory _tokens, bool[] memory _accepted) external virtual override {
        _requireOwner();
        _registerAssets(_tokens, _accepted);
    }

    /**
     * @notice Set the price provider for TVL calculations
     * @dev Only callable by owner (governance)
     * @param _newPriceProvider Address of the new price provider
     */
    function setPriceProvider(address _newPriceProvider) external {
        _requireOwner();

        // Validate address
        if (_newPriceProvider == address(0)) revert ZeroAddress();

        // Store old provider for event
        address oldProvider = priceProvider;

        // Update price provider
        priceProvider = _newPriceProvider;

        // Emit event
        emit PriceProviderUpdated(oldProvider, _newPriceProvider);
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Calculate the total value locked in this vault
     * @return ethValue Total value in ETH (18 decimals)
     * @return usdValue Total value in USD (18 decimals)
     * @dev Aggregates value of all deposited tokens using _deposits mapping
     */
    function tvl() external view override returns (uint256 ethValue, uint256 usdValue) {
        // Initialize total ETH value
        uint256 totalEth = 0;

        // Get the price provider
        IPriceProvider provider = IPriceProvider(priceProvider);

        // Loop through all assets
        for (uint256 i = 0; i < _assets.length; i++) {
            address token = _assets[i];

            // Skip if token is not registered/accepted
            if (!_registeredTokens[token]) {
                continue;
            }

            // Get deposited amount (principal tracking)
            uint256 deposited = _deposits[token];

            // Skip if no deposits
            if (deposited == 0) {
                continue;
            }

            // CRITICAL: Price must be available for ALL registered tokens with deposits
            // We revert rather than skip to prevent understated TVL
            if (!provider.isPriceAvailable(token)) {
                revert PriceNotAvailable(token);
            }

            // Get price in ETH
            uint256 priceInEth = provider.getPriceInEth(token);

            // CRITICAL: Price must be non-zero for accurate TVL
            // We revert rather than skip to prevent understated TVL
            if (priceInEth == 0) {
                revert PriceNotAvailable(token);
            }

            // Get token decimals
            uint8 decimals = _getDecimals(token);

            // Calculate token value in ETH using mulDiv for precision and overflow safety
            // tokenEthValue = (deposited * priceInEth) / (10 ** decimals)
            uint256 tokenEthValue = Math.mulDiv(deposited, priceInEth, 10 ** decimals);

            // Add to total
            totalEth += tokenEthValue;
        }

        // Convert ETH value to USD
        (uint256 ethUsdPrice, uint256 ethUsdDecimals) = provider.getEthUsdPrice();

        // Calculate USD value using mulDiv for precision and overflow safety
        // usdValue = (totalEth * ethUsdPrice) / (10 ** ethUsdDecimals)
        uint256 totalUsd = Math.mulDiv(totalEth, ethUsdPrice, 10 ** ethUsdDecimals);

        return (totalEth, totalUsd);
    }

    /**
     * @notice Get array of all registered and accepted assets
     * @return acceptedTokens Array of accepted asset addresses
     * @dev Filters _assets array by _registeredTokens[token] == true
     */
    function assets() external view override returns (address[] memory acceptedTokens) {
        // Count accepted tokens
        uint256 count = 0;
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_registeredTokens[_assets[i]]) {
                count++;
            }
        }

        // Create result array with correct size
        acceptedTokens = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_registeredTokens[_assets[i]]) {
                acceptedTokens[index] = _assets[i];
                index++;
            }
        }
    }

    /**
     * @notice Get balances of all registered assets
     * @dev Returns parallel arrays of assets and their balances from _deposits mapping
     * @dev Balances represent principal deposits only (not current market value or share appreciation)
     * @dev Specialized vaults may override to provide different balance calculations
     * @return assetAddresses Array of all registered asset addresses
     * @return amounts Array of principal amounts for each asset
     */
    function getBalances() external view virtual returns (address[] memory assetAddresses, uint256[] memory amounts) {
        // Get all assets (registered and accepted)
        assetAddresses = this.assets();

        // Allocate amounts array with same length
        amounts = new uint256[](assetAddresses.length);

        // Fill amounts array with principal deposits
        for (uint256 i = 0; i < assetAddresses.length; i++) {
            amounts[i] = _deposits[assetAddresses[i]];
        }

        return (assetAddresses, amounts);
    }

    /**
     * @notice Get balance of a specific asset
     * @dev Returns principal deposit amount from _deposits mapping
     * @dev Returns 0 if asset is not registered
     * @dev Simpler alternative to getBalances() when only one asset needs checking
     * @param _asset Address of the asset to query
     * @return amount Principal deposit amount for the asset (0 if not registered)
     */
    function getBalance(address _asset) external view virtual returns (uint256 amount) {
        // Return principal deposit for this asset (0 if not registered)
        return _deposits[_asset];
    }
}
