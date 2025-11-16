// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IPriceProvider
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice Interface for price oracles that provide ETH and USD-denominated asset prices
 * @dev Prices are returned with 18 decimals precision (WAD format: 1e18 = 1.00)
 * @dev This interface is used by King Vaults to calculate TVL in both ETH and USD
 */
interface IPriceProvider {
    /**
     * @notice Get the ETH price of an asset
     * @param asset The address of the asset (ERC20 token or ETH)
     * @return priceInEth The price in ETH with 18 decimals (e.g., 0.05e18 = 0.05 ETH)
     * @dev Returns 0 if price is unavailable
     * @dev For ETH, should return 1e18 (1 ETH = 1 ETH)
     */
    function getPriceInEth(address asset) external view returns (uint256 priceInEth);

    /**
     * @notice Get the current ETH/USD price
     * @return ethUsdPrice The ETH price in USD
     * @return decimals The decimals of the price (typically 18 for WAD format)
     * @dev Example: If ETH = $2000, returns (2000e18, 18)
     */
    function getEthUsdPrice() external view returns (uint256 ethUsdPrice, uint256 decimals);

    /**
     * @notice Check if price data is available for an asset
     * @param asset The address of the asset
     * @return available True if price data exists and is valid
     * @dev Returns false if price is 0 or stale
     */
    function isPriceAvailable(address asset) external view returns (bool available);
}
