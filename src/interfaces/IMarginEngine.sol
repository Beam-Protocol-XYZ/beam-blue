// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id} from "./IMorpho.sol";

/// @title IMarginEngine
/// @notice Interface for the leveraged margin trading engine
/// @dev Manages positions that borrow via uncollateralized lending and deploy to strategies
interface IMarginEngine {
    /* ═══════════════════════════════════════════ STRUCTS ═══════════════════════════════════════════ */

    /// @notice Configuration for a collateral token
    struct CollateralConfig {
        address oracle; // Price oracle (returns price scaled by 1e36)
        uint256 maxLeverage; // Maximum leverage multiplier (WAD scale, e.g., 10e18 = 10x)
        uint256 liquidationThreshold; // Health factor below which liquidation is allowed (WAD, e.g., 1.05e18)
        uint256 liquidationIncentive; // Bonus for liquidators (WAD scale, e.g., 0.05e18 = 5%)
        uint8 decimals; // Token decimals
        bool enabled;
    }

    /// @notice Configuration for a loan token market
    struct LoanMarketConfig {
        Id morphoMarketId; // Morpho market ID for borrowing
        address oracle; // Price oracle for loan token
        uint8 decimals; // Token decimals
        bool enabled;
    }

    /// @notice User margin position
    struct Position {
        address user;
        address collateralToken;
        address loanToken;
        uint128 collateralAmount; // Deposited collateral
        uint128 borrowShares; // Shares of debt in Morpho market
        address strategy; // Deployed strategy address
        uint128 strategyShares; // Shares held in strategy
        uint128 lastUpdate; // Last interest accrual timestamp
        bool active;
    }

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event CollateralDeposited(
        bytes32 indexed positionId,
        address indexed user,
        address token,
        uint256 amount
    );

    event CollateralWithdrawn(
        bytes32 indexed positionId,
        address indexed user,
        address token,
        uint256 amount
    );

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed user,
        address collateralToken,
        address loanToken,
        uint256 collateralAmount,
        uint256 borrowAmount,
        address strategy,
        uint256 leverage
    );

    event PositionClosed(
        bytes32 indexed positionId,
        address indexed user,
        uint256 collateralReturned,
        int256 pnl
    );

    event PositionIncreased(
        bytes32 indexed positionId,
        uint256 additionalBorrow,
        uint256 additionalStrategyShares
    );

    event PositionDecreased(
        bytes32 indexed positionId,
        uint256 debtRepaid,
        uint256 strategySharesWithdrawn
    );

    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized,
        uint256 incentive
    );

    event CollateralConfigSet(
        address indexed token,
        uint256 maxLeverage,
        uint256 liquidationThreshold
    );

    event LoanMarketConfigSet(address indexed token, Id indexed marketId);

    event StrategyWhitelisted(address indexed strategy, bool whitelisted);

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error Paused();
    error Reentrancy();
    error CollateralNotEnabled();
    error LoanMarketNotEnabled();
    error StrategyNotWhitelisted();
    error ExceedsMaxLeverage();
    error PositionNotActive();
    error PositionNotHealthy();
    error PositionHealthy();
    error InsufficientCollateral();
    error UnauthorizedCaller();
    error StalePrice();
    error StrategyAssetMismatch();

    /* ═══════════════════════════════════════════ ADMIN FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Set collateral token configuration
    function setCollateralConfig(
        address token,
        address oracle,
        uint256 maxLeverage,
        uint256 liquidationThreshold,
        uint256 liquidationIncentive,
        uint8 decimals
    ) external;

    /// @notice Set loan market configuration
    function setLoanMarketConfig(
        address loanToken,
        Id morphoMarketId,
        address oracle,
        uint8 decimals
    ) external;

    /// @notice Whitelist or delist a strategy
    function setStrategyWhitelist(address strategy, bool whitelisted) external;

    /// @notice Pause/unpause the contract
    function setPaused(bool paused) external;

    /* ═══════════════════════════════════════════ POSITION MANAGEMENT ═══════════════════════════════════════════ */

    /// @notice Open a new leveraged margin position
    /// @param collateralToken Token to use as collateral
    /// @param loanToken Token to borrow
    /// @param collateralAmount Amount of collateral to deposit
    /// @param borrowAmount Amount to borrow (must respect maxLeverage)
    /// @param strategy Whitelisted strategy to deploy borrowed funds
    /// @return positionId Unique identifier for the position
    function openPosition(
        address collateralToken,
        address loanToken,
        uint256 collateralAmount,
        uint256 borrowAmount,
        address strategy
    ) external returns (bytes32 positionId);

    /// @notice Add collateral to an existing position
    /// @param positionId Position to add collateral to
    /// @param amount Amount of collateral to add
    function addCollateral(bytes32 positionId, uint256 amount) external;

    /// @notice Withdraw collateral from a position (must remain healthy)
    /// @param positionId Position to withdraw from
    /// @param amount Amount of collateral to withdraw
    function withdrawCollateral(bytes32 positionId, uint256 amount) external;

    /// @notice Increase position size (borrow more, deploy more)
    /// @param positionId Position to increase
    /// @param additionalBorrow Additional amount to borrow
    function increasePosition(
        bytes32 positionId,
        uint256 additionalBorrow
    ) external;

    /// @notice Decrease position size (withdraw from strategy, repay debt)
    /// @param positionId Position to decrease
    /// @param debtToRepay Amount of debt to repay
    function decreasePosition(bytes32 positionId, uint256 debtToRepay) external;

    /// @notice Close entire position
    /// @param positionId Position to close
    /// @return collateralReturned Amount of collateral returned to user
    /// @return pnl Profit or loss (positive = profit)
    function closePosition(
        bytes32 positionId
    ) external returns (uint256 collateralReturned, int256 pnl);

    /* ═══════════════════════════════════════════ LIQUIDATION ═══════════════════════════════════════════ */

    /// @notice Liquidate an unhealthy position
    /// @param positionId Position to liquidate
    /// @param maxDebtToRepay Maximum amount of debt to repay (0 = full liquidation)
    function liquidate(bytes32 positionId, uint256 maxDebtToRepay) external;

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Get position details
    function getPosition(
        bytes32 positionId
    ) external view returns (Position memory);

    /// @notice Get position health factor
    /// @return healthFactor WAD-scaled health factor (< 1e18 means liquidatable)
    function getHealthFactor(
        bytes32 positionId
    ) external view returns (uint256 healthFactor);

    /// @notice Get current debt value in loan tokens
    function getDebtValue(
        bytes32 positionId
    ) external view returns (uint256 debtValue);

    /// @notice Get current strategy position value in loan tokens
    function getStrategyValue(
        bytes32 positionId
    ) external view returns (uint256 strategyValue);

    /// @notice Get collateral value in loan token terms
    function getCollateralValue(
        bytes32 positionId
    ) external view returns (uint256 collateralValue);

    /// @notice Check if a position is liquidatable
    function isLiquidatable(bytes32 positionId) external view returns (bool);

    /// @notice Calculate maximum borrowable amount for given collateral
    function getMaxBorrowable(
        address collateralToken,
        address loanToken,
        uint256 collateralAmount
    ) external view returns (uint256 maxBorrow);

    /// @notice Check if a strategy is whitelisted
    function isWhitelistedStrategy(
        address strategy
    ) external view returns (bool);
}
