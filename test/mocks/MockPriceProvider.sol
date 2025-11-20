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

    /// @notice Mapping of asset address => whether price is set
    mapping(address => bool) private _priceSet;

    /// @notice Mapping of asset address => custom timestamp (0 = use block.timestamp)
    mapping(address => uint256) private _priceTimestamp;

    /// @notice Mapping of asset address => validity flag
    mapping(address => bool) private _priceInvalid;

    /// @notice Current ETH/USD price (18 decimals)
    uint256 private _ethUsdPrice;

    /// @notice Custom timestamp for ETH/USD price (0 = use block.timestamp)
    uint256 private _ethUsdTimestamp;

    /// @notice Validity flag for ETH/USD price
    bool private _ethUsdInvalid;

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
        _priceSet[asset] = true;
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
            _priceSet[assets[i]] = true;
        }
    }

    /**
     * @notice Set price availability for an asset
     * @param asset The asset address
     * @param available Whether price is available
     */
    function setPriceAvailability(address asset, bool available) external {
        _priceSet[asset] = available;
    }

    /**
     * @notice Set the ETH/USD price
     * @param ethUsdPrice The new ETH price in USD (18 decimals)
     */
    function setEthUsdPrice(uint256 ethUsdPrice) external {
        _ethUsdPrice = ethUsdPrice;
    }

    /**
     * @notice Set a custom timestamp for an asset price
     * @param asset The asset address
     * @param timestamp The custom timestamp (0 = use block.timestamp)
     */
    function setPriceTimestamp(address asset, uint256 timestamp) external {
        _priceTimestamp[asset] = timestamp;
    }

    /**
     * @notice Set the validity flag for an asset price
     * @param asset The asset address
     * @param invalid Whether the price should be marked as invalid
     */
    function setPriceInvalid(address asset, bool invalid) external {
        _priceInvalid[asset] = invalid;
    }

    /**
     * @notice Set a custom timestamp for ETH/USD price
     * @param timestamp The custom timestamp (0 = use block.timestamp)
     */
    function setEthUsdTimestamp(uint256 timestamp) external {
        _ethUsdTimestamp = timestamp;
    }

    /**
     * @notice Set the validity flag for ETH/USD price
     * @param invalid Whether the price should be marked as invalid
     */
    function setEthUsdInvalid(bool invalid) external {
        _ethUsdInvalid = invalid;
    }

    /**
     * @inheritdoc IPriceProvider
     */
    function getPriceInEth(address asset) external view override returns (uint256 priceInEth) {
        require(_priceSet[asset], "MockPriceProvider: Price not set");
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
    function getPriceDataInEth(address asset)
        external
        view
        override
        returns (IPriceProvider.PriceData memory priceData)
    {
        // If price is not set, return invalid price data instead of reverting
        // This allows the vault to handle the error appropriately
        if (!_priceSet[asset]) {
            priceData.price = 0;
            priceData.timestamp = 0;
            priceData.isValid = false;
            return priceData;
        }

        // Return price with custom or current timestamp and validity flag
        priceData.price = _pricesInEth[asset];
        priceData.timestamp = _priceTimestamp[asset] == 0 ? block.timestamp : _priceTimestamp[asset];
        priceData.isValid = !_priceInvalid[asset];

        return priceData;
    }

    /**
     * @inheritdoc IPriceProvider
     */
    function getEthUsdPriceData()
        external
        view
        override
        returns (IPriceProvider.PriceData memory priceData, uint256 decimals)
    {
        // Return ETH/USD price with custom or current timestamp and validity flag
        priceData.price = _ethUsdPrice;
        priceData.timestamp = _ethUsdTimestamp == 0 ? block.timestamp : _ethUsdTimestamp;
        priceData.isValid = !_ethUsdInvalid;
        decimals = _ethUsdDecimals;

        return (priceData, decimals);
    }
}
