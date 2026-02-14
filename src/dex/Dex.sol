// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, Market, IMorpho} from "../interfaces/IMorpho.sol";
import {IIrm} from "../interfaces/IIrm.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {MarketParamsLib} from "../libraries/MarketParamsLib.sol";
import {MathLib, WAD} from "../libraries/MathLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {UtilsLib} from "../libraries/UtilsLib.sol";

/// @title Dex
/// @notice Credit-based DEX leveraging Morpho uncollateralized lending for instant swaps
/// @dev Swaps are executed immediately via borrowing; settled when counterparty arrives
contract Dex {
    using MathLib for uint256;
    using MathLib for uint128;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;
    using UtilsLib for uint256;

    /* ═══════════════════════════════════════════ CONSTANTS ═══════════════════════════════════════════ */

    uint256 public constant WAD_UNIT = 1e18;
    uint256 public constant BASE_FEE_BPS = 30; // 0.30%
    uint256 public constant MAX_FEE_BPS = 100; // 1.00%
    uint256 public constant BPS_SCALE = 10000;
    uint256 public constant INTEREST_BUFFER = 1.5e18; // 1.5x multiplier
    uint256 public constant EWMA_ALPHA = 0.1e18; // Smoothing factor for match time
    uint256 public constant DEFAULT_MATCH_TIME = 1 hours;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36; // Morpho oracle price scale
    uint256 public constant MIN_LP_DEPOSIT = 1000; // Minimum LP deposit to prevent inflation attack
    uint256 public constant PROTOCOL_FEE_BPS = 1000; // 10% of LP fees go to protocol

    /* ═══════════════════════════════════════════ IMMUTABLES ═══════════════════════════════════════════ */

    IMorpho public immutable morpho;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    address public owner;
    bool public paused;
    uint256 private _locked = 1; // Reentrancy guard (1 = unlocked, 2 = locked)

    // Allocation percentages (must sum to 100)
    uint256 public supplyAllocation = 50;
    uint256 public repayAllocation = 25;
    uint256 public liquidityAllocation = 25;

    /* ═══════════════════════════════════════════ TOKEN STATE ═══════════════════════════════════════════ */

    struct TokenState {
        Id[] marketIds; // Whitelisted uncollateralized markets for this token
        uint256 morphoSupplyShares; // DEX's supply shares in primary Morpho market
        uint256 localLiquidity; // Buffer held in DEX for instant swaps (excludes held balances)
        uint256 totalHeldBalance; // Total held balance across all pairs (reserved for reverse swaps)
        uint256 totalBorrowed; // Cumulative borrowed from Morpho
        uint256 totalRepaid; // Cumulative repaid to Morpho
        uint256 totalLPDeposits; // Total LP deposits
        // Fee tracking (per token, collected from fees in this token)
        uint256 lpFeeReserve; // Fees earned by LPs
        uint256 interestReserve; // Fees to cover Morpho interest costs
        uint256 protocolFees; // Protocol's withholding cut
    }

    mapping(address token => TokenState) public tokenState;
    mapping(Id marketId => bool) public isWhitelistedMarket;
    mapping(Id marketId => address) public marketToToken;

    /// @notice Per-market borrow shares tracking (for multi-market repayment)
    mapping(address token => mapping(Id marketId => uint256))
        public marketBorrowShares;

    /// @notice Oracle for each trading pair (tokenIn => tokenOut => oracle)
    /// @dev Oracle returns price of tokenIn in terms of tokenOut, scaled by 1e36
    mapping(address tokenIn => mapping(address tokenOut => address))
        public pairOracle;

    /// @notice Whitelist of trading pairs that can be swapped
    mapping(address tokenIn => mapping(address tokenOut => bool))
        public isWhitelistedPair;

    /* ═══════════════════════════════════════════ LP STATE ═══════════════════════════════════════════ */

    struct LPPosition {
        uint256 shares;
        uint256 depositTimestamp;
    }

    mapping(address token => mapping(address lp => LPPosition))
        public lpPositions;
    mapping(address token => uint256) public totalLPShares;

    /* ═══════════════════════════════════════════ PAIR STATE ═══════════════════════════════════════════ */

    struct PairState {
        uint256 heldBalance; // TokenIn accumulated from forward swaps
        uint256 outstandingDebt; // TokenOut borrowed (principal)
        uint256 debtTimestamp; // Last debt update for interest approximation
        uint256 expectedMatchTime; // EWMA of actual match times
        uint256 totalSwaps; // Count for EWMA calculation
        int256 imbalance; // positive = need reverse swaps
    }

    mapping(bytes32 pairId => PairState) public pairState;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event MarketWhitelisted(Id indexed marketId, address indexed token);
    event MarketRemoved(Id indexed marketId);
    event PairOracleSet(
        address indexed tokenIn,
        address indexed tokenOut,
        address oracle
    );
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
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event PausedSet(bool paused);
    event PairWhitelisted(address indexed tokenIn, address indexed tokenOut);
    event PairDelisted(address indexed tokenIn, address indexed tokenOut);

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error MarketNotWhitelisted();
    error MarketAlreadyWhitelisted();
    error InsufficientLiquidity();
    error InsufficientShares();
    error SlippageExceeded();
    error InvalidAllocation();
    error NoMarketAvailable();
    error InsufficientLocalLiquidity();
    error OracleNotSet();
    error InvalidOracle();
    error Paused();
    error Reentrancy();
    error DepositTooSmall();
    error PairNotWhitelisted();
    error MarketHasActivePosition();

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
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Whitelist an uncollateralized market for a token
    function whitelistMarket(Id marketId) external onlyOwner {
        if (isWhitelistedMarket[marketId]) revert MarketAlreadyWhitelisted();

        MarketParams memory params = morpho.idToMarketParams(marketId);
        address token = params.loanToken;

        isWhitelistedMarket[marketId] = true;
        marketToToken[marketId] = token;
        tokenState[token].marketIds.push(marketId);

        // Approve Morpho to spend token
        IERC20(token).safeApprove(address(morpho), type(uint256).max);

        emit MarketWhitelisted(marketId, token);
    }

    /// @notice Remove a market from whitelist
    /// @dev Reverts if there are active borrow shares or if removing primary market with supply shares
    function removeMarket(Id marketId) external onlyOwner {
        if (!isWhitelistedMarket[marketId]) revert MarketNotWhitelisted();

        address token = marketToToken[marketId];
        TokenState storage state = tokenState[token];

        // Critical: Cannot remove market with active borrow shares (would orphan debt)
        if (marketBorrowShares[token][marketId] > 0)
            revert MarketHasActivePosition();

        // Critical: Cannot remove primary market if it has supply shares
        if (
            state.marketIds.length > 0 &&
            Id.unwrap(state.marketIds[0]) == Id.unwrap(marketId) &&
            state.morphoSupplyShares > 0
        ) {
            revert MarketHasActivePosition();
        }

        isWhitelistedMarket[marketId] = false;
        delete marketToToken[marketId];

        // Remove from array
        Id[] storage markets = state.marketIds;
        for (uint256 i = 0; i < markets.length; i++) {
            if (Id.unwrap(markets[i]) == Id.unwrap(marketId)) {
                markets[i] = markets[markets.length - 1];
                markets.pop();
                break;
            }
        }

        emit MarketRemoved(marketId);
    }

    /// @notice Set allocation percentages for LP deposits
    function setAllocation(
        uint256 supply,
        uint256 repay,
        uint256 liquidity
    ) external onlyOwner {
        if (supply + repay + liquidity != 100) revert InvalidAllocation();
        supplyAllocation = supply;
        repayAllocation = repay;
        liquidityAllocation = liquidity;
        emit AllocationUpdated(supply, repay, liquidity);
    }

    /// @notice Reallocate funds between local liquidity and Morpho supply
    function reallocate(
        address token,
        int256 deltaToMorpho
    ) external onlyOwner {
        TokenState storage state = tokenState[token];

        if (deltaToMorpho > 0) {
            // Move from local to Morpho
            uint256 amount = uint256(deltaToMorpho);
            if (state.localLiquidity < amount)
                revert InsufficientLocalLiquidity();
            state.localLiquidity -= amount;
            _supplyToMorpho(token, amount);
        } else if (deltaToMorpho < 0) {
            // Move from Morpho to local
            uint256 amount = uint256(-deltaToMorpho);
            _withdrawFromMorpho(token, amount);
            state.localLiquidity += amount;
        }

        emit Reallocation(token, deltaToMorpho);
    }

    /// @notice Set oracle for a trading pair
    /// @param tokenIn The input token (what user deposits)
    /// @param tokenOut The output token (what user receives)
    /// @param oracle The oracle address that returns price of tokenIn in tokenOut terms
    function setPairOracle(
        address tokenIn,
        address tokenOut,
        address oracle
    ) external onlyOwner {
        if (oracle == address(0)) revert InvalidOracle();
        pairOracle[tokenIn][tokenOut] = oracle;
        emit PairOracleSet(tokenIn, tokenOut, oracle);
    }

    /// @notice Pause/unpause the contract
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Whitelist a trading pair to allow swaps
    function whitelistPair(
        address tokenIn,
        address tokenOut
    ) external onlyOwner {
        if (tokenIn == address(0) || tokenOut == address(0))
            revert ZeroAddress();
        isWhitelistedPair[tokenIn][tokenOut] = true;
        emit PairWhitelisted(tokenIn, tokenOut);
    }

    /// @notice Remove a trading pair from whitelist
    function delistPair(address tokenIn, address tokenOut) external onlyOwner {
        isWhitelistedPair[tokenIn][tokenOut] = false;
        emit PairDelisted(tokenIn, tokenOut);
    }

    /// @notice Withdraw protocol fees (withholding) for a specific token
    function withdrawProtocolFees(
        address token,
        address recipient
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        TokenState storage state = tokenState[token];

        uint256 fees = state.protocolFees;
        if (fees == 0) revert ZeroAmount();
        state.protocolFees = 0;

        IERC20(token).safeTransfer(recipient, fees);
    }

    /* ═══════════════════════════════════════════ LP FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Deposit liquidity for a token
    function depositLP(
        address token,
        uint256 amount
    ) external whenNotPaused nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_LP_DEPOSIT) revert DepositTooSmall();
        TokenState storage state = tokenState[token];
        if (state.marketIds.length == 0) revert NoMarketAvailable();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate split
        uint256 toSupply;
        uint256 toRepay;
        uint256 toLiquidity;

        if (_hasAnyBorrowShares(token)) {
            // Has outstanding loans - use configured allocation
            toSupply = (amount * supplyAllocation) / 100;
            toRepay = (amount * repayAllocation) / 100;
            toLiquidity = amount - toSupply - toRepay;
        } else {
            // No loans - split between supply and liquidity
            toSupply = (amount * 66) / 100;
            toLiquidity = amount - toSupply;
        }

        // Calculate shares BEFORE modifying state (issue 4)
        uint256 totalAssetsBefore = _getTotalAssets(token);
        if (totalLPShares[token] == 0) {
            shares = amount;
        } else {
            shares = (amount * totalLPShares[token]) / totalAssetsBefore;
        }

        // Execute allocations
        if (toSupply > 0) {
            _supplyToMorpho(token, toSupply);
        }
        if (toRepay > 0 && _hasAnyBorrowShares(token)) {
            uint256 actualRepaid = _repayMorpho(token, toRepay);
            // If couldn't repay full amount, add remainder to liquidity
            toLiquidity += toRepay - actualRepaid;
        }
        state.localLiquidity += toLiquidity;
        state.totalLPDeposits += amount;

        lpPositions[token][msg.sender].shares += shares;
        lpPositions[token][msg.sender].depositTimestamp = block.timestamp;
        totalLPShares[token] += shares;

        emit LPDeposit(token, msg.sender, amount, shares);
    }

    /// @notice Withdraw LP position
    function withdrawLP(
        address token,
        uint256 shares
    ) external nonReentrant returns (uint256 amount) {
        LPPosition storage pos = lpPositions[token][msg.sender];
        if (pos.shares < shares) revert InsufficientShares();

        TokenState storage state = tokenState[token];

        // Pro-rata share of total assets
        uint256 totalAssets = _getTotalAssets(token);
        amount = (shares * totalAssets) / totalLPShares[token];

        // Source funds: local first, then LP fees, then withdraw from Morpho
        uint256 remaining = amount;
        uint256 fromLocal = _min(remaining, state.localLiquidity);
        state.localLiquidity -= fromLocal;
        remaining -= fromLocal;

        // Use LP fee reserve (these belong to LPs)
        uint256 fromFees = _min(remaining, state.lpFeeReserve);
        state.lpFeeReserve -= fromFees;
        remaining -= fromFees;

        // Finally withdraw from Morpho supply
        if (remaining > 0) {
            _withdrawFromMorpho(token, remaining);
        }

        pos.shares -= shares;
        totalLPShares[token] -= shares;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit LPWithdraw(token, msg.sender, shares, amount);
    }

    /* ═══════════════════════════════════════════ SWAP FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Execute a swap
    /// @param tokenIn The token the user deposits
    /// @param tokenOut The token the user receives
    /// @param amountIn The amount of tokenIn to swap
    /// @param minAmountOut Minimum amount of tokenOut to receive (slippage protection)
    /// @param isReverse If false: forward swap (borrow tokenOut, hold tokenIn)
    ///                  If true: reverse swap (repay debt with tokenIn, release held tokenOut)
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bool isReverse
    ) external whenNotPaused nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (!isWhitelistedPair[tokenIn][tokenOut]) revert PairNotWhitelisted();

        // Get oracle price based on direction
        // Forward: tokenIn→tokenOut, Reverse: tokenIn→tokenOut (same oracle lookup)
        address oracle = pairOracle[tokenIn][tokenOut];
        if (oracle == address(0)) revert OracleNotSet();
        uint256 price = IOracle(oracle).price();

        // Calculate fee
        uint256 fee = _calculateFee(tokenIn, tokenOut, amountIn, !isReverse);
        uint256 amountInAfterFee = amountIn - fee;

        // Convert using oracle price
        // Oracle gives price of tokenIn in tokenOut (e.g., 1 ETH = 2000 USDC)
        // Forward: amountOut = amountIn * price / scale (ETH→USDC: more out)
        // Reverse: amountOut = amountIn * scale / price (USDC→ETH: less out)
        if (isReverse) {
            amountOut = (amountInAfterFee * ORACLE_PRICE_SCALE) / price;
        } else {
            amountOut = (amountInAfterFee * price) / ORACLE_PRICE_SCALE;
        }
        if (amountOut < minAmountOut) revert SlippageExceeded();

        // Pair ID is always the same regardless of direction
        // tokenIn/tokenOut define the trading pair, isReverse determines the direction
        bytes32 pairId = _getPairId(tokenIn, tokenOut);

        // Execute the appropriate swap type
        if (isReverse) {
            _executeReverseSwap(
                pairId,
                tokenIn,
                tokenOut,
                amountIn,
                amountOut,
                fee
            );
        } else {
            _executeForwardSwap(
                pairId,
                tokenIn,
                tokenOut,
                amountIn,
                amountOut,
                fee
            );
        }

        emit Swap(
            tokenIn,
            tokenOut,
            msg.sender,
            amountIn,
            amountOut,
            fee,
            !isReverse
        );
    }

    /// @dev Forward swap: User deposits tokenIn, receives tokenOut
    /// @dev Liquidity priority: local → Morpho supply withdrawal → Morpho borrow
    /// @dev heldBalance stores tokenIn, outstandingDebt is in tokenOut
    function _executeForwardSwap(
        bytes32 pairId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    ) internal {
        PairState storage pair = pairState[pairId];
        TokenState storage outState = tokenState[tokenOut];

        // Take input token and add to held balance (NOT localLiquidity - held is reserved for reverse swaps)
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 heldAmount = amountIn - fee;
        pair.heldBalance += heldAmount;
        tokenState[tokenIn].totalHeldBalance += heldAmount;

        // Source output token in order: local → Morpho supply → borrow
        uint256 remaining = amountOut;
        uint256 fromLocal = 0;
        uint256 fromMorphoSupply = 0;
        uint256 fromBorrow = 0;

        // 1. Use local liquidity first
        if (remaining > 0 && outState.localLiquidity > 0) {
            fromLocal = _min(remaining, outState.localLiquidity);
            outState.localLiquidity -= fromLocal;
            remaining -= fromLocal;
        }

        // 2. Withdraw from Morpho supply if needed
        if (remaining > 0 && outState.morphoSupplyShares > 0) {
            // Get max withdrawable
            Id marketId = outState.marketIds[0];
            Market memory market = morpho.market(marketId);
            uint256 maxWithdraw = outState.morphoSupplyShares.toAssetsDown(
                market.totalSupplyAssets,
                market.totalSupplyShares
            );
            fromMorphoSupply = _min(remaining, maxWithdraw);
            if (fromMorphoSupply > 0) {
                _withdrawFromMorpho(tokenOut, fromMorphoSupply);
                remaining -= fromMorphoSupply;
            }
        }

        // 3. Borrow from Morpho as last resort
        if (remaining > 0) {
            fromBorrow = remaining;
            _borrowFromMorpho(tokenOut, fromBorrow);
            pair.outstandingDebt += fromBorrow;
            pair.debtTimestamp = block.timestamp;
            outState.totalBorrowed += fromBorrow;
        }

        // Distribute fees based on liquidity source (fees collected in tokenIn)
        TokenState storage feeTokenState = tokenState[tokenIn];
        uint256 fromLPLiquidity = fromLocal + fromMorphoSupply; // LP-provided liquidity

        if (fee > 0) {
            // Protocol always takes its cut from all fees
            uint256 protocolCut = (fee * PROTOCOL_FEE_BPS) / BPS_SCALE;
            uint256 remainingFee = fee - protocolCut;
            feeTokenState.protocolFees += protocolCut;

            if (fromLPLiquidity > 0) {
                // Split remaining fee between LP and interest based on liquidity source ratio
                uint256 lpFeePortion = (remainingFee * fromLPLiquidity) /
                    amountOut;
                feeTokenState.lpFeeReserve += lpFeePortion;
                feeTokenState.interestReserve += (remainingFee - lpFeePortion);
            } else {
                // All remaining fees go to interest reserve when using only borrowed funds
                feeTokenState.interestReserve += remainingFee;
            }
        }

        // Update imbalance (positive = need reverse swaps to settle)
        pair.imbalance += int256(amountOut);

        // Send output to user
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @dev Reverse swap: User deposits tokenOut (repays debt), receives tokenIn (from held balance)
    /// @dev For pair (tokenIn, tokenOut): heldBalance is tokenIn, outstandingDebt is tokenOut
    function _executeReverseSwap(
        bytes32 pairId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn, // Amount of tokenOut user deposits
        uint256 amountOut, // Amount of tokenIn user receives
        uint256 fee
    ) internal {
        PairState storage pair = pairState[pairId];

        // In reverse: user deposits tokenOut, receives tokenIn
        // heldBalance is in tokenIn, debt is in tokenOut

        // Check we have held balance (tokenIn) to give
        if (pair.heldBalance < amountOut) revert InsufficientLiquidity();

        // Take user's tokenOut (what they're depositing to repay the debt)
        IERC20(tokenOut).safeTransferFrom(msg.sender, address(this), amountIn);

        // Use tokenOut to repay debt (debt is in tokenOut)
        TokenState storage debtTokenState = tokenState[tokenOut];
        uint256 netAmount = amountIn - fee;

        if (pair.outstandingDebt > 0) {
            uint256 repayAmount = _min(netAmount, pair.outstandingDebt);
            uint256 actualRepaid = _repayMorpho(tokenOut, repayAmount);
            pair.outstandingDebt -= actualRepaid;
            debtTokenState.totalRepaid += actualRepaid;

            // Remainder goes to local liquidity
            debtTokenState.localLiquidity += (netAmount - actualRepaid);
        } else {
            debtTokenState.localLiquidity += netAmount;
        }

        // Update match time EWMA
        if (pair.debtTimestamp > 0) {
            uint256 matchTime = block.timestamp - pair.debtTimestamp;
            _updateMatchTimeEWMA(pairId, matchTime);
        }

        // Update imbalance (reduces the need for reverse swaps)
        pair.imbalance -= int256(netAmount);

        // Release held balance (tokenIn) to user - update totalHeldBalance not localLiquidity
        pair.heldBalance -= amountOut;
        tokenState[tokenIn].totalHeldBalance -= amountOut;

        // Distribute fee - reverse swaps use LP's held balance, fees collected in tokenOut
        // (user deposits tokenOut, so that's where the fee comes from)
        TokenState storage feeTokenState = tokenState[tokenOut];
        uint256 protocolCut = (fee * PROTOCOL_FEE_BPS) / BPS_SCALE;
        feeTokenState.protocolFees += protocolCut;
        feeTokenState.lpFeeReserve += (fee - protocolCut);

        // Send tokenIn to user
        IERC20(tokenIn).safeTransfer(msg.sender, amountOut);
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Get quote for a swap
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool isReverse
    ) external view returns (uint256 amountOut, uint256 fee) {
        address oracle = pairOracle[tokenIn][tokenOut];
        if (oracle == address(0)) return (0, 0); // No oracle set

        uint256 price = IOracle(oracle).price();
        fee = _calculateFee(tokenIn, tokenOut, amountIn, !isReverse);
        uint256 amountInAfterFee = amountIn - fee;

        if (isReverse) {
            amountOut = (amountInAfterFee * ORACLE_PRICE_SCALE) / price;
        } else {
            amountOut = (amountInAfterFee * price) / ORACLE_PRICE_SCALE;
        }
    }

    /// @notice Get total assets for a token (local + morpho supply - morpho borrow)
    function getTotalAssets(address token) external view returns (uint256) {
        return _getTotalAssets(token);
    }

    /// @notice Get LP position value
    function getLPValue(
        address token,
        address lp
    ) external view returns (uint256) {
        uint256 shares = lpPositions[token][lp].shares;
        if (shares == 0 || totalLPShares[token] == 0) return 0;
        return (shares * _getTotalAssets(token)) / totalLPShares[token];
    }

    /// @notice Get pair status
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
        )
    {
        bytes32 pId = _getPairId(tokenIn, tokenOut);
        PairState storage pair = pairState[pId];
        return (
            pair.heldBalance,
            pair.outstandingDebt,
            pair.imbalance,
            pair.expectedMatchTime
        );
    }

    /// @notice Get available liquidity for borrowing
    function getAvailableLiquidity(
        address token
    ) external view returns (uint256 local, uint256 morphoLiquidity) {
        TokenState storage state = tokenState[token];
        local = state.localLiquidity;

        // Check Morpho market liquidity
        if (state.marketIds.length > 0) {
            Id marketId = state.marketIds[0];
            Market memory market = morpho.market(marketId);
            morphoLiquidity = market.totalSupplyAssets > market.totalBorrowAssets ? market.totalSupplyAssets - market.totalBorrowAssets : 0;
        }
    }

    function getMarkets(address token) external view returns (Id[] memory) {
        return tokenState[token].marketIds;
    }

    /* ═══════════════════════════════════════════ INTERNAL FUNCTIONS ═══════════════════════════════════════════ */

    function _calculateFee(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool isTaker
    ) internal view returns (uint256) {
        bytes32 pId = _getPairId(tokenIn, tokenOut);
        PairState storage pair = pairState[pId];

        // Base fee
        uint256 feeBps = BASE_FEE_BPS;

        // Add interest cost estimate for takers
        if (isTaker) {
            uint256 interestCost = _estimateInterestCost(
                tokenOut,
                amount,
                pair.expectedMatchTime
            );
            uint256 interestBps = (interestCost * BPS_SCALE) / amount;
            feeBps += (interestBps * INTEREST_BUFFER) / WAD_UNIT;
        }

        // Dynamic adjustment based on imbalance
        int256 imb = pair.imbalance;
        uint256 imbalanceBps = _abs(imb) / 1e18; // Scale down
        imbalanceBps = _min(imbalanceBps, 20); // Cap at 20 bps adjustment

        if (imb > 0 && !isTaker) {
            // Need fillers → discount for fillers
            feeBps = feeBps > imbalanceBps ? feeBps - imbalanceBps : 0;
        } else if (imb < 0 && isTaker) {
            // Need takers → discount for takers
            feeBps = feeBps > imbalanceBps ? feeBps - imbalanceBps : 0;
        } else if (imb > 0 && isTaker) {
            // Excess takers → premium for takers
            feeBps += imbalanceBps;
        } else if (imb < 0 && !isTaker) {
            // Excess fillers → premium for fillers
            feeBps += imbalanceBps;
        }

        // Cap at max
        feeBps = _min(feeBps, MAX_FEE_BPS);

        return (amount * feeBps) / BPS_SCALE;
    }

    function _estimateInterestCost(
        address token,
        uint256 amount,
        uint256 matchTime
    ) internal view returns (uint256) {
        TokenState storage state = tokenState[token];
        if (state.marketIds.length == 0) return 0;

        Id marketId = state.marketIds[0];
        MarketParams memory params = morpho.idToMarketParams(marketId);

        if (params.irm == address(0)) return 0;

        uint256 effectiveMatchTime = matchTime > 0
            ? matchTime
            : DEFAULT_MATCH_TIME;

        // Get borrow rate
        Market memory market = morpho.market(marketId);
        uint256 borrowRate = IIrm(params.irm).borrowRateView(params, market);

        // Interest = amount * rate * time
        return amount.wMulDown(borrowRate.wMulDown(effectiveMatchTime));
    }

    function _updateMatchTimeEWMA(bytes32 pId, uint256 actualTime) internal {
        PairState storage pair = pairState[pId];
        if (pair.expectedMatchTime == 0) {
            pair.expectedMatchTime = actualTime;
        } else {
            pair.expectedMatchTime =
                (EWMA_ALPHA *
                    actualTime +
                    (WAD_UNIT - EWMA_ALPHA) *
                    pair.expectedMatchTime) /
                WAD_UNIT;
        }
        pair.totalSwaps++;
    }

    function _supplyToMorpho(address token, uint256 amount) internal {
        TokenState storage state = tokenState[token];
        if (state.marketIds.length == 0) return;

        Id marketId = state.marketIds[0];
        MarketParams memory params = morpho.idToMarketParams(marketId);

        (, uint256 shares) = morpho.supply(
            params,
            amount,
            0,
            address(this),
            ""
        );
        state.morphoSupplyShares += shares;
    }

    function _withdrawFromMorpho(address token, uint256 amount) internal {
        TokenState storage state = tokenState[token];
        if (state.morphoSupplyShares == 0) return;

        Id marketId = state.marketIds[0];
        MarketParams memory params = morpho.idToMarketParams(marketId);

        (, uint256 sharesUsed) = morpho.withdraw(
            params,
            amount,
            0,
            address(this),
            address(this)
        );
        state.morphoSupplyShares -= sharesUsed;
    }

    function _borrowFromMorpho(
        address token,
        uint256 amount
    ) internal returns (Id borrowedMarketId) {
        TokenState storage state = tokenState[token];
        if (state.marketIds.length == 0) revert NoMarketAvailable();

        borrowedMarketId = _findMarketWithLiquidity(token, amount);
        MarketParams memory params = morpho.idToMarketParams(borrowedMarketId);

        (, uint256 shares) = morpho.borrow(
            params,
            amount,
            0,
            address(this),
            address(this)
        );

        // Track per-market borrow shares
        marketBorrowShares[token][borrowedMarketId] += shares;
    }

    function _repayMorpho(
        address token,
        uint256 amount
    ) internal returns (uint256 actualRepaid) {
        TokenState storage state = tokenState[token];
        if (state.marketIds.length == 0) return 0;

        // Use interest reserve to boost repayment - these are fee tokens already in the contract
        uint256 reserveUsed = 0;
        uint256 totalToRepay = amount;
        if (state.interestReserve > 0) {
            // Interest reserve tokens are already held by contract, add them to repay amount
            reserveUsed = state.interestReserve;
            totalToRepay += reserveUsed;
        }

        uint256 remainingToRepay = totalToRepay;

        // Iterate through markets and repay where we have borrow shares
        for (
            uint256 i = 0;
            i < state.marketIds.length && remainingToRepay > 0;
            i++
        ) {
            Id marketId = state.marketIds[i];
            uint256 borrowShares = marketBorrowShares[token][marketId];
            if (borrowShares == 0) continue;

            MarketParams memory params = morpho.idToMarketParams(marketId);
            Market memory market = morpho.market(marketId);

            // Calculate max repayable for this market
            uint256 maxRepay = borrowShares.toAssetsUp(
                market.totalBorrowAssets,
                market.totalBorrowShares
            );
            uint256 toRepay = _min(remainingToRepay, maxRepay);

            if (toRepay > 0) {
                (, uint256 sharesRepaid) = morpho.repay(
                    params,
                    toRepay,
                    0,
                    address(this),
                    ""
                );
                marketBorrowShares[token][marketId] -= sharesRepaid;
                actualRepaid += toRepay;
                remainingToRepay -= toRepay;
            }
        }

        // Only deduct the portion of reserve that was actually used
        // actualRepaid is what we spent; if it's less than totalToRepay, we have unused reserve
        uint256 actuallyUsedFromReserve = reserveUsed > 0
            ? _min(
                reserveUsed,
                actualRepaid > amount ? actualRepaid - amount : 0
            ) + (actualRepaid <= amount ? 0 : 0)
            : 0;

        // Simpler logic: if we repaid less than totalToRepay, return unused to reserve
        if (actualRepaid < totalToRepay && reserveUsed > 0) {
            uint256 unused = totalToRepay - actualRepaid;
            // The unused portion comes from the reserve we added
            uint256 unusedFromReserve = _min(unused, reserveUsed);
            state.interestReserve = unusedFromReserve;
        } else if (reserveUsed > 0) {
            // We used all the reserve
            state.interestReserve = 0;
        }
    }

    function _findMarketWithLiquidity(
        address token,
        uint256 amount
    ) internal view returns (Id) {
        Id[] storage markets = tokenState[token].marketIds;

        for (uint256 i = 0; i < markets.length; i++) {
            Id marketId = markets[i];
            Market memory market = morpho.market(marketId);
            uint256 available = market.totalSupplyAssets > market.totalBorrowAssets
                ? market.totalSupplyAssets - market.totalBorrowAssets
                : 0;
            if (available >= amount) {
                return marketId;
            }
        }
        revert InsufficientLiquidity();
    }

    function _getTotalAssets(address token) internal view returns (uint256) {
        TokenState storage state = tokenState[token];

        uint256 supplyValue = 0;

        if (state.marketIds.length > 0) {
            Id marketId = state.marketIds[0];
            Market memory market = morpho.market(marketId);

            if (state.morphoSupplyShares > 0) {
                supplyValue = state.morphoSupplyShares.toAssetsDown(
                    market.totalSupplyAssets,
                    market.totalSupplyShares
                );
            }
        }

        // LP total assets = localLiquidity + Morpho supply + LP fees
        // Note: totalHeldBalance is NOT included - those are swap deposits, not LP deposits
        // Note: morpho borrows are protocol costs covered by interest reserve, not LP liability
        return state.localLiquidity + supplyValue + state.lpFeeReserve;
    }

    function _getPairId(
        address tokenA,
        address tokenB
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenA, tokenB));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _hasAnyBorrowShares(address token) internal view returns (bool) {
        Id[] storage markets = tokenState[token].marketIds;
        for (uint256 i = 0; i < markets.length; i++) {
            if (marketBorrowShares[token][markets[i]] > 0) {
                return true;
            }
        }
        return false;
    }
}
