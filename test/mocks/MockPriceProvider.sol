// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../../src/interfaces/IPriceProvider.sol";

/**
 * @title MockPriceProvider
 * @notice Mock price oracle for testing King Vaults
 * @dev Allows manual price setting for any asset with configurable ETH/USD price
 */
contract MockPriceProvider is IPriceProvider {
    /// @notice Mapping of asset address => price in ETH (18 decimals)
    mapping(address => uint256) private _pricesInEth;

    /// @notice Mapping of asset address => price availability
    mapping(address => bool) private _priceAvailable;

    /// @notice Current ETH/USD price (18 decimals)
    uint256 private _ethUsdPrice;

    /// @notice Decimals for ETH/USD price (always 18)
    uint256 private constant _ethUsdDecimals = 18;

    /**
     * @notice Constructor with default ETH price
     * @param defaultEthUsdPrice Default ETH price in USD (e.g., 2000e18 for $2000)
     */
    constructor(uint256 defaultEthUsdPrice) {
        _ethUsdPrice = defaultEthUsdPrice > 0 ? defaultEthUsdPrice : 2000e18;
    }

    /**
     * @notice Set the ETH price for a specific asset
     * @param asset The asset address
     * @param priceInEth The price in ETH with 18 decimals
     */
    function setPrice(address asset, uint256 priceInEth) external {
        _pricesInEth[asset] = priceInEth;
        _priceAvailable[asset] = true;
    }

    /**
     * @notice Batch set prices for multiple assets
     * @param assets Array of asset addresses
     * @param pricesInEth Array of prices corresponding to assets
     */
    function setPrices(address[] calldata assets, uint256[] calldata pricesInEth) external {
        require(assets.length == pricesInEth.length, "MockPriceProvider: Length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            _pricesInEth[assets[i]] = pricesInEth[i];
            _priceAvailable[assets[i]] = true;
        }
    }

    /**
     * @notice Set price availability for an asset
     * @param asset The asset address
     * @param available Whether price is available
     */
    function setPriceAvailability(address asset, bool available) external {
        _priceAvailable[asset] = available;
    }

    /**
     * @notice Set the ETH/USD price
     * @param ethUsdPrice The new ETH price in USD (18 decimals)
     */
    function setEthUsdPrice(uint256 ethUsdPrice) external {
        _ethUsdPrice = ethUsdPrice;
    }

    /**
     * @inheritdoc IPriceProvider
     */
    function getPriceInEth(address asset) external view override returns (uint256 priceInEth) {
        return _pricesInEth[asset];
    }

    /**
     * @inheritdoc IPriceProvider
     */
    function getEthUsdPrice() external view override returns (uint256 ethUsdPrice, uint256 decimals) {
        return (_ethUsdPrice, _ethUsdDecimals);
    }

    /**
     * @inheritdoc IPriceProvider
     */
    function isPriceAvailable(address asset) external view override returns (bool available) {
        return _priceAvailable[asset] && _pricesInEth[asset] > 0;
    }
}
