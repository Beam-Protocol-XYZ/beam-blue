// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id} from "./IMorpho.sol";

/// @title CrossChainTypes
/// @notice Shared types for cross-chain borrow protocol with full Morpho-style tracking
library CrossChainTypes {
    /// @notice Message types for cross-chain communication
    enum MessageType {
        BORROW, // Request borrow on remote chain
        BORROW_ACK, // Acknowledge borrow executed (includes market state)
        BORROW_FAILED, // Borrow failed on remote
        REPAY, // Request repay on remote chain
        REPAY_ACK, // Acknowledge repay executed (includes market state)
        LIQUIDATE_REPAY, // Liquidation-triggered repay
        SYNC_MARKET, // Request market state sync
        SYNC_PRICE // Price update from remote oracle
    }

    /// @notice Borrow request payload
    struct BorrowRequest {
        bytes32 positionId; // Unique position identifier
        address user; // User who initiated borrow
        Id marketId; // Morpho market to borrow from
        uint256 amount; // Amount to borrow
        address receiver; // Receiver of borrowed funds
        uint64 nonce; // Replay protection
    }

    /// @notice Borrow acknowledgment payload with market state
    struct BorrowAck {
        bytes32 positionId;
        uint256 borrowShares; // Shares received from Morpho
        uint256 actualAmount; // Actual amount borrowed
        bool success;
        uint64 nonce;
    }

    /// @notice Extended borrow ack with market state (decoded separately)
    struct BorrowAckExtended {
        BorrowAck ack;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
    }

    /// @notice Repay request payload
    struct RepayRequest {
        bytes32 positionId;
        Id marketId;
        uint256 amount; // Amount to repay (0 = use maxShares)
        uint256 maxShares; // Max shares to repay
        bool isLiquidation; // Whether this is a liquidation repay
        uint64 nonce;
    }

    /// @notice Repay acknowledgment payload
    struct RepayAck {
        bytes32 positionId;
        uint256 sharesRepaid;
        uint256 amountRepaid;
        bool success;
        uint64 nonce;
    }

    /// @notice Extended repay ack with market state
    struct RepayAckExtended {
        RepayAck ack;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
    }

    /// @notice Market state sync payload
    struct MarketStateSync {
        Id marketId;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint256 borrowRate;
        uint256 oraclePrice;
        uint256 timestamp;
    }

    /// @notice Price sync payload
    struct PriceSync {
        Id marketId;
        uint256 price;
        uint256 timestamp;
    }
}
