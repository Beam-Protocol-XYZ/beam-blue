// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, Market, IMorpho} from "../interfaces/IMorpho.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MathLib, WAD} from "../libraries/MathLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../libraries/MarketParamsLib.sol";
import {UtilsLib} from "../libraries/UtilsLib.sol";

/// @title MarginEngine
/// @notice Leveraged margin trading using Morpho uncollateralized lending
/// @dev Uses Morpho's exact health formula: maxBorrow = collateral * price / SCALE * lltv
///      Position is healthy if maxBorrow >= borrowed
contract MarginEngine is IMarginEngine {
    using SafeTransferLib for IERC20;
    using MathLib for uint256;
    using MathLib for uint128;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;
    using UtilsLib for uint256;

    /* ═══════════════════════════════════════════ CONSTANTS ═══════════════════════════════════════════ */

    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant MIN_COLLATERAL = 1000;

    /// @dev Liquidation incentive factor constants (same as Morpho)
    uint256 public constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18; // 115%
    uint256 public constant LIQUIDATION_CURSOR = 0.3e18; // 30%

    /* ═══════════════════════════════════════════ IMMUTABLES ═══════════════════════════════════════════ */

    IMorpho public immutable morpho;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    address public owner;
    bool public paused;
    uint256 private _locked = 1;

    /// @notice Margin pair configuration
    /// @param oracle Returns collateral price in loan token terms (1e36 scale)
    /// @param morphoMarketId Morpho market for borrowing
    /// @param lltv Loan-to-value ratio for health check (WAD, e.g., 0.9e18 = 90%)
    /// @param maxLeverage Maximum initial leverage (WAD, e.g., 10e18 = 10x)
    /// @param liquidationIncentiveFactor Bonus for liquidators (WAD, e.g., 1.05e18 = 5% bonus)
    struct MarginPairConfig {
        address oracle;
        Id morphoMarketId;
        uint256 lltv;
        uint256 maxLeverage;
        uint256 liquidationIncentiveFactor;
        bool enabled;
    }

    /// @notice Pair key: keccak256(collateralToken, loanToken)
    mapping(bytes32 pairKey => MarginPairConfig) public pairConfigs;

    /// @notice Per-token collateral configurations (set via setCollateralConfig)
    mapping(address token => CollateralConfig) public collateralConfigs;
    address[] public collateralTokens;

    /// @notice Per-token loan market configurations (set via setLoanMarketConfig)
    mapping(address token => LoanMarketConfig) public loanMarketConfigs;
    address[] public loanTokens;

    // Whitelisted strategies
    mapping(address strategy => bool) public whitelistedStrategies;

    // User positions
    mapping(bytes32 positionId => Position) public positions;
    mapping(address user => bytes32[]) public userPositionIds;

    // Protocol reserves from liquidation fees
    mapping(address token => uint256) public protocolReserves;

    /* ═══════════════════════════════════════════ MODIFIERS ═══════════════════════════════════════════ */

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked == 2) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(address _morpho, address _owner) {
        if (_morpho == address(0) || _owner == address(0)) revert ZeroAddress();
        morpho = IMorpho(_morpho);
        owner = _owner;
    }

    /* ═══════════════════════════════════════════ ADMIN FUNCTIONS ═══════════════════════════════════════════ */

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /// @notice Configure a margin pair
    /// @param collateralToken The collateral token
    /// @param loanToken The loan token
    /// @param oracle Oracle returning collateral price in loan terms (1e36 scale)
    /// @param morphoMarketId Morpho market for borrowing
    /// @param lltv Liquidation loan-to-value (WAD), position unhealthy when borrowed > maxBorrow
    /// @param maxLeverage Maximum initial leverage multiplier (WAD)
    function setMarginPairConfig(
        address collateralToken,
        address loanToken,
        address oracle,
        Id morphoMarketId,
        uint256 lltv,
        uint256 maxLeverage
    ) external onlyOwner {
        if (
            collateralToken == address(0) ||
            loanToken == address(0) ||
            oracle == address(0)
        ) revert ZeroAddress();
        require(lltv < WAD, "LLTV must be < 1");
        require(maxLeverage > 0, "Max leverage must be > 0");

        bytes32 pairKey = _getPairKey(collateralToken, loanToken);
        MarginPairConfig storage config = pairConfigs[pairKey];

        if (!config.enabled) {
            IERC20(loanToken).safeApprove(address(morpho), type(uint256).max);
        }

        config.oracle = oracle;
        config.morphoMarketId = morphoMarketId;
        config.lltv = lltv;
        config.maxLeverage = maxLeverage;
        // Calculate liquidation incentive factor same as Morpho
        // liquidationIncentiveFactor = min(MAX, WAD / (WAD - CURSOR * (WAD - lltv)))
        config.liquidationIncentiveFactor = _liquidationIncentiveFactor(lltv);
        config.enabled = true;

        emit CollateralConfigSet(collateralToken, maxLeverage, lltv);
    }

    function setStrategyWhitelist(
        address strategy,
        bool whitelisted
    ) external onlyOwner {
        if (strategy == address(0)) revert ZeroAddress();

        if (whitelisted && !whitelistedStrategies[strategy]) {
            address asset = IStrategy(strategy).asset();
            IERC20(asset).safeApprove(strategy, type(uint256).max);
            // Authorize strategy in Morpho to withdraw on MarginEngine's behalf
            morpho.setAuthorization(strategy, true);
        }

        whitelistedStrategies[strategy] = whitelisted;
        emit StrategyWhitelisted(strategy, whitelisted);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /// @inheritdoc IMarginEngine
    function setCollateralConfig(
        address token,
        address oracle,
        uint256 maxLeverage,
        uint256 liquidationThreshold,
        uint256 liquidationIncentive,
        uint8 decimals
    ) external onlyOwner {
        if (token == address(0) || oracle == address(0)) revert ZeroAddress();
        require(
            liquidationThreshold > 0 && liquidationThreshold < WAD,
            "invalid liq threshold"
        );
        require(maxLeverage > 0, "Max leverage must be > 0");

        CollateralConfig storage config = collateralConfigs[token];
        if (!config.enabled) {
            collateralTokens.push(token);
        }

        config.oracle = oracle;
        config.maxLeverage = maxLeverage;
        config.liquidationThreshold = liquidationThreshold;
        config.liquidationIncentive = liquidationIncentive;
        config.decimals = decimals;
        config.enabled = true;

        emit CollateralConfigSet(token, maxLeverage, liquidationThreshold);

        // Auto-assemble pair configs for all known loan tokens
        for (uint256 i = 0; i < loanTokens.length; i++) {
            address loan = loanTokens[i];
            if (loanMarketConfigs[loan].enabled) {
                _assemblePairConfig(token, loan);
            }
        }
    }

    /// @inheritdoc IMarginEngine
    function setLoanMarketConfig(
        address loanToken,
        Id morphoMarketId,
        address oracle,
        uint8 decimals
    ) external onlyOwner {
        if (loanToken == address(0) || oracle == address(0))
            revert ZeroAddress();

        LoanMarketConfig storage config = loanMarketConfigs[loanToken];
        if (!config.enabled) {
            loanTokens.push(loanToken);
            // Pre-approve Morpho for this loan token
            IERC20(loanToken).safeApprove(address(morpho), type(uint256).max);
        }

        config.morphoMarketId = morphoMarketId;
        config.oracle = oracle;
        config.decimals = decimals;
        config.enabled = true;

        emit LoanMarketConfigSet(loanToken, morphoMarketId);

        // Auto-assemble pair configs for all known collateral tokens
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address coll = collateralTokens[i];
            if (collateralConfigs[coll].enabled) {
                _assemblePairConfig(coll, loanToken);
            }
        }
    }

    function withdrawProtocolReserves(
        address token,
        address recipient
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 amount = protocolReserves[token];
        if (amount == 0) revert ZeroAmount();
        protocolReserves[token] = 0;
        IERC20(token).safeTransfer(recipient, amount);
    }

    /* ═══════════════════════════════════════════ POSITION MANAGEMENT ═══════════════════════════════════════════ */

    function openPosition(
        address collateralToken,
        address loanToken,
        uint256 collateralAmount,
        uint256 borrowAmount,
        address strategy
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {
        if (collateralAmount < MIN_COLLATERAL) revert ZeroAmount();
        if (borrowAmount == 0) revert ZeroAmount();

        bytes32 pairKey = _getPairKey(collateralToken, loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];
        if (!pairConfig.enabled) revert CollateralNotEnabled();

        if (!whitelistedStrategies[strategy]) revert StrategyNotWhitelisted();
        if (IStrategy(strategy).asset() != loanToken)
            revert StrategyAssetMismatch();

        // Validate max leverage: borrowAmount <= collateralValue * maxLeverage
        uint256 collateralPrice = IOracle(pairConfig.oracle).price();
        uint256 collateralValueInLoan = collateralAmount.mulDivDown(
            collateralPrice,
            ORACLE_PRICE_SCALE
        );
        uint256 maxBorrowByLeverage = collateralValueInLoan.wMulDown(
            pairConfig.maxLeverage
        );
        if (borrowAmount > maxBorrowByLeverage) revert ExceedsMaxLeverage();

        // Generate position ID
        positionId = _getPositionId(
            msg.sender,
            collateralToken,
            loanToken,
            strategy,
            userPositionIds[msg.sender].length
        );
        Position storage pos = positions[positionId];
        if (pos.active) revert PositionNotActive();

        // Transfer collateral from user
        IERC20(collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );

        // Borrow from Morpho (as uncollateralized borrower)
        MarketParams memory marketParams = morpho.idToMarketParams(
            pairConfig.morphoMarketId
        );
        (, uint256 borrowShares) = morpho.borrow(
            marketParams,
            borrowAmount,
            0,
            address(this),
            address(this)
        );

        // Deploy to strategy
        uint256 strategyShares = IStrategy(strategy).deposit(
            borrowAmount,
            address(this)
        );

        // Create position
        pos.user = msg.sender;
        pos.collateralToken = collateralToken;
        pos.loanToken = loanToken;
        pos.collateralAmount = collateralAmount.toUint128();
        pos.borrowShares = borrowShares.toUint128();
        pos.strategy = strategy;
        pos.strategyShares = strategyShares.toUint128();
        pos.lastUpdate = uint256(block.timestamp).toUint128();
        pos.active = true;

        userPositionIds[msg.sender].push(positionId);

        // Calculate leverage for event
        uint256 leverage = collateralValueInLoan > 0
            ? (borrowAmount * WAD) / collateralValueInLoan
            : 0;

        emit PositionOpened(
            positionId,
            msg.sender,
            collateralToken,
            loanToken,
            collateralAmount,
            borrowAmount,
            strategy,
            leverage
        );
    }

    function addCollateral(
        bytes32 positionId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert UnauthorizedCaller();
        if (!pos.active) revert PositionNotActive();

        IERC20(pos.collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        pos.collateralAmount += amount.toUint128();

        emit CollateralDeposited(
            positionId,
            msg.sender,
            pos.collateralToken,
            amount
        );
    }

    function withdrawCollateral(
        bytes32 positionId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert UnauthorizedCaller();
        if (!pos.active) revert PositionNotActive();
        if (pos.collateralAmount < amount) revert InsufficientCollateral();

        uint128 newCollateral = pos.collateralAmount - amount.toUint128();

        // Check position remains healthy with Morpho's formula
        if (pos.borrowShares > 0) {
            if (!_isHealthyWithCollateral(pos, newCollateral)) {
                revert PositionNotHealthy();
            }
        }

        pos.collateralAmount = newCollateral;
        IERC20(pos.collateralToken).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(
            positionId,
            msg.sender,
            pos.collateralToken,
            amount
        );
    }

    function increasePosition(
        bytes32 positionId,
        uint256 additionalBorrow
    ) external nonReentrant whenNotPaused {
        if (additionalBorrow == 0) revert ZeroAmount();

        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert UnauthorizedCaller();
        if (!pos.active) revert PositionNotActive();

        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];

        // Check leverage limit
        uint256 collateralPrice = IOracle(pairConfig.oracle).price();
        uint256 collateralValueInLoan = uint256(pos.collateralAmount)
            .mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        uint256 maxBorrowByLeverage = collateralValueInLoan.wMulDown(
            pairConfig.maxLeverage
        );

        // Get current debt
        Market memory market = morpho.market(pairConfig.morphoMarketId);
        uint256 currentDebt = uint256(pos.borrowShares).toAssetsUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );

        if (currentDebt + additionalBorrow > maxBorrowByLeverage)
            revert ExceedsMaxLeverage();

        // Also ensure position will be healthy after borrow
        // Using Morpho formula: (collateral + strategy) * price / SCALE * lltv >= newDebt
        uint256 strategyValue = IStrategy(pos.strategy).convertToAssets(
            pos.strategyShares
        );
        uint256 effectiveCollateral = pos.collateralAmount +
            _convertLoanToCollateral(pairKey, strategyValue);
        uint256 maxBorrowByHealth = effectiveCollateral
            .mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(pairConfig.lltv);

        if (currentDebt + additionalBorrow > maxBorrowByHealth)
            revert PositionNotHealthy();

        // Borrow more
        MarketParams memory marketParams = morpho.idToMarketParams(
            pairConfig.morphoMarketId
        );
        (, uint256 newShares) = morpho.borrow(
            marketParams,
            additionalBorrow,
            0,
            address(this),
            address(this)
        );

        // Deploy to strategy
        uint256 additionalStrategyShares = IStrategy(pos.strategy).deposit(
            additionalBorrow,
            address(this)
        );

        pos.borrowShares += newShares.toUint128();
        pos.strategyShares += additionalStrategyShares.toUint128();
        pos.lastUpdate = uint256(block.timestamp).toUint128();

        emit PositionIncreased(
            positionId,
            additionalBorrow,
            additionalStrategyShares
        );
    }

    function decreasePosition(
        bytes32 positionId,
        uint256 debtToRepay
    ) external nonReentrant {
        if (debtToRepay == 0) revert ZeroAmount();

        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert UnauthorizedCaller();
        if (!pos.active) revert PositionNotActive();

        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];

        MarketParams memory marketParams = morpho.idToMarketParams(
            pairConfig.morphoMarketId
        );
        Market memory market = morpho.market(pairConfig.morphoMarketId);

        // Convert desired repay to shares
        uint256 sharesToRepay = debtToRepay.toSharesUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );
        sharesToRepay = sharesToRepay < pos.borrowShares
            ? sharesToRepay
            : pos.borrowShares;

        // Calculate proportional strategy shares to withdraw
        uint256 strategySharesNeeded = (uint256(pos.strategyShares) *
            sharesToRepay) / pos.borrowShares;

        // Withdraw from strategy
        uint256 assetsReceived = IStrategy(pos.strategy).redeem(
            strategySharesNeeded,
            address(this),
            address(this)
        );

        // Repay debt
        (uint256 assetsRepaid, uint256 actualSharesRepaid) = morpho.repay(
            marketParams,
            assetsReceived,
            0,
            address(this),
            ""
        );

        pos.borrowShares -= actualSharesRepaid.toUint128();
        pos.strategyShares -= strategySharesNeeded.toUint128();
        pos.lastUpdate = uint256(block.timestamp).toUint128();

        // Return excess to user
        if (assetsReceived > assetsRepaid) {
            IERC20(pos.loanToken).safeTransfer(
                msg.sender,
                assetsReceived - assetsRepaid
            );
        }

        emit PositionDecreased(positionId, assetsRepaid, strategySharesNeeded);
    }

    function closePosition(
        bytes32 positionId
    ) external nonReentrant returns (uint256 collateralReturned, int256 pnl) {
        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert UnauthorizedCaller();
        if (!pos.active) revert PositionNotActive();

        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];

        // Withdraw all from strategy
        uint256 strategyAssets = IStrategy(pos.strategy).redeem(
            pos.strategyShares,
            address(this),
            address(this)
        );

        // Get total debt
        MarketParams memory marketParams = morpho.idToMarketParams(
            pairConfig.morphoMarketId
        );
        Market memory market = morpho.market(pairConfig.morphoMarketId);
        uint256 totalDebt = uint256(pos.borrowShares).toAssetsUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );

        // Repay debt
        uint256 assetsToRepay = strategyAssets < totalDebt
            ? strategyAssets
            : totalDebt;
        if (assetsToRepay > 0) {
            morpho.repay(marketParams, assetsToRepay, 0, address(this), "");
        }

        // Calculate PnL in loan token terms
        pnl = int256(strategyAssets) - int256(totalDebt);

        // Handle collateral return
        collateralReturned = pos.collateralAmount;

        if (pnl > 0) {
            // Profit goes to user in loan tokens
            IERC20(pos.loanToken).safeTransfer(msg.sender, uint256(pnl));
        } else if (pnl < 0) {
            // Loss: convert to collateral terms and deduct
            uint256 lossInLoan = uint256(-pnl);
            uint256 collateralPrice = IOracle(pairConfig.oracle).price();
            // lossInCollateral = lossInLoan * ORACLE_PRICE_SCALE / collateralPrice
            uint256 lossInCollateral = lossInLoan.mulDivUp(
                ORACLE_PRICE_SCALE,
                collateralPrice
            );

            if (lossInCollateral >= collateralReturned) {
                // Bad debt
                collateralReturned = 0;
            } else {
                collateralReturned -= lossInCollateral;
            }
        }

        // Return remaining collateral
        if (collateralReturned > 0) {
            IERC20(pos.collateralToken).safeTransfer(
                msg.sender,
                collateralReturned
            );
        }

        // Clear position
        pos.active = false;
        pos.collateralAmount = 0;
        pos.borrowShares = 0;
        pos.strategyShares = 0;

        emit PositionClosed(positionId, msg.sender, collateralReturned, pnl);
    }

    /* ═══════════════════════════════════════════ LIQUIDATION ═══════════════════════════════════════════ */

    function liquidate(
        bytes32 positionId,
        uint256 maxDebtToRepay
    ) external nonReentrant whenNotPaused {
        Position storage pos = positions[positionId];
        if (!pos.active) revert PositionNotActive();

        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];

        uint256 collateralPrice = IOracle(pairConfig.oracle).price();

        // Check position is NOT healthy using Morpho's formula
        if (_isHealthy(pos, pairKey, collateralPrice)) revert PositionHealthy();

        MarketParams memory marketParams = morpho.idToMarketParams(
            pairConfig.morphoMarketId
        );
        Market memory market = morpho.market(pairConfig.morphoMarketId);

        // Get total debt
        uint256 totalDebt = uint256(pos.borrowShares).toAssetsUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );

        // Determine repay amount
        uint256 debtToRepay = maxDebtToRepay == 0
            ? totalDebt
            : (maxDebtToRepay < totalDebt ? maxDebtToRepay : totalDebt);

        // Withdraw from strategy
        uint256 strategyValue = IStrategy(pos.strategy).convertToAssets(
            pos.strategyShares
        );
        uint256 strategySharesNeeded;

        if (strategyValue >= debtToRepay) {
            strategySharesNeeded = IStrategy(pos.strategy).previewWithdraw(
                debtToRepay
            );
            strategySharesNeeded = strategySharesNeeded < pos.strategyShares
                ? strategySharesNeeded
                : pos.strategyShares;
        } else {
            strategySharesNeeded = pos.strategyShares;
        }

        uint256 assetsFromStrategy = IStrategy(pos.strategy).redeem(
            strategySharesNeeded,
            address(this),
            address(this)
        );

        // Repay debt
        uint256 actualRepay = assetsFromStrategy < debtToRepay
            ? assetsFromStrategy
            : debtToRepay;
        (, uint256 sharesRepaid) = morpho.repay(
            marketParams,
            actualRepay,
            0,
            address(this),
            ""
        );

        // Calculate collateral to seize using Morpho's formula
        // seizedCollateral = repaidAssets * liquidationIncentiveFactor * SCALE / collateralPrice
        uint256 collateralToSeize = actualRepay
            .wMulDown(pairConfig.liquidationIncentiveFactor)
            .mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);

        // Cap at available collateral
        collateralToSeize = collateralToSeize < pos.collateralAmount
            ? collateralToSeize
            : pos.collateralAmount;

        // Update position
        pos.borrowShares -= sharesRepaid.toUint128();
        pos.strategyShares -= strategySharesNeeded.toUint128();
        pos.collateralAmount -= collateralToSeize.toUint128();

        // Check for bad debt
        if (pos.collateralAmount == 0 && pos.borrowShares > 0) {
            uint256 reserves = protocolReserves[pos.loanToken];
            if (reserves > 0) {
                Market memory currentMarket = morpho.market(
                    pairConfig.morphoMarketId
                );
                uint256 remainingDebt = uint256(pos.borrowShares).toAssetsUp(
                    currentMarket.totalBorrowAssets,
                    currentMarket.totalBorrowShares
                );

                if (remainingDebt > 0) {
                    uint256 amountToCover = remainingDebt > reserves
                        ? reserves
                        : remainingDebt;
                    protocolReserves[pos.loanToken] -= amountToCover;
                    morpho.repay(
                        marketParams,
                        amountToCover,
                        0,
                        address(this),
                        ""
                    );
                }
            }
            // Bad debt: clear the position
            pos.borrowShares = 0;
            pos.active = false;
        } else if (pos.borrowShares == 0) {
            pos.active = false;
        }

        // Transfer seized collateral to liquidator
        IERC20(pos.collateralToken).safeTransfer(msg.sender, collateralToSeize);

        emit PositionLiquidated(
            positionId,
            msg.sender,
            actualRepay,
            collateralToSeize,
            pairConfig.liquidationIncentiveFactor
        );
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    function getPosition(
        bytes32 positionId
    ) external view returns (Position memory) {
        return positions[positionId];
    }

    function getHealthFactor(
        bytes32 positionId
    ) external view returns (uint256) {
        Position storage pos = positions[positionId];
        if (!pos.active || pos.borrowShares == 0) return type(uint256).max;

        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];

        uint256 collateralPrice = IOracle(pairConfig.oracle).price();
        Market memory market = morpho.market(pairConfig.morphoMarketId);

        // Get borrowed amount
        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );

        // Get maxBorrow using Morpho formula
        // effective collateral includes strategy value (converted to collateral terms)
        uint256 strategyValue = IStrategy(pos.strategy).convertToAssets(
            pos.strategyShares
        );
        uint256 strategyInCollateral = strategyValue.mulDivDown(
            ORACLE_PRICE_SCALE,
            collateralPrice
        );
        uint256 effectiveCollateral = pos.collateralAmount +
            strategyInCollateral;

        uint256 maxBorrow = effectiveCollateral
            .mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(pairConfig.lltv);

        // Health factor = maxBorrow / borrowed (WAD scale)
        if (borrowed == 0) return type(uint256).max;
        return maxBorrow.wDivDown(borrowed);
    }

    function getDebtValue(bytes32 positionId) external view returns (uint256) {
        Position storage pos = positions[positionId];
        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];
        Market memory market = morpho.market(pairConfig.morphoMarketId);

        return
            uint256(pos.borrowShares).toAssetsUp(
                market.totalBorrowAssets,
                market.totalBorrowShares
            );
    }

    function getStrategyValue(
        bytes32 positionId
    ) external view returns (uint256) {
        Position storage pos = positions[positionId];
        return IStrategy(pos.strategy).convertToAssets(pos.strategyShares);
    }

    function getCollateralValue(
        bytes32 positionId
    ) external view returns (uint256) {
        Position storage pos = positions[positionId];
        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];
        uint256 collateralPrice = IOracle(pairConfig.oracle).price();
        return
            uint256(pos.collateralAmount).mulDivDown(
                collateralPrice,
                ORACLE_PRICE_SCALE
            );
    }

    function isLiquidatable(bytes32 positionId) external view returns (bool) {
        Position storage pos = positions[positionId];
        if (!pos.active || pos.borrowShares == 0) return false;

        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];
        uint256 collateralPrice = IOracle(pairConfig.oracle).price();

        return !_isHealthy(pos, pairKey, collateralPrice);
    }

    function getMaxBorrowable(
        address collateralToken,
        address loanToken,
        uint256 collateralAmount
    ) external view returns (uint256) {
        bytes32 pairKey = _getPairKey(collateralToken, loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];
        if (!pairConfig.enabled) return 0;

        uint256 collateralPrice = IOracle(pairConfig.oracle).price();
        uint256 collateralValueInLoan = collateralAmount.mulDivDown(
            collateralPrice,
            ORACLE_PRICE_SCALE
        );
        return collateralValueInLoan.wMulDown(pairConfig.maxLeverage);
    }

    function isWhitelistedStrategy(
        address strategy
    ) external view returns (bool) {
        return whitelistedStrategies[strategy];
    }

    function getUserPositions(
        address user
    ) external view returns (bytes32[] memory) {
        return userPositionIds[user];
    }

    function getPairConfig(
        address collateralToken,
        address loanToken
    ) external view returns (MarginPairConfig memory) {
        return pairConfigs[_getPairKey(collateralToken, loanToken)];
    }

    /* ═══════════════════════════════════════════ INTERNAL FUNCTIONS ═══════════════════════════════════════════ */

    function _getPairKey(
        address collateralToken,
        address loanToken
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(collateralToken, loanToken));
    }

    function _getPositionId(
        address user,
        address collateralToken,
        address loanToken,
        address strategy,
        uint256 index
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    user,
                    collateralToken,
                    loanToken,
                    strategy,
                    index
                )
            );
    }

    /// @notice Morpho's exact health check formula
    /// @dev Position healthy if: effectiveCollateral * price / SCALE * lltv >= borrowed
    function _isHealthy(
        Position storage pos,
        bytes32 pairKey,
        uint256 collateralPrice
    ) internal view returns (bool) {
        if (pos.borrowShares == 0) return true;

        MarginPairConfig storage pairConfig = pairConfigs[pairKey];
        Market memory market = morpho.market(pairConfig.morphoMarketId);

        // Get borrowed amount (rounds up, favoring protocol)
        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );

        // Calculate effective collateral (user collateral + strategy value in collateral terms)
        uint256 strategyValue = IStrategy(pos.strategy).convertToAssets(
            pos.strategyShares
        );
        uint256 strategyInCollateral = strategyValue.mulDivDown(
            ORACLE_PRICE_SCALE,
            collateralPrice
        );
        uint256 effectiveCollateral = pos.collateralAmount +
            strategyInCollateral;

        // maxBorrow = effectiveCollateral * collateralPrice / ORACLE_PRICE_SCALE * lltv
        // (rounds down, favoring protocol)
        uint256 maxBorrow = effectiveCollateral
            .mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(pairConfig.lltv);

        return maxBorrow >= borrowed;
    }

    /// @notice Check health with a hypothetical collateral amount
    function _isHealthyWithCollateral(
        Position storage pos,
        uint128 newCollateral
    ) internal view returns (bool) {
        bytes32 pairKey = _getPairKey(pos.collateralToken, pos.loanToken);
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];

        uint256 collateralPrice = IOracle(pairConfig.oracle).price();
        Market memory market = morpho.market(pairConfig.morphoMarketId);

        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );

        uint256 strategyValue = IStrategy(pos.strategy).convertToAssets(
            pos.strategyShares
        );
        uint256 strategyInCollateral = strategyValue.mulDivDown(
            ORACLE_PRICE_SCALE,
            collateralPrice
        );
        uint256 effectiveCollateral = newCollateral + strategyInCollateral;

        uint256 maxBorrow = effectiveCollateral
            .mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(pairConfig.lltv);

        return maxBorrow >= borrowed;
    }

    /// @notice Convert loan token amount to collateral token amount
    function _convertLoanToCollateral(
        bytes32 pairKey,
        uint256 loanAmount
    ) internal view returns (uint256) {
        MarginPairConfig storage pairConfig = pairConfigs[pairKey];
        uint256 collateralPrice = IOracle(pairConfig.oracle).price();
        // collateral = loan * SCALE / price
        return loanAmount.mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
    }

    /// @notice Calculate liquidation incentive factor (same as Morpho)
    /// @dev liquidationIncentiveFactor = min(MAX_FACTOR, WAD / (WAD - CURSOR * (WAD - lltv)))
    function _liquidationIncentiveFactor(
        uint256 lltv
    ) internal pure returns (uint256) {
        return
            UtilsLib.min(
                MAX_LIQUIDATION_INCENTIVE_FACTOR,
                WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - lltv))
            );
    }

    /// @notice Assemble a MarginPairConfig from per-token collateral and loan configs
    /// @dev Called automatically when both sides of a pair are configured
    function _assemblePairConfig(
        address collateralToken,
        address loanToken
    ) internal {
        CollateralConfig storage collConfig = collateralConfigs[
            collateralToken
        ];
        LoanMarketConfig storage loanConfig = loanMarketConfigs[loanToken];

        bytes32 pairKey = _getPairKey(collateralToken, loanToken);
        MarginPairConfig storage pair = pairConfigs[pairKey];

        // First time enabling this pair: approve Morpho for the loan token
        if (!pair.enabled) {
            IERC20(loanToken).safeApprove(address(morpho), type(uint256).max);
        }

        // Use the collateral oracle (returns collateral price in loan token terms)
        pair.oracle = collConfig.oracle;
        pair.morphoMarketId = loanConfig.morphoMarketId;
        // Derive LLTV from liquidation threshold (they map to the same concept)
        pair.lltv = collConfig.liquidationThreshold;
        pair.maxLeverage = collConfig.maxLeverage;
        // Calculate liquidation incentive factor from lltv
        pair.liquidationIncentiveFactor = _liquidationIncentiveFactor(
            pair.lltv
        );
        pair.enabled = true;
    }
}
