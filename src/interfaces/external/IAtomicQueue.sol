// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title IAtomicQueue
 * @author King Protocol (https://www.kingprotocol.org)
 * @custom:security-contact security@kingprotocol.com
 * @notice Interface for Veda Finance AtomicQueue contract
 * @dev Handles asynchronous withdrawal requests via solver fulfillment
 * @dev Mainnet address: 0xD45884B592E316eB816199615A95C182F75dea07
 */
interface IAtomicQueue {
    /**
     * @notice Atomic withdrawal request data structure
     * @dev Stored on-chain and fulfilled by solvers off-chain
     * @param deadline Unix timestamp after which request expires
     * @param atomicPrice Price per share in offer asset (with slippage)
     * @param offerAmount Amount of shares offered for withdrawal
     * @param inSolve True if request is currently being solved
     */
    struct AtomicRequest {
        uint64 deadline; // Expiration timestamp
        uint88 atomicPrice; // Price with slippage (offer asset per share)
        uint96 offerAmount; // Shares to withdraw
        bool inSolve; // Solver lock flag
    }

    /**
     * @notice Create or update an atomic withdrawal request
     * @dev Creates new request or updates existing one
     * @dev To cancel: pass empty request (all fields = 0)
     * @dev Requires share approval to AtomicQueue
     * @dev Solver fulfills by providing want asset at atomicPrice
     * @param offer ERC20 shares being offered (BoringVault shares)
     * @param want ERC20 asset desired in return (e.g., WETH)
     * @param request AtomicRequest struct with deadline, price, amount, inSolve
     */
    function updateAtomicRequest(ERC20 offer, ERC20 want, AtomicRequest calldata request) external;

    /**
     * @notice Get user's current atomic withdrawal request
     * @dev Returns request details for a specific offer/want pair
     * @dev Returns empty struct if no request exists
     * @param user Address of the user
     * @param offer ERC20 shares being offered (BoringVault shares)
     * @param want ERC20 asset desired in return
     * @return AtomicRequest struct with current request details
     */
    function getUserAtomicRequest(address user, ERC20 offer, ERC20 want) external view returns (AtomicRequest memory);
}
