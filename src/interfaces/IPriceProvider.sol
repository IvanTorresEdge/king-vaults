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
     * @notice Price data with validation information
     * @param price The price value with 18 decimals
     * @param timestamp The timestamp when the price was last updated
     * @param isValid Whether the price is currently valid (not stale, within circuit breaker limits)
     */
    struct PriceData {
        uint256 price;
        uint256 timestamp;
        bool isValid;
    }

    /**
     * @notice Get the ETH price of an asset
     * @param asset The address of the asset (ERC20 token or ETH)
     * @return priceInEth The price in ETH with 18 decimals (e.g., 0.05e18 = 0.05 ETH)
     * @dev Reverts if token is not registered in the price provider
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
     * @notice Get validated price data for an asset in ETH
     * @param asset The address of the asset (ERC20 token or ETH)
     * @return priceData Struct containing price, timestamp, and validity flag
     * @dev Reverts if token is not registered in the price provider
     * @dev Consumers should check isValid flag and timestamp before using price
     */
    function getPriceDataInEth(address asset) external view returns (PriceData memory priceData);

    /**
     * @notice Get validated ETH/USD price data
     * @return priceData Struct containing ETH/USD price, timestamp, and validity flag
     * @return decimals The decimals of the price (typically 18 for WAD format)
     * @dev Consumers should check isValid flag and timestamp before using price
     */
    function getEthUsdPriceData() external view returns (PriceData memory priceData, uint256 decimals);
}
