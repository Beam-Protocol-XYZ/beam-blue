// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id} from "../../interfaces/IMorpho.sol";

/// @title IDex
/// @notice Interface for the credit-based DEX
interface IDex {
    /* ═══════════════════════════════════════════ STRUCTS ═══════════════════════════════════════════ */

    struct TokenState {
        Id[] marketIds;
        uint256 morphoSupplyShares;
        uint256 morphoBorrowShares;
        uint256 localLiquidity;
        uint256 totalBorrowed;
        uint256 totalRepaid;
        uint256 totalLPDeposits;
        uint256 accumulatedFees;
    }

    struct LPPosition {
        uint256 shares;
        uint256 depositTimestamp;
    }

    struct PairState {
        uint256 heldBalance;
        uint256 outstandingDebt;
        uint256 debtTimestamp;
        uint256 expectedMatchTime;
        uint256 totalSwaps;
        int256 imbalance;
    }

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event MarketWhitelisted(Id indexed marketId, address indexed token);
    event MarketRemoved(Id indexed marketId);
    event LPDeposit(
        address indexed token,
        address indexed lp,
        uint256 amount,
        uint256 shares
    );
    event LPWithdraw(
        address indexed token,
        address indexed lp,
        uint256 shares,
        uint256 amount
    );
    event Swap(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed user,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        bool isTaker
    );
    event Reallocation(address indexed token, int256 deltaToMorpho);
    event AllocationUpdated(uint256 supply, uint256 repay, uint256 liquidity);

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    function transferOwnership(address newOwner) external;

    function whitelistMarket(Id marketId) external;

    function removeMarket(Id marketId) external;

    function setAllocation(
        uint256 supply,
        uint256 repay,
        uint256 liquidity
    ) external;

    function reallocate(address token, int256 deltaToMorpho) external;

    function setPairOracle(
        address tokenIn,
        address tokenOut,
        address oracle
    ) external;

    /* ═══════════════════════════════════════════ LP ═══════════════════════════════════════════ */

    function depositLP(
        address token,
        uint256 amount
    ) external returns (uint256 shares);

    function withdrawLP(
        address token,
        uint256 shares
    ) external returns (uint256 amount);

    /* ═══════════════════════════════════════════ SWAP ═══════════════════════════════════════════ */

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bool isReverse
    ) external returns (uint256 amountOut);

    /* ═══════════════════════════════════════════ VIEW ═══════════════════════════════════════════ */

    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool isReverse
    ) external view returns (uint256 amountOut, uint256 fee);

    function getTotalAssets(address token) external view returns (uint256);

    function getLPValue(
        address token,
        address lp
    ) external view returns (uint256);

    function getPairStatus(
        address tokenIn,
        address tokenOut
    )
        external
        view
        returns (
            uint256 heldBalance,
            uint256 outstandingDebt,
            int256 imbalance,
            uint256 expectedMatchTime
        );

    function getAvailableLiquidity(
        address token
    ) external view returns (uint256 local, uint256 morpho);

    function getMarkets(address token) external view returns (Id[] memory);
}
