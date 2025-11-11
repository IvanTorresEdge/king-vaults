// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Governable} from "../governance/Governable.sol";

/**
 * @title KingVaultStorage
 * @notice Storage layout for King Protocol vault implementations
 * @dev Provides base storage structure for all vault types with UUPS upgradeability
 * @dev Uses simplified storage with separate mappings for gas efficiency (Decision 12 & 13)
 */
abstract contract KingVaultStorage is
    Initializable,
    Governable,
    PausableUpgradeable,
    UUPSUpgradeable
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
     */
    mapping(address => uint256) internal _profitsDistribution;

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
     * @dev Storage gap to allow for future upgrades
     * @dev Reserves 50 slots for adding new state variables in future versions
     * @dev Critical for UUPS upgradeability pattern
     */
    uint256[50] private __gap;

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
