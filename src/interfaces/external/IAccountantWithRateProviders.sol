// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title IAccountantWithRateProviders
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice Interface for Veda Finance BoringVault Accountant contract
 * @dev Provides exchange rates for share pricing and valuation
 * @dev Mainnet address: 0x05A1552c5e18F5A0BB9571b5F2D6a4765ebdA32b (sETHFI Accountant)
 */
interface IAccountantWithRateProviders {
    /**
     * @notice Get current exchange rate (shares to base asset)
     * @dev Returns rate in base asset decimals (e.g., 18 for ETH)
     * @dev Rate = value of 1 share in base asset terms
     * @dev May revert if rate provider unavailable
     * @return rate Exchange rate (1 share = rate base assets)
     */
    function getRate() external view returns (uint256 rate);

    /**
     * @notice Get current exchange rate with safety checks
     * @dev Same as getRate() but with additional validation
     * @dev Preferred for critical operations
     * @return rate Exchange rate (1 share = rate base assets)
     */
    function getRateSafe() external view returns (uint256 rate);

    /**
     * @notice Get exchange rate for a specific quote asset
     * @dev Converts share value to any quote asset using oracle
     * @dev May revert if rate provider unavailable
     * @param quote ERC20 asset to price shares in
     * @return rate Exchange rate (1 share = rate quote assets)
     */
    function getRateInQuote(ERC20 quote) external view returns (uint256 rate);

    /**
     * @notice Get exchange rate for a specific quote asset with safety checks
     * @dev Same as getRateInQuote() but with additional validation
     * @dev Preferred for critical operations
     * @param quote ERC20 asset to price shares in
     * @return rate Exchange rate (1 share = rate quote assets)
     */
    function getRateInQuoteSafe(ERC20 quote) external view returns (uint256 rate);

    /**
     * @notice Get the base asset for this Accountant
     * @dev All rates are denominated in this asset by default
     * @dev For sETHFI vault, this is WETH
     * @return Address of the base ERC20 asset
     */
    function base() external view returns (address);

    /**
     * @notice Get the decimals used for rate calculations
     * @dev Typically matches base asset decimals (18 for WETH)
     * @return Number of decimals for rates
     */
    function decimals() external view returns (uint8);

    /**
     * @notice Get the BoringVault contract address
     * @dev The vault that this Accountant prices
     * @return Address of the BoringVault contract
     */
    function vault() external view returns (address);

    /**
     * @notice Check if Accountant is paused
     * @dev When paused, rate queries may revert or return stale data
     * @return True if paused, false otherwise
     */
    function isPaused() external view returns (bool);
}
