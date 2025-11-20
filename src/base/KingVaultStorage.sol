// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IKingVault} from "../interfaces/IKingVault.sol";

/**
 * @title KingVaultStorage
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice Storage layout for King Protocol vault implementations
 * @dev Provides base storage structure for all vault types with UUPS upgradeability
 * @dev Uses simplified storage with separate mappings for gas efficiency (Decision 12 & 13)
 */
abstract contract KingVaultStorage is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ============================================
    // State Variables
    // ============================================

    /**
     * @notice King's core vault address (only authorized depositor/withdrawer)
     * @dev Immutable after initialization - set once in __KingVault_init and cannot be changed
     * @dev Critical security requirement: prevents unauthorized address changes (Decision 11)
     */
    address public kingVault;

    /**
     * @notice Price provider for token valuation
     * @dev Used for TVL calculation in ETH and USD
     */
    address public priceProvider;

    /**
     * @notice Mapping of token address => accepted status
     * @dev true = token is accepted for deposits, false = not accepted (kept for audit trail)
     * @dev Tokens are never removed from this mapping once added (audit trail)
     */
    mapping(address => bool) internal _registeredTokens;

    /**
     * @notice Mapping of token address => deposited amount (principal tracking)
     * @dev Tracks original deposited amounts, not current market value
     * @dev Used to calculate profits: current balance - _deposits[token] = profit
     */
    mapping(address => uint256) internal _deposits;

    /**
     * @notice Array of registered token addresses for iteration
     * @dev Tokens are added when first registered, never removed (audit trail)
     * @dev assets() view function filters this by _registeredTokens[token] == true
     */
    address[] internal _assets;

    /**
     * @notice Mapping of recipient address => profit distribution percentage in BPS
     * @dev Setting to 0 removes from distributions but keeps audit trail in mapping
     * @dev Total of all percentages MUST equal 10000 BPS (100%)
     * @dev uint16 is sufficient (max 65535 > 10000 BPS) and enables storage packing
     */
    mapping(address => uint16) internal _profitsDistribution;

    /**
     * @notice Array of profit recipients for iteration during distribution
     * @dev Managed by setProfitsDistribution: add when % > 0, remove when % = 0
     * @dev Used by distributeProfits() to iterate and distribute to active recipients
     */
    address[] internal _profitsRecipients;

    /**
     * @notice Constant for percentage calculations
     * @dev 10000 BPS = 100%
     */
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 100_00;

    /**
     * @notice Maximum allowed price age in seconds
     * @dev Prices older than this threshold are considered stale
     * @dev Default is 6 hours (21600 seconds), configurable by owner
     * @dev Used to prevent using outdated oracle prices for TVL and profit calculations
     */
    uint256 public maxPriceAge;

    /**
     * @dev Storage gap to allow for future upgrades
     * @dev Reserves 42 slots to complete 50-slot layer (8 used + 42 gap = 50 total)
     * @dev Critical for UUPS upgradeability pattern
     * @dev Follows OpenZeppelin standard: each inheritance layer occupies exactly 50 slots
     */
    uint256[42] private __gap;

    // ============================================
    // Internal Helper Functions
    // ============================================

    /**
     * @notice Get token decimals using IERC20Metadata interface
     * @param token Address of the ERC20 token
     * @return decimals Number of decimals for the token
     * @dev Queries the token contract for its decimal places
     * @dev Used in TVL calculation to normalize amounts
     */
    function _getDecimals(address token) internal view returns (uint8 decimals) {
        return IERC20Metadata(token).decimals();
    }

    /**
     * @notice Add token to _assets array if not already present
     * @param token Address of the token to add
     * @dev Checks if token exists in array before adding (prevents duplicates)
     * @dev Used by registerAssets() when accepting new tokens
     * @dev Part of Mapping + Array pattern (Decision 13)
     */
    function _addToAssets(address token) internal {
        // Check if token already exists in _assets array
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i] == token) {
                return; // Token already in array, no need to add
            }
        }
        // Token not found, add it to the array
        _assets.push(token);
    }

    /**
     * @notice Add recipient to _profitsRecipients array
     * @param recipient Address of the profit recipient to add
     * @dev Only adds if not already present (prevents duplicates)
     * @dev Called by setProfitsDistribution() when percentage > 0
     * @dev Part of Mapping + Array pattern (Decision 13)
     */
    function _addToProfitsRecipients(address recipient) internal {
        // Check if recipient already exists in array
        for (uint256 i = 0; i < _profitsRecipients.length; i++) {
            if (_profitsRecipients[i] == recipient) {
                return; // Recipient already in array
            }
        }
        // Recipient not found, add to array
        _profitsRecipients.push(recipient);
    }

    /**
     * @notice Remove recipient from _profitsRecipients array using swap-and-pop pattern
     * @param recipient Address of the profit recipient to remove
     * @dev Uses swap-and-pop for O(1) removal: swaps with last element then pops
     * @dev Called by setProfitsDistribution() when percentage = 0
     * @dev Part of Mapping + Array pattern (Decision 13)
     */
    function _removeFromProfitsRecipients(address recipient) internal {
        uint256 length = _profitsRecipients.length;

        // Find the recipient in the array
        for (uint256 i = 0; i < length; i++) {
            if (_profitsRecipients[i] == recipient) {
                // Swap with last element
                _profitsRecipients[i] = _profitsRecipients[length - 1];
                // Remove last element
                _profitsRecipients.pop();
                return;
            }
        }
        // If recipient not found, do nothing (idempotent operation)
    }

    /**
     * @notice Require caller to be King's core vault
     * @dev Reverts with OnlyKingVault error if caller is not kingVault
     */
    function _requireKingVault() internal view {
        if (msg.sender != kingVault) {
            revert IKingVault.OnlyKingVault();
        }
    }

    /**
     * @notice Require caller to be owner
     * @dev Reverts with OwnableUnauthorizedAccount error if caller is not owner
     */
    function _requireOwner() internal view {
        _checkOwner();
    }

    /**
     * @notice Require caller to be owner or King's core vault
     * @dev Reverts with OnlyOwnerOrKingVault error if caller is neither
     */
    function _requireOwnerOrKingVault() internal view {
        if (msg.sender != owner() && msg.sender != kingVault) {
            revert IKingVault.OnlyOwnerOrKingVault();
        }
    }

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get profit recipient information for a specific address
     * @param recipient Address to query
     * @return isRecipient True if address is an active profit recipient
     * @return percentage Distribution percentage in BPS (0 if not a recipient)
     * @dev Does not expose the full recipients array for privacy
     * @dev Returns (true, percentage) if percentage > 0, otherwise (false, 0)
     */
    function getProfitRecipientInfo(address recipient) public view returns (bool isRecipient, uint16 percentage) {
        percentage = _profitsDistribution[recipient];
        isRecipient = percentage > 0;
    }

    // ============================================
    // UUPS Upgrade Authorization
    // ============================================

    /**
     * @notice Authorize contract upgrade
     * @dev Only owner can authorize upgrades
     * @dev Required by UUPSUpgradeable
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        newImplementation; // Silence unused parameter warning
        _checkOwner();
    }

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Constructor that disables initializers
     * @dev Prevents implementation contract from being initialized
     * @dev Required for UUPS proxy pattern security
     */
    constructor() {
        _disableInitializers();
    }
}
