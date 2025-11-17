// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockERC4626Vault
 * @notice Mock ERC-4626 vault for testing KingTokenizedVault
 * @dev Allows manual control of exchange rate for testing profit scenarios
 */
contract MockERC4626Vault is ERC4626 {
    // Override exchange rate (1e18 = 1:1 ratio)
    uint256 private _exchangeRate;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {
        _exchangeRate = 1e18; // Start at 1:1
    }

    /**
     * @notice Set custom exchange rate for testing
     * @dev Rate is in 18 decimals (1e18 = 1:1)
     * @param rate New exchange rate
     */
    function setExchangeRate(uint256 rate) external {
        _exchangeRate = rate;
    }

    /**
     * @notice Override to use custom exchange rate
     */
    function _convertToAssets(uint256 shares, Math.Rounding /* rounding */ )
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return (shares * _exchangeRate) / 1e18;
    }

    /**
     * @notice Override to use custom exchange rate
     */
    function _convertToShares(uint256 assets, Math.Rounding /* rounding */ )
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return (assets * 1e18) / _exchangeRate;
    }
}
