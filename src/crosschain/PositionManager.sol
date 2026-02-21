// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, IMorpho} from "../interfaces/IMorpho.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ICrossChainAdapter} from "../interfaces/ICrossChainAdapter.sol";
import {CrossChainTypes} from "../interfaces/CrossChainTypes.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MathLib, WAD} from "../libraries/MathLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {UtilsLib} from "../libraries/UtilsLib.sol";

/// @title PositionManager
/// @notice Source-chain contract for cross-chain borrowing with full Morpho-style position tracking
/// @dev Tracks positions, shares, interest accrual, and syncs market state from remote chains
contract PositionManager {
    using SafeTransferLib for IERC20;
    using MathLib for uint256;
    using MathLib for uint128;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

    /* ═══════════════════════════════════════════ CONSTANTS ═══════════════════════════════════════════ */

    uint256 public constant WAD_UNIT = 1e18;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant MAX_LIQUIDATION_INCENTIVE = 0.15e18; // 15%
    uint256 public constant STALE_PRICE_THRESHOLD = 2 minutes;
    uint256 public constant STALE_MARKET_THRESHOLD = 5 minutes;

    /* ═══════════════════════════════════════════ STRUCTS ═══════════════════════════════════════════ */

    /// @notice Collateral configuration for a token
    struct CollateralConfig {
        address oracle; // Price oracle for this collateral (returns price in USD, scaled 1e36)
        uint256 lltv; // Liquidation loan-to-value (WAD scale, e.g., 0.85e18 = 85%)
        uint256 liquidationIncentive; // Bonus for liquidators (WAD scale)
        uint8 decimals; // Token decimals
        bool enabled;
    }

    /// @notice Remote market configuration - mirrors Morpho Market struct
    struct RemoteMarketConfig {
        uint32 chainId;
        Id marketId;
        address loanToken;
        address loanTokenOracle; // Price oracle for loan token (USD price, scaled 1e36)
        uint8 loanTokenDecimals;
        // Synced market state from remote chain
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastRemoteUpdate; // When we last synced from remote
        uint256 borrowRate; // Current borrow rate (per second, WAD)
        bool enabled;
    }

    /// @notice User position - Morpho-style with shares
    struct Position {
        address user;
        address collateralToken;
        uint128 collateralAmount;
        // Remote borrow tracking
        uint32 remoteChainId;
        Id remoteMarketId;
        uint128 borrowShares; // User's share of total borrow on remote Morpho
        uint128 lastInterestAccrual; // Timestamp of last local interest accrual
        bool active;
    }

    /// @notice Pending cross-chain request
    struct PendingRequest {
        bytes32 positionId;
        CrossChainTypes.MessageType requestType;
        uint256 requestedAmount;
        uint64 nonce;
        uint256 timestamp;
        bool pending;
        address liquidator;
        uint256 collateralToSeize;
    }

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    address public owner;
    ICrossChainAdapter public adapter;
    bool public paused;
    uint256 private _locked = 1;
    uint64 public messageNonce;

    // Collateral configs
    mapping(address token => CollateralConfig) public collateralConfigs;
    address[] public collateralTokens;

    // Remote market configs (chainId => marketId hash => config)
    mapping(bytes32 marketKey => RemoteMarketConfig) public remoteMarkets;
    bytes32[] public remoteMarketKeys;

    // Remote executor addresses per chain
    mapping(uint32 chainId => address) public remoteExecutors;

    // User positions
    mapping(bytes32 positionId => Position) public positions;
    mapping(address user => bytes32[]) public userPositionIds;

    // Pending requests
    mapping(bytes32 positionId => PendingRequest) public pendingRequests;

    // Oracle price cache for remote loan tokens (updated via cross-chain sync)
    mapping(bytes32 marketKey => uint256) public cachedLoanTokenPrice;
    mapping(bytes32 marketKey => uint256) public priceLastUpdated;

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
    event BorrowRequested(
        bytes32 indexed positionId,
        uint32 chainId,
        Id marketId,
        uint256 amount,
        address receiver
    );
    event BorrowConfirmed(
        bytes32 indexed positionId,
        uint256 borrowShares,
        uint256 actualAmount
    );
    event BorrowFailed(bytes32 indexed positionId, uint64 nonce);
    event RepayRequested(bytes32 indexed positionId, uint256 amount);
    event RepayConfirmed(
        bytes32 indexed positionId,
        uint256 sharesRepaid,
        uint256 amountRepaid
    );
    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event MarketStateSynced(
        bytes32 indexed marketKey,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint256 borrowRate
    );
    event PriceSynced(bytes32 indexed marketKey, uint256 price);
    event CollateralConfigSet(
        address indexed token,
        uint256 lltv,
        uint256 liquidationIncentive
    );
    event RemoteMarketSet(
        uint32 chainId,
        Id indexed marketId,
        address loanToken
    );
    event RemoteExecutorSet(uint32 indexed chainId, address executor);

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error Paused();
    error Reentrancy();
    error CollateralNotEnabled();
    error RemoteMarketNotEnabled();
    error InsufficientCollateral();
    error PositionNotHealthy();
    error PositionHealthy();
    error PositionNotActive();
    error PendingRequestExists();
    error NoPendingRequest();
    error InvalidNonce();
    error UnauthorizedCaller();
    error InvalidMessage();
    error ExceedsMaxLTV();
    error StalePrice();
    error StaleMarketState();

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

    constructor(address _adapter, address _owner) {
        if (_adapter == address(0) || _owner == address(0))
            revert ZeroAddress();
        adapter = ICrossChainAdapter(_adapter);
        owner = _owner;
    }

    /* ═══════════════════════════════════════════ ADMIN FUNCTIONS ═══════════════════════════════════════════ */

    function withdrawEther(
        address payable to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function setAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) revert ZeroAddress();
        adapter = ICrossChainAdapter(_adapter);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setCollateralConfig(
        address token,
        address oracle,
        uint256 lltv,
        uint256 liquidationIncentive,
        uint8 decimals
    ) external onlyOwner {
        if (token == address(0) || oracle == address(0)) revert ZeroAddress();

        CollateralConfig storage config = collateralConfigs[token];
        if (!config.enabled) {
            collateralTokens.push(token);
        }

        config.oracle = oracle;
        config.lltv = lltv;
        config.liquidationIncentive = liquidationIncentive;
        config.decimals = decimals;
        config.enabled = true;

        emit CollateralConfigSet(token, lltv, liquidationIncentive);
    }

    function setRemoteMarket(
        uint32 chainId,
        Id marketId,
        address loanToken,
        address loanTokenOracle,
        uint8 loanTokenDecimals
    ) external onlyOwner {
        if (loanToken == address(0) || loanTokenOracle == address(0))
            revert ZeroAddress();

        bytes32 key = _getRemoteMarketKey(chainId, marketId);
        RemoteMarketConfig storage config = remoteMarkets[key];

        if (!config.enabled) {
            remoteMarketKeys.push(key);
        }

        config.chainId = chainId;
        config.marketId = marketId;
        config.loanToken = loanToken;
        config.loanTokenOracle = loanTokenOracle;
        config.loanTokenDecimals = loanTokenDecimals;
        config.enabled = true;

        emit RemoteMarketSet(chainId, marketId, loanToken);
    }

    function setRemoteExecutor(
        uint32 chainId,
        address executor
    ) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        remoteExecutors[chainId] = executor;
        emit RemoteExecutorSet(chainId, executor);
    }

    /* ═══════════════════════════════════════════ COLLATERAL FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Deposit collateral to create or add to a position
    function depositCollateral(
        address collateralToken,
        uint256 amount,
        uint32 remoteChainId,
        Id remoteMarketId
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {
        if (amount == 0) revert ZeroAmount();

        CollateralConfig storage collConfig = collateralConfigs[
            collateralToken
        ];
        if (!collConfig.enabled) revert CollateralNotEnabled();

        bytes32 marketKey = _getRemoteMarketKey(remoteChainId, remoteMarketId);
        RemoteMarketConfig storage marketConfig = remoteMarkets[marketKey];
        if (!marketConfig.enabled) revert RemoteMarketNotEnabled();

        positionId = _getPositionId(
            msg.sender,
            collateralToken,
            remoteChainId,
            remoteMarketId
        );
        Position storage pos = positions[positionId];

        IERC20(collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        if (!pos.active) {
            pos.user = msg.sender;
            pos.collateralToken = collateralToken;
            pos.remoteChainId = remoteChainId;
            pos.remoteMarketId = remoteMarketId;
            pos.lastInterestAccrual = uint256(block.timestamp).toUint128();
            pos.active = true;
            userPositionIds[msg.sender].push(positionId);
        }

        pos.collateralAmount += amount.toUint128();

        emit CollateralDeposited(
            positionId,
            msg.sender,
            collateralToken,
            amount
        );
    }

    /// @notice Withdraw collateral from a position
    function withdrawCollateral(
        bytes32 positionId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert UnauthorizedCaller();
        if (!pos.active) revert PositionNotActive();
        if (pos.collateralAmount < amount) revert InsufficientCollateral();

        // Accrue interest before health check
        _accrueInterest(positionId);

        uint128 newCollateral = pos.collateralAmount - amount.toUint128();

        // Check position remains healthy after withdrawal
        if (pos.borrowShares > 0 && newCollateral > 0) {
            if (
                !_isHealthy(
                    pos.collateralToken,
                    newCollateral,
                    pos.remoteChainId,
                    pos.remoteMarketId,
                    pos.borrowShares
                )
            ) {
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

    /* ═══════════════════════════════════════════ BORROW FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Request a borrow on a remote chain
    function borrowRemote(
        bytes32 positionId,
        uint256 amount,
        address receiver
    ) external payable nonReentrant whenNotPaused returns (uint64 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert UnauthorizedCaller();
        if (!pos.active) revert PositionNotActive();
        if (pendingRequests[positionId].pending) revert PendingRequestExists();

        // Accrue interest
        _accrueInterest(positionId);

        // Validate prices are fresh
        bytes32 marketKey = _getRemoteMarketKey(
            pos.remoteChainId,
            pos.remoteMarketId
        );
        _validatePriceFreshness(marketKey);
        _validateMarketStateFreshness(marketKey);

        // Calculate max borrowable
        uint256 maxBorrow = _getMaxBorrowableAmount(positionId);
        uint256 currentDebt = _getDebtValue(
            pos.remoteChainId,
            pos.remoteMarketId,
            pos.borrowShares
        );

        if (currentDebt + amount > maxBorrow) revert ExceedsMaxLTV();

        nonce = ++messageNonce;

        CrossChainTypes.BorrowRequest memory request = CrossChainTypes
            .BorrowRequest({
                positionId: positionId,
                user: msg.sender,
                marketId: pos.remoteMarketId,
                amount: amount,
                receiver: receiver,
                nonce: nonce
            });

        pendingRequests[positionId] = PendingRequest({
            positionId: positionId,
            requestType: CrossChainTypes.MessageType.BORROW,
            requestedAmount: amount,
            nonce: nonce,
            timestamp: block.timestamp,
            pending: true,
            liquidator: address(0),
            collateralToSeize: 0
        });

        bytes memory payload = abi.encode(
            CrossChainTypes.MessageType.BORROW,
            abi.encode(request)
        );
        adapter.sendMessage{value: msg.value}(
            pos.remoteChainId,
            remoteExecutors[pos.remoteChainId],
            payload,
            ""
        );

        emit BorrowRequested(
            positionId,
            pos.remoteChainId,
            pos.remoteMarketId,
            amount,
            receiver
        );
    }

    /// @notice Request repayment of remote debt
    function repayRemote(
        bytes32 positionId,
        uint256 shares // Repay by shares for precision
    ) external payable nonReentrant whenNotPaused {
        Position storage pos = positions[positionId];
        if (pos.user != msg.sender) revert UnauthorizedCaller();
        if (!pos.active) revert PositionNotActive();
        if (pos.borrowShares == 0) revert ZeroAmount();

        _accrueInterest(positionId);

        uint64 nonce = ++messageNonce;
        uint256 sharesToRepay = shares == 0
            ? pos.borrowShares
            : _min(shares, pos.borrowShares);

        CrossChainTypes.RepayRequest memory request = CrossChainTypes
            .RepayRequest({
                positionId: positionId,
                marketId: pos.remoteMarketId,
                amount: 0, // We use shares
                maxShares: sharesToRepay,
                isLiquidation: false,
                nonce: nonce
            });

        pendingRequests[positionId] = PendingRequest({
            positionId: positionId,
            requestType: CrossChainTypes.MessageType.REPAY,
            requestedAmount: sharesToRepay,
            nonce: nonce,
            timestamp: block.timestamp,
            pending: true,
            liquidator: address(0),
            collateralToSeize: 0
        });

        bytes memory payload = abi.encode(
            CrossChainTypes.MessageType.REPAY,
            abi.encode(request)
        );
        adapter.sendMessage{value: msg.value}(
            pos.remoteChainId,
            remoteExecutors[pos.remoteChainId],
            payload,
            ""
        );

        emit RepayRequested(positionId, sharesToRepay);
    }

    /* ═══════════════════════════════════════════ LIQUIDATION ═══════════════════════════════════════════ */

    /// @notice Liquidate an unhealthy position
    /// @param positionId The position to liquidate
    /// @param repayShares Number of shares to repay (0 = max)
    function liquidate(
        bytes32 positionId,
        uint256 repayShares
    ) external payable nonReentrant whenNotPaused {
        Position storage pos = positions[positionId];
        if (!pos.active) revert PositionNotActive();
        if (pos.borrowShares == 0) revert ZeroAmount();
        if (pendingRequests[positionId].pending) revert PendingRequestExists();

        _accrueInterest(positionId);

        bytes32 marketKey = _getRemoteMarketKey(
            pos.remoteChainId,
            pos.remoteMarketId
        );
        _validatePriceFreshness(marketKey);

        // Check position is unhealthy
        if (
            _isHealthy(
                pos.collateralToken,
                pos.collateralAmount,
                pos.remoteChainId,
                pos.remoteMarketId,
                pos.borrowShares
            )
        ) {
            revert PositionHealthy();
        }

        // Calculate shares to liquidate
        uint256 sharesToLiquidate = repayShares == 0
            ? pos.borrowShares
            : _min(repayShares, pos.borrowShares);

        // Calculate debt value for those shares
        uint256 debtToRepay = _sharesToAssets(
            pos.remoteChainId,
            pos.remoteMarketId,
            sharesToLiquidate
        );

        // Calculate collateral to seize (debt + incentive)
        CollateralConfig storage collConfig = collateralConfigs[
            pos.collateralToken
        ];
        uint256 incentive = collConfig.liquidationIncentive;

        uint256 collateralPrice = _getCollateralPrice(pos.collateralToken);
        uint256 loanPrice = _getLoanTokenPrice(
            pos.remoteChainId,
            pos.remoteMarketId
        );

        // collateralToSeize = debtToRepay * (1 + incentive) * loanPrice / collateralPrice
        uint256 collateralToSeize = debtToRepay
            .wMulDown(WAD_UNIT + incentive)
            .mulDivDown(loanPrice, collateralPrice);

        // Adjust decimals
        collateralToSeize = _adjustDecimals(
            collateralToSeize,
            remoteMarkets[marketKey].loanTokenDecimals,
            collConfig.decimals
        );

        // Cap at available collateral (bad debt case)
        collateralToSeize = _min(collateralToSeize, pos.collateralAmount);

        // Send liquidation repay to remote
        uint64 nonce = ++messageNonce;
        CrossChainTypes.RepayRequest memory request = CrossChainTypes
            .RepayRequest({
                positionId: positionId,
                marketId: pos.remoteMarketId,
                amount: 0,
                maxShares: sharesToLiquidate,
                isLiquidation: true,
                nonce: nonce
            });

        pendingRequests[positionId] = PendingRequest({
            positionId: positionId,
            requestType: CrossChainTypes.MessageType.LIQUIDATE_REPAY,
            requestedAmount: sharesToLiquidate,
            nonce: nonce,
            timestamp: block.timestamp,
            pending: true,
            liquidator: msg.sender,
            collateralToSeize: collateralToSeize
        });

        bytes memory payload = abi.encode(
            CrossChainTypes.MessageType.LIQUIDATE_REPAY,
            abi.encode(request)
        );
        adapter.sendMessage{value: msg.value}(
            pos.remoteChainId,
            remoteExecutors[pos.remoteChainId],
            payload,
            ""
        );

        emit RepayRequested(positionId, sharesToLiquidate);
    }

    /* ═══════════════════════════════════════════ CROSS-CHAIN SYNC ═══════════════════════════════════════════ */

    /// @notice Request market state sync from remote chain
    function requestMarketSync(uint32 chainId, Id marketId) external payable {
        bytes32 marketKey = _getRemoteMarketKey(chainId, marketId);
        RemoteMarketConfig storage config = remoteMarkets[marketKey];
        if (!config.enabled) revert RemoteMarketNotEnabled();

        bytes memory payload = abi.encode(
            CrossChainTypes.MessageType.BORROW, // Reuse type, could add SYNC_REQUEST
            abi.encode(marketKey) // Just need to identify which market
        );

        // Request sync - RemoteExecutor will respond with market state
        adapter.sendMessage{value: msg.value}(
            chainId,
            remoteExecutors[chainId],
            payload,
            ""
        );
    }

    /// @notice Handle incoming cross-chain messages
    function receiveMessage(
        uint32 srcChainId,
        address srcSender,
        bytes calldata payload
    ) external {
        if (msg.sender != address(adapter)) revert UnauthorizedCaller();
        if (srcSender != remoteExecutors[srcChainId])
            revert UnauthorizedCaller();

        (CrossChainTypes.MessageType msgType, bytes memory data) = abi.decode(
            payload,
            (CrossChainTypes.MessageType, bytes)
        );

        if (msgType == CrossChainTypes.MessageType.BORROW_ACK) {
            _handleBorrowAck(abi.decode(data, (CrossChainTypes.BorrowAck)));
        } else if (msgType == CrossChainTypes.MessageType.BORROW_FAILED) {
            _handleBorrowFailed(abi.decode(data, (CrossChainTypes.BorrowAck)));
        } else if (msgType == CrossChainTypes.MessageType.REPAY_ACK) {
            _handleRepayAck(abi.decode(data, (CrossChainTypes.RepayAck)));
        } else {
            revert InvalidMessage();
        }
    }

    /// @notice Sync market state from remote chain (called by keeper/oracle)
    function syncRemoteMarketState(
        uint32 chainId,
        Id marketId,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint256 borrowRate
    ) external onlyOwner {
        bytes32 marketKey = _getRemoteMarketKey(chainId, marketId);
        RemoteMarketConfig storage config = remoteMarkets[marketKey];
        if (!config.enabled) revert RemoteMarketNotEnabled();

        config.totalBorrowAssets = totalBorrowAssets;
        config.totalBorrowShares = totalBorrowShares;
        config.borrowRate = borrowRate;
        config.lastRemoteUpdate = uint256(block.timestamp).toUint128();

        emit MarketStateSynced(
            marketKey,
            totalBorrowAssets,
            totalBorrowShares,
            borrowRate
        );
    }

    /// @notice Sync loan token price from remote chain oracle
    function syncLoanTokenPrice(
        uint32 chainId,
        Id marketId,
        uint256 price
    ) external onlyOwner {
        bytes32 marketKey = _getRemoteMarketKey(chainId, marketId);
        if (!remoteMarkets[marketKey].enabled) revert RemoteMarketNotEnabled();

        cachedLoanTokenPrice[marketKey] = price;
        priceLastUpdated[marketKey] = block.timestamp;

        emit PriceSynced(marketKey, price);
    }

    /* ═══════════════════════════════════════════ INTERNAL HANDLERS ═══════════════════════════════════════════ */

    function _handleBorrowAck(CrossChainTypes.BorrowAck memory ack) internal {
        PendingRequest storage pending = pendingRequests[ack.positionId];
        if (!pending.pending) revert NoPendingRequest();
        if (pending.nonce != ack.nonce) revert InvalidNonce();

        Position storage pos = positions[ack.positionId];

        if (ack.success) {
            pos.borrowShares += ack.borrowShares.toUint128();
            pos.lastInterestAccrual = uint256(block.timestamp).toUint128();
            emit BorrowConfirmed(
                ack.positionId,
                ack.borrowShares,
                ack.actualAmount
            );
        } else {
            emit BorrowFailed(ack.positionId, ack.nonce);
        }

        delete pendingRequests[ack.positionId];
    }

    function _handleBorrowFailed(
        CrossChainTypes.BorrowAck memory ack
    ) internal {
        PendingRequest storage pending = pendingRequests[ack.positionId];
        if (!pending.pending) revert NoPendingRequest();
        if (pending.nonce != ack.nonce) revert InvalidNonce();

        delete pendingRequests[ack.positionId];
        emit BorrowFailed(ack.positionId, ack.nonce);
    }

    function _handleRepayAck(CrossChainTypes.RepayAck memory ack) internal {
        Position storage pos = positions[ack.positionId];
        PendingRequest memory pending = pendingRequests[ack.positionId];
        if (!pending.pending) revert NoPendingRequest();

        if (ack.success) {
            pos.borrowShares -= ack.sharesRepaid.toUint128();
            pos.lastInterestAccrual = uint256(block.timestamp).toUint128();

            if (
                pending.requestType ==
                CrossChainTypes.MessageType.LIQUIDATE_REPAY
            ) {
                uint256 actualCollateralToSeize = pending.collateralToSeize;
                if (
                    ack.sharesRepaid < pending.requestedAmount &&
                    pending.requestedAmount > 0
                ) {
                    actualCollateralToSeize =
                        (pending.collateralToSeize * ack.sharesRepaid) /
                        pending.requestedAmount;
                }

                if (actualCollateralToSeize > pos.collateralAmount)
                    actualCollateralToSeize = pos.collateralAmount;

                pos.collateralAmount -= actualCollateralToSeize.toUint128();
                IERC20(pos.collateralToken).safeTransfer(
                    pending.liquidator,
                    actualCollateralToSeize
                );

                emit PositionLiquidated(
                    ack.positionId,
                    pending.liquidator,
                    ack.amountRepaid,
                    actualCollateralToSeize
                );
            }

            emit RepayConfirmed(
                ack.positionId,
                ack.sharesRepaid,
                ack.amountRepaid
            );
        }

        // Clear any pending request
        delete pendingRequests[ack.positionId];
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

        return
            _calculateHealthFactor(
                pos.collateralToken,
                pos.collateralAmount,
                pos.remoteChainId,
                pos.remoteMarketId,
                pos.borrowShares
            );
    }

    function getDebtValue(bytes32 positionId) external view returns (uint256) {
        Position storage pos = positions[positionId];
        return
            _getDebtValue(
                pos.remoteChainId,
                pos.remoteMarketId,
                pos.borrowShares
            );
    }

    function getMaxBorrowableAmount(
        bytes32 positionId
    ) external view returns (uint256) {
        return _getMaxBorrowableAmount(positionId);
    }

    function getUserPositions(
        address user
    ) external view returns (bytes32[] memory) {
        return userPositionIds[user];
    }

    /* ═══════════════════════════════════════════ INTERNAL FUNCTIONS ═══════════════════════════════════════════ */

    function _accrueInterest(bytes32 positionId) internal {
        Position storage pos = positions[positionId];
        if (pos.borrowShares == 0) return;

        bytes32 marketKey = _getRemoteMarketKey(
            pos.remoteChainId,
            pos.remoteMarketId
        );
        RemoteMarketConfig storage market = remoteMarkets[marketKey];

        // Interest accrual happens on remote Morpho
        // We just update our local timestamp for tracking
        pos.lastInterestAccrual = uint256(block.timestamp).toUint128();
    }

    function _getPositionId(
        address user,
        address collateralToken,
        uint32 chainId,
        Id marketId
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    user,
                    collateralToken,
                    chainId,
                    Id.unwrap(marketId)
                )
            );
    }

    function _getRemoteMarketKey(
        uint32 chainId,
        Id marketId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainId, Id.unwrap(marketId)));
    }

    function _getCollateralPrice(
        address token
    ) internal view returns (uint256) {
        CollateralConfig storage config = collateralConfigs[token];
        return IOracle(config.oracle).price();
    }

    function _getLoanTokenPrice(
        uint32 chainId,
        Id marketId
    ) internal view returns (uint256) {
        bytes32 marketKey = _getRemoteMarketKey(chainId, marketId);

        // Try cached price first (from cross-chain sync)
        if (cachedLoanTokenPrice[marketKey] > 0) {
            return cachedLoanTokenPrice[marketKey];
        }

        // Fallback to local oracle if configured
        RemoteMarketConfig storage config = remoteMarkets[marketKey];
        if (config.loanTokenOracle != address(0)) {
            return IOracle(config.loanTokenOracle).price();
        }

        revert StalePrice();
    }

    function _sharesToAssets(
        uint32 chainId,
        Id marketId,
        uint256 shares
    ) internal view returns (uint256) {
        bytes32 marketKey = _getRemoteMarketKey(chainId, marketId);
        RemoteMarketConfig storage market = remoteMarkets[marketKey];

        if (market.totalBorrowShares == 0) return shares;

        // Calculate accrued interest since last sync
        // Interest accrues continuously: newAssets = assets * (1 + rate * time)
        uint256 totalBorrowAssets = market.totalBorrowAssets;

        if (market.borrowRate > 0 && market.lastRemoteUpdate > 0) {
            uint256 elapsed = block.timestamp - market.lastRemoteUpdate;
            if (elapsed > 0) {
                // interest = totalBorrowAssets * borrowRate * elapsed
                // borrowRate is per-second, scaled by WAD
                uint256 interest = uint256(market.totalBorrowAssets).wMulDown(
                    market.borrowRate
                ) * elapsed;
                totalBorrowAssets += interest.toUint128();
            }
        }

        return shares.toAssetsUp(totalBorrowAssets, market.totalBorrowShares);
    }

    function _assetsToShares(
        uint32 chainId,
        Id marketId,
        uint256 assets
    ) internal view returns (uint256) {
        bytes32 marketKey = _getRemoteMarketKey(chainId, marketId);
        RemoteMarketConfig storage market = remoteMarkets[marketKey];

        if (market.totalBorrowAssets == 0) return assets;

        // Calculate accrued interest since last sync (same as _sharesToAssets)
        uint256 totalBorrowAssets = market.totalBorrowAssets;

        if (market.borrowRate > 0 && market.lastRemoteUpdate > 0) {
            uint256 elapsed = block.timestamp - market.lastRemoteUpdate;
            if (elapsed > 0) {
                uint256 interest = uint256(market.totalBorrowAssets).wMulDown(
                    market.borrowRate
                ) * elapsed;
                totalBorrowAssets += interest.toUint128();
            }
        }

        return assets.toSharesDown(totalBorrowAssets, market.totalBorrowShares);
    }

    function _getDebtValue(
        uint32 chainId,
        Id marketId,
        uint256 borrowShares
    ) internal view returns (uint256) {
        if (borrowShares == 0) return 0;

        uint256 debtAssets = _sharesToAssets(chainId, marketId, borrowShares);
        uint256 loanPrice = _getLoanTokenPrice(chainId, marketId);

        return debtAssets.wMulDown(loanPrice);
    }

    function _getCollateralValue(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        if (amount == 0) return 0;

        uint256 price = _getCollateralPrice(token);
        return uint256(amount).wMulDown(price);
    }

    function _getMaxBorrowableAmount(
        bytes32 positionId
    ) internal view returns (uint256) {
        Position storage pos = positions[positionId];
        CollateralConfig storage collConfig = collateralConfigs[
            pos.collateralToken
        ];

        uint256 collateralValue = _getCollateralValue(
            pos.collateralToken,
            pos.collateralAmount
        );
        uint256 maxBorrowValue = collateralValue.wMulDown(collConfig.lltv);

        uint256 loanPrice = _getLoanTokenPrice(
            pos.remoteChainId,
            pos.remoteMarketId
        );

        return maxBorrowValue.wDivDown(loanPrice);
    }

    function _calculateHealthFactor(
        address collateralToken,
        uint256 collateralAmount,
        uint32 chainId,
        Id marketId,
        uint256 borrowShares
    ) internal view returns (uint256) {
        if (borrowShares == 0) return type(uint256).max;

        CollateralConfig storage collConfig = collateralConfigs[
            collateralToken
        ];

        uint256 collateralValue = _getCollateralValue(
            collateralToken,
            collateralAmount
        );
        uint256 maxBorrowValue = collateralValue.wMulDown(collConfig.lltv);
        uint256 debtValue = _getDebtValue(chainId, marketId, borrowShares);

        // Health factor = maxBorrowValue / debtValue
        // If >= 1e18, position is healthy
        return maxBorrowValue.wDivDown(debtValue);
    }

    function _isHealthy(
        address collateralToken,
        uint256 collateralAmount,
        uint32 chainId,
        Id marketId,
        uint256 borrowShares
    ) internal view returns (bool) {
        return
            _calculateHealthFactor(
                collateralToken,
                collateralAmount,
                chainId,
                marketId,
                borrowShares
            ) >= WAD_UNIT;
    }

    function _validatePriceFreshness(bytes32 marketKey) internal view {
        uint256 lastUpdate = priceLastUpdated[marketKey];
        if (
            lastUpdate == 0 ||
            block.timestamp - lastUpdate > STALE_PRICE_THRESHOLD
        ) {
            // Check if we have a local oracle fallback
            RemoteMarketConfig storage config = remoteMarkets[marketKey];
            if (config.loanTokenOracle == address(0)) {
                revert StalePrice();
            }
        }
    }

    function _validateMarketStateFreshness(bytes32 marketKey) internal view {
        RemoteMarketConfig storage config = remoteMarkets[marketKey];
        if (
            config.lastRemoteUpdate == 0 ||
            block.timestamp - config.lastRemoteUpdate > STALE_MARKET_THRESHOLD
        ) {
            revert StaleMarketState();
        }
    }

    function _adjustDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        }
        return amount * (10 ** (toDecimals - fromDecimals));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
