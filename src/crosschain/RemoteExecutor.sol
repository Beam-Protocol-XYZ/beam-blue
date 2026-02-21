// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, Market, IMorpho} from "../interfaces/IMorpho.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ICrossChainAdapter} from "../interfaces/ICrossChainAdapter.sol";
import {CrossChainTypes} from "../interfaces/CrossChainTypes.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title RemoteExecutor
/// @notice Destination-chain contract that executes Morpho operations for cross-chain borrowing
/// @dev Must be whitelisted as uncollateralized borrower in Morpho markets
contract RemoteExecutor {
    using SafeTransferLib for IERC20;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    IMorpho public immutable morpho;
    address public owner;
    ICrossChainAdapter public adapter;
    bool public paused;
    uint256 private _locked = 1;

    /// @notice Whitelisted Morpho markets for uncollateralized borrowing
    mapping(Id marketId => bool) public isWhitelistedMarket;
    Id[] public whitelistedMarkets;

    /// @notice Position manager addresses per source chain
    mapping(uint32 chainId => address) public positionManagers;

    /// @notice Track borrow shares per position for repayment
    mapping(bytes32 positionId => uint256) public positionBorrowShares;

    /// @notice Track which market each position borrowed from
    mapping(bytes32 positionId => Id) public positionMarket;

    /// @notice Processed nonces for replay protection
    mapping(bytes32 positionId => mapping(uint64 nonce => bool))
        public processedNonces;

    /// @notice Liquidity reserve for repayments (funded by protocol or liquidation proceeds)
    mapping(address token => uint256) public repaymentReserve;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event MarketWhitelisted(Id indexed marketId);
    event MarketDelisted(Id indexed marketId);
    event PositionManagerSet(uint32 chainId, address positionManager);
    event BorrowExecuted(
        bytes32 indexed positionId,
        uint256 amount,
        uint256 shares,
        address receiver
    );
    event BorrowFailed(bytes32 indexed positionId, uint64 nonce, string reason);
    event RepayExecuted(
        bytes32 indexed positionId,
        uint256 amount,
        uint256 sharesRepaid
    );
    event RepaymentFunded(address indexed token, uint256 amount);
    event MarketStateSent(uint32 indexed destChainId, Id indexed marketId);

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error NotOwner();
    error ZeroAddress();
    error Paused();
    error Reentrancy();
    error MarketNotWhitelisted();
    error MarketAlreadyWhitelisted();
    error UnauthorizedCaller();
    error NonceAlreadyUsed();
    error InsufficientRepaymentFunds();
    error InsufficientShares();
    error ZeroAmount();

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

    constructor(address _morpho, address _adapter, address _owner) {
        if (
            _morpho == address(0) ||
            _adapter == address(0) ||
            _owner == address(0)
        ) {
            revert ZeroAddress();
        }
        morpho = IMorpho(_morpho);
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

    /// @notice Whitelist a Morpho market for uncollateralized borrowing
    /// @dev The RemoteExecutor must also be whitelisted in Morpho via setUncollateralizedBorrower
    function whitelistMarket(Id marketId) external onlyOwner {
        if (isWhitelistedMarket[marketId]) revert MarketAlreadyWhitelisted();

        isWhitelistedMarket[marketId] = true;
        whitelistedMarkets.push(marketId);

        MarketParams memory params = morpho.idToMarketParams(marketId);
        IERC20(params.loanToken).safeApprove(
            address(morpho),
            type(uint256).max
        );

        emit MarketWhitelisted(marketId);
    }

    function delistMarket(Id marketId) external onlyOwner {
        if (!isWhitelistedMarket[marketId]) revert MarketNotWhitelisted();

        isWhitelistedMarket[marketId] = false;

        for (uint256 i = 0; i < whitelistedMarkets.length; i++) {
            if (Id.unwrap(whitelistedMarkets[i]) == Id.unwrap(marketId)) {
                whitelistedMarkets[i] = whitelistedMarkets[
                    whitelistedMarkets.length - 1
                ];
                whitelistedMarkets.pop();
                break;
            }
        }

        emit MarketDelisted(marketId);
    }

    function setPositionManager(
        uint32 chainId,
        address positionManager
    ) external onlyOwner {
        if (positionManager == address(0)) revert ZeroAddress();
        positionManagers[chainId] = positionManager;
        emit PositionManagerSet(chainId, positionManager);
    }

    /* ═══════════════════════════════════════════ FUND MANAGEMENT ═══════════════════════════════════════════ */

    /// @notice Fund the repayment reserve for a token
    function fundRepaymentReserve(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        repaymentReserve[token] += amount;
        emit RepaymentFunded(token, amount);
    }

    /// @notice Withdraw from repayment reserve (owner only)
    function withdrawReserve(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (repaymentReserve[token] < amount)
            revert InsufficientRepaymentFunds();

        repaymentReserve[token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);
    }

    /* ═══════════════════════════════════════════ MESSAGE RECEIVER ═══════════════════════════════════════════ */

    /// @notice Handle incoming cross-chain messages from PositionManager
    function receiveMessage(
        uint32 srcChainId,
        address srcSender,
        bytes calldata payload
    ) external nonReentrant whenNotPaused {
        if (msg.sender != address(adapter)) revert UnauthorizedCaller();
        if (srcSender != positionManagers[srcChainId])
            revert UnauthorizedCaller();

        (CrossChainTypes.MessageType msgType, bytes memory data) = abi.decode(
            payload,
            (CrossChainTypes.MessageType, bytes)
        );

        if (msgType == CrossChainTypes.MessageType.BORROW) {
            _handleBorrowRequest(
                srcChainId,
                abi.decode(data, (CrossChainTypes.BorrowRequest))
            );
        } else if (msgType == CrossChainTypes.MessageType.REPAY) {
            _handleRepayRequest(
                srcChainId,
                abi.decode(data, (CrossChainTypes.RepayRequest))
            );
        } else if (msgType == CrossChainTypes.MessageType.LIQUIDATE_REPAY) {
            _handleLiquidationRepay(
                srcChainId,
                abi.decode(data, (CrossChainTypes.RepayRequest))
            );
        }
    }

    /* ═══════════════════════════════════════════ INTERNAL HANDLERS ═══════════════════════════════════════════ */

    function _handleBorrowRequest(
        uint32 srcChainId,
        CrossChainTypes.BorrowRequest memory request
    ) internal {
        if (processedNonces[request.positionId][request.nonce])
            revert NonceAlreadyUsed();
        processedNonces[request.positionId][request.nonce] = true;

        if (!isWhitelistedMarket[request.marketId]) {
            _sendBorrowFailedAck(srcChainId, request, "Market not whitelisted");
            return;
        }

        MarketParams memory params = morpho.idToMarketParams(request.marketId);

        try
            morpho.borrow(
                params,
                request.amount,
                0,
                address(this),
                request.receiver
            )
        returns (uint256 assets, uint256 shares) {
            // Track position
            positionBorrowShares[request.positionId] += shares;
            positionMarket[request.positionId] = request.marketId;

            // Get market state to send back
            Market memory marketState = morpho.market(request.marketId);

            // Send success ack with market state
            _sendBorrowAck(
                srcChainId,
                request,
                shares,
                assets,
                true,
                marketState
            );

            emit BorrowExecuted(
                request.positionId,
                assets,
                shares,
                request.receiver
            );
        } catch Error(string memory reason) {
            _sendBorrowFailedAck(srcChainId, request, reason);
        } catch {
            _sendBorrowFailedAck(srcChainId, request, "Unknown error");
        }
    }

    function _sendBorrowAck(
        uint32 srcChainId,
        CrossChainTypes.BorrowRequest memory request,
        uint256 shares,
        uint256 assets,
        bool success,
        Market memory marketState
    ) internal {
        CrossChainTypes.BorrowAck memory ack = CrossChainTypes.BorrowAck({
            positionId: request.positionId,
            borrowShares: shares,
            actualAmount: assets,
            success: success,
            nonce: request.nonce
        });

        // Include market state in extended payload
        bytes memory extendedData = abi.encode(
            ack,
            marketState.totalBorrowAssets,
            marketState.totalBorrowShares
        );

        bytes memory payload = abi.encode(
            CrossChainTypes.MessageType.BORROW_ACK,
            extendedData
        );
        adapter.sendMessage(
            srcChainId,
            positionManagers[srcChainId],
            payload,
            ""
        );
    }

    function _sendBorrowFailedAck(
        uint32 srcChainId,
        CrossChainTypes.BorrowRequest memory request,
        string memory reason
    ) internal {
        CrossChainTypes.BorrowAck memory ack = CrossChainTypes.BorrowAck({
            positionId: request.positionId,
            borrowShares: 0,
            actualAmount: 0,
            success: false,
            nonce: request.nonce
        });

        bytes memory payload = abi.encode(
            CrossChainTypes.MessageType.BORROW_FAILED,
            abi.encode(ack)
        );
        adapter.sendMessage(
            srcChainId,
            positionManagers[srcChainId],
            payload,
            ""
        );

        emit BorrowFailed(request.positionId, request.nonce, reason);
    }

    function _handleRepayRequest(
        uint32 srcChainId,
        CrossChainTypes.RepayRequest memory request
    ) internal {
        if (processedNonces[request.positionId][request.nonce])
            revert NonceAlreadyUsed();
        processedNonces[request.positionId][request.nonce] = true;

        uint256 positionShares = positionBorrowShares[request.positionId];
        if (positionShares == 0) {
            _sendRepayAck(srcChainId, request, 0, 0, true);
            return;
        }

        Id marketId = positionMarket[request.positionId];
        MarketParams memory params = morpho.idToMarketParams(marketId);

        // Calculate shares to repay
        uint256 sharesToRepay = request.maxShares > 0
            ? _min(request.maxShares, positionShares)
            : positionShares;

        // Get current debt for shares
        Market memory marketState = morpho.market(marketId);
        uint256 repayAmount = sharesToRepay.toAssetsUp(
            marketState.totalBorrowAssets,
            marketState.totalBorrowShares
        );

        // Check reserve has enough
        uint256 available = repaymentReserve[params.loanToken];
        if (available < repayAmount) {
            if (available > 0) {
                // Partial repay
                repayAmount = available;
                sharesToRepay = repayAmount.toSharesDown(
                    marketState.totalBorrowAssets,
                    marketState.totalBorrowShares
                );
            } else {
                _sendRepayAck(srcChainId, request, 0, 0, false);
                return;
            }
        }

        // Deduct from reserve
        repaymentReserve[params.loanToken] -= repayAmount;

        // Execute repay
        (uint256 assetsRepaid, uint256 sharesRepaid) = morpho.repay(
            params,
            repayAmount,
            0,
            address(this),
            ""
        );

        positionBorrowShares[request.positionId] -= sharesRepaid;

        _sendRepayAck(srcChainId, request, sharesRepaid, assetsRepaid, true);
        emit RepayExecuted(request.positionId, assetsRepaid, sharesRepaid);
    }

    function _handleLiquidationRepay(
        uint32 srcChainId,
        CrossChainTypes.RepayRequest memory request
    ) internal {
        // For liquidations, we must repay even if reserve is low
        // The protocol should ensure reserve is funded
        _handleRepayRequest(srcChainId, request);
    }

    function _sendRepayAck(
        uint32 srcChainId,
        CrossChainTypes.RepayRequest memory request,
        uint256 sharesRepaid,
        uint256 amountRepaid,
        bool success
    ) internal {
        Id marketId = positionMarket[request.positionId];
        Market memory marketState = morpho.market(marketId);

        CrossChainTypes.RepayAck memory ack = CrossChainTypes.RepayAck({
            positionId: request.positionId,
            sharesRepaid: sharesRepaid,
            amountRepaid: amountRepaid,
            success: success,
            nonce: request.nonce
        });

        // Include updated market state
        bytes memory extendedData = abi.encode(
            ack,
            marketState.totalBorrowAssets,
            marketState.totalBorrowShares
        );

        bytes memory payload = abi.encode(
            CrossChainTypes.MessageType.REPAY_ACK,
            extendedData
        );
        adapter.sendMessage(
            srcChainId,
            positionManagers[srcChainId],
            payload,
            ""
        );
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    function getPositionShares(
        bytes32 positionId
    ) external view returns (uint256) {
        return positionBorrowShares[positionId];
    }

    function getPositionDebt(
        bytes32 positionId
    ) external view returns (uint256) {
        uint256 shares = positionBorrowShares[positionId];
        if (shares == 0) return 0;

        Id marketId = positionMarket[positionId];
        Market memory marketState = morpho.market(marketId);

        return
            shares.toAssetsUp(
                marketState.totalBorrowAssets,
                marketState.totalBorrowShares
            );
    }

    function getMarketState(
        Id marketId
    )
        external
        view
        returns (
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate
        )
    {
        Market memory state = morpho.market(marketId);
        return (
            state.totalBorrowAssets,
            state.totalBorrowShares,
            state.lastUpdate
        );
    }

    function getWhitelistedMarkets() external view returns (Id[] memory) {
        return whitelistedMarkets;
    }

    /* ═══════════════════════════════════════════ QUERY FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Query oracle price for a market's loan token
    function queryOraclePrice(Id marketId) external view returns (uint256) {
        MarketParams memory params = morpho.idToMarketParams(marketId);
        if (params.oracle == address(0)) return 0;
        return IOracle(params.oracle).price();
    }

    /// @notice Send market state and price to source chain (keeper function)
    function pushMarketState(
        uint32 destChainId,
        Id marketId
    ) external payable onlyOwner {
        if (!isWhitelistedMarket[marketId]) revert MarketNotWhitelisted();

        Market memory state = morpho.market(marketId);
        MarketParams memory params = morpho.idToMarketParams(marketId);

        uint256 price = 0;
        if (params.oracle != address(0)) {
            price = IOracle(params.oracle).price();
        }

        // Encode market state update
        bytes memory stateData = abi.encode(
            marketId,
            state.totalBorrowAssets,
            state.totalBorrowShares,
            price
        );

        bytes memory payload = abi.encode(
            CrossChainTypes.MessageType.REPAY_ACK, // Reuse type, could add MARKET_SYNC
            stateData
        );

        adapter.sendMessage{value: msg.value}(
            destChainId,
            positionManagers[destChainId],
            payload,
            ""
        );
        emit MarketStateSent(destChainId, marketId);
    }

    /* ═══════════════════════════════════════════ INTERNAL FUNCTIONS ═══════════════════════════════════════════ */

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
