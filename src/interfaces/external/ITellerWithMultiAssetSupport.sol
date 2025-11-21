// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ITellerWithMultiAssetSupport
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice Interface for Veda Finance BoringVault Teller contract
 * @dev Handles atomic deposits (assets → shares in single transaction)
 * @dev Mainnet address: 0xe2acf9f80a2756E51D1e53F9f41583C84279Fb1f (sETHFI Teller)
 */
interface ITellerWithMultiAssetSupport {
    /**
     * @notice Deposit assets into BoringVault and receive shares
     * @dev Atomic operation - assets transferred and shares minted in single transaction
     * @dev Requires asset approval to vault (NOT Teller)
     * @dev Teller calculates shares using Accountant's rate
     * @dev Reverts if paused or slippage exceeded
     * @param depositAsset ERC20 asset to deposit
     * @param depositAmount Amount of asset to deposit
     * @param minimumMint Minimum shares to receive (slippage protection)
     * @return shares Amount of BoringVault shares minted to caller
     */
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint)
        external
        returns (uint256 shares);

    /**
     * @notice Get the Accountant contract address
     * @dev Used to query exchange rates for share calculations
     * @return Address of the Accountant contract
     */
    function accountant() external view returns (address);

    /**
     * @notice Get the BoringVault contract address
     * @dev The vault that holds deposited assets and issues shares
     * @return Address of the BoringVault contract
     */
    function vault() external view returns (address);

    /**
     * @notice Check if Teller is paused
     * @dev When paused, deposit() calls will revert
     * @return True if paused, false otherwise
     */
    function isPaused() external view returns (bool);
}
