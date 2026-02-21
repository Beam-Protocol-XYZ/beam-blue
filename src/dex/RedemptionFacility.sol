// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Dex} from "./Dex.sol";
import {IRedemptionAdapter} from "./interfaces/IRedemptionAdapter.sol";
import {Id, MarketParams, IMorpho} from "../interfaces/IMorpho.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {MathLib, WAD} from "../libraries/MathLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../libraries/MarketParamsLib.sol";

/// @title RedemptionFacility
/// @notice Extends DEX to provide instant liquidity for RWA token holders
/// @dev Inherits Dex.sol - borrows from Morpho, user gets instant liquidity, repays after RWA redemption
contract RedemptionFacility is Dex {
    using SafeTransferLib for IERC20;
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /* ═══════════════════════════════════════════ CONSTANTS ═══════════════════════════════════════════ */

    /// @notice Settlement-period-based fee tiers (in basis points)
    uint256 public constant INSTANT_FEE_BPS = 10; // <1 hour: 0.1%
    uint256 public constant SAME_DAY_FEE_BPS = 30; // <24 hours: 0.3%
    uint256 public constant SHORT_FEE_BPS = 50; // 1-7 days: 0.5%
    uint256 public constant STANDARD_FEE_BPS = 100; // 7-30 days: 1.0%
    uint256 public constant EXTENDED_FEE_BPS = 200; // >30 days: 2.0%

    /// @notice Maximum staleness before liquidation (settlement period + buffer)
    uint256 public constant STALE_BUFFER = 7 days;

    /// @notice Liquidation bonus for settling stale redemptions
    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5%

    /* ═══════════════════════════════════════════ RWA CONFIG ═══════════════════════════════════════════ */

    /// @notice Configuration for each whitelisted RWA token
    struct RWAConfig {
        IRedemptionAdapter adapter; // Protocol-specific adapter
        Id morphoMarketId; // Market for borrowing liquid asset
        address oracle; // Price oracle (RWA price in output token terms)
        uint256 settlementPeriod; // Expected redemption time (seconds)
        uint256 maxLTV; // Max LTV for this RWA (WAD scale)
        address outputToken; // Token received from redemption (e.g., USDC)
        bool enabled;
    }

    mapping(address rwaToken => RWAConfig) public rwaConfigs;

    /* ═══════════════════════════════════════════ REDEMPTION STATE ═══════════════════════════════════════════ */

    /// @notice Active redemption tracking
    struct ActiveRedemption {
        address user;
        address rwaToken;
        uint256 rwaAmount;
        uint256 borrowedAmount;
        uint256 borrowShares;
        bytes32 adapterRequestId;
        uint256 timestamp;
        bool settled;
    }

    mapping(bytes32 redemptionId => ActiveRedemption) public redemptions;
    uint256 public redemptionNonce;

    /// @notice Track total outstanding redemptions per RWA token
    mapping(address rwaToken => uint256) public totalPendingRedemptions;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event RWAConfigured(
        address indexed rwaToken,
        address adapter,
        Id morphoMarketId,
        uint256 settlementPeriod,
        address outputToken
    );
    event RWADisabled(address indexed rwaToken);
    event InstantRedemption(
        bytes32 indexed redemptionId,
        address indexed user,
        address indexed rwaToken,
        uint256 rwaAmount,
        uint256 outputAmount,
        uint256 fee
    );
    event RedemptionSettled(
        bytes32 indexed redemptionId,
        uint256 redeemedAmount,
        uint256 repaidAmount,
        uint256 surplus
    );
    event StaleRedemptionLiquidated(
        bytes32 indexed redemptionId,
        address indexed liquidator,
        uint256 reward
    );

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error RWANotEnabled();
    error RWAAlreadyEnabled();
    error RedemptionNotFound();
    error RedemptionAlreadySettled();
    error RedemptionNotComplete();
    error RedemptionNotStale();
    error InvalidAdapter();
    error InvalidSettlementPeriod();
    error OutputBelowMinimum();

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(address _morpho, address _owner) Dex(_morpho, _owner) {}

    /* ═══════════════════════════════════════════ ADMIN FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Configure an RWA token for instant redemption
    /// @param rwaToken The RWA token address
    /// @param adapter The protocol-specific adapter
    /// @param morphoMarketId Morpho market for borrowing output token
    /// @param oracle Price oracle for RWA valuation
    /// @param settlementPeriod Expected redemption settlement time
    /// @param maxLTV Maximum loan-to-value ratio
    /// @param outputToken Token received from redemption
    function configureRWA(
        address rwaToken,
        IRedemptionAdapter adapter,
        Id morphoMarketId,
        address oracle,
        uint256 settlementPeriod,
        uint256 maxLTV,
        address outputToken
    ) external onlyOwner {
        if (address(adapter) == address(0)) revert InvalidAdapter();
        if (settlementPeriod == 0) revert InvalidSettlementPeriod();
        if (rwaToken == address(0) || outputToken == address(0))
            revert ZeroAddress();

        // Verify market exists
        MarketParams memory params = morpho.idToMarketParams(morphoMarketId);
        if (params.loanToken != outputToken) revert InvalidAdapter();

        rwaConfigs[rwaToken] = RWAConfig({
            adapter: adapter,
            morphoMarketId: morphoMarketId,
            oracle: oracle,
            settlementPeriod: settlementPeriod,
            maxLTV: maxLTV,
            outputToken: outputToken,
            enabled: true
        });

        // Approve adapter to spend RWA tokens
        IERC20(rwaToken).safeApprove(address(adapter), type(uint256).max);

        emit RWAConfigured(
            rwaToken,
            address(adapter),
            morphoMarketId,
            settlementPeriod,
            outputToken
        );
    }

    /// @notice Disable an RWA token
    function disableRWA(address rwaToken) external onlyOwner {
        if (!rwaConfigs[rwaToken].enabled) revert RWANotEnabled();
        rwaConfigs[rwaToken].enabled = false;
        emit RWADisabled(rwaToken);
    }

    /* ═══════════════════════════════════════════ CORE REDEMPTION ═══════════════════════════════════════════ */

    /// @notice Instant redeem RWA tokens for liquid asset
    /// @param rwaToken The RWA token to redeem
    /// @param amount Amount of RWA tokens
    /// @param minOutput Minimum output amount (slippage protection)
    /// @return redemptionId Unique identifier for tracking
    /// @return outputAmount Amount of output token received
    function instantRedeem(
        address rwaToken,
        uint256 amount,
        uint256 minOutput
    )
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 redemptionId, uint256 outputAmount)
    {
        if (amount == 0) revert ZeroAmount();

        RWAConfig storage config = rwaConfigs[rwaToken];
        if (!config.enabled) revert RWANotEnabled();

        // Get expected output from adapter
        (, uint256 expectedOutput) = config.adapter.getRedemptionQuote(
            rwaToken,
            amount
        );

        // Calculate fee based on settlement period
        uint256 fee = calculateRedemptionFee(rwaToken, expectedOutput);
        outputAmount = expectedOutput - fee;

        if (outputAmount < minOutput) revert OutputBelowMinimum();

        // Transfer RWA tokens from user
        IERC20(rwaToken).safeTransferFrom(msg.sender, address(this), amount);

        // Borrow output token from Morpho
        Id borrowedMarketId = _borrowFromMorpho(
            config.outputToken,
            expectedOutput
        );

        // Get borrow shares for tracking
        uint256 borrowShares = marketBorrowShares[config.outputToken][
            borrowedMarketId
        ];

        // Initiate redemption via adapter
        bytes32 adapterRequestId = config.adapter.initiateRedemption(
            rwaToken,
            amount,
            address(this)
        );

        // Generate unique redemption ID
        redemptionId = keccak256(
            abi.encodePacked(msg.sender, rwaToken, amount, redemptionNonce++)
        );

        // Store redemption state
        redemptions[redemptionId] = ActiveRedemption({
            user: msg.sender,
            rwaToken: rwaToken,
            rwaAmount: amount,
            borrowedAmount: expectedOutput,
            borrowShares: borrowShares,
            adapterRequestId: adapterRequestId,
            timestamp: block.timestamp,
            settled: false
        });

        totalPendingRedemptions[rwaToken] += amount;

        // Distribute fee
        TokenState storage outState = tokenState[config.outputToken];
        uint256 protocolCut = (fee * PROTOCOL_FEE_BPS) / BPS_SCALE;
        outState.protocolFees += protocolCut;
        outState.interestReserve += (fee - protocolCut);

        // Transfer output to user
        IERC20(config.outputToken).safeTransfer(msg.sender, outputAmount);

        emit InstantRedemption(
            redemptionId,
            msg.sender,
            rwaToken,
            amount,
            outputAmount,
            fee
        );
    }

    /// @notice Settle a completed redemption (repay Morpho loan)
    /// @param redemptionId The redemption to settle
    function settleRedemption(bytes32 redemptionId) external nonReentrant {
        ActiveRedemption storage redemption = redemptions[redemptionId];
        if (redemption.user == address(0)) revert RedemptionNotFound();
        if (redemption.settled) revert RedemptionAlreadySettled();

        RWAConfig storage config = rwaConfigs[redemption.rwaToken];

        // Check if redemption is complete
        if (!config.adapter.isRedemptionComplete(redemption.adapterRequestId)) {
            revert RedemptionNotComplete();
        }

        // Claim redeemed tokens
        uint256 redeemedAmount = config.adapter.claimRedemption(
            redemption.adapterRequestId
        );

        // Handle surplus or shortfall before repaying to ensure accounting is correct
        uint256 surplus = 0;
        if (redeemedAmount > redemption.borrowedAmount) {
            surplus = redeemedAmount - redemption.borrowedAmount;
            tokenState[config.outputToken].interestReserve += surplus;
        } else if (redeemedAmount < redemption.borrowedAmount) {
            uint256 shortfall = redemption.borrowedAmount - redeemedAmount;
            TokenState storage state = tokenState[config.outputToken];
            if (state.protocolFees >= shortfall) {
                state.protocolFees -= shortfall;
            } else {
                uint256 remaining = shortfall - state.protocolFees;
                state.protocolFees = 0;
                if (state.interestReserve >= remaining) {
                    state.interestReserve -= remaining;
                } else {
                    remaining -= state.interestReserve;
                    state.interestReserve = 0;
                    if (state.localLiquidity >= remaining) {
                        state.localLiquidity -= remaining;
                    } else {
                        state.localLiquidity = 0;
                    }
                }
            }
        }

        // Repay Morpho loan
        uint256 repaidAmount = _repayMorpho(
            config.outputToken,
            redemption.borrowedAmount
        );

        // Mark as settled
        redemption.settled = true;
        totalPendingRedemptions[redemption.rwaToken] -= redemption.rwaAmount;

        emit RedemptionSettled(
            redemptionId,
            redeemedAmount,
            repaidAmount,
            surplus
        );
    }

    /// @notice Liquidate a stale redemption that hasn't settled
    /// @param redemptionId The stale redemption
    function liquidateStaleRedemption(
        bytes32 redemptionId
    ) external nonReentrant {
        ActiveRedemption storage redemption = redemptions[redemptionId];
        if (redemption.user == address(0)) revert RedemptionNotFound();
        if (redemption.settled) revert RedemptionAlreadySettled();

        RWAConfig storage config = rwaConfigs[redemption.rwaToken];

        // Check if redemption is stale
        uint256 deadline = redemption.timestamp +
            config.settlementPeriod +
            STALE_BUFFER;
        if (block.timestamp < deadline) revert RedemptionNotStale();

        // Liquidator can attempt to complete redemption
        uint256 redeemedAmount = 0;
        if (config.adapter.isRedemptionComplete(redemption.adapterRequestId)) {
            redeemedAmount = config.adapter.claimRedemption(
                redemption.adapterRequestId
            );
        }

        // Handle surplus or shortfall
        uint256 surplus = 0;
        if (redeemedAmount > redemption.borrowedAmount) {
            surplus = redeemedAmount - redemption.borrowedAmount;
            tokenState[config.outputToken].interestReserve += surplus;
        } else if (
            redeemedAmount > 0 && redeemedAmount < redemption.borrowedAmount
        ) {
            uint256 shortfall = redemption.borrowedAmount - redeemedAmount;
            TokenState storage state = tokenState[config.outputToken];
            if (state.protocolFees >= shortfall) {
                state.protocolFees -= shortfall;
            } else {
                uint256 remaining = shortfall - state.protocolFees;
                state.protocolFees = 0;
                if (state.interestReserve >= remaining) {
                    state.interestReserve -= remaining;
                } else {
                    remaining -= state.interestReserve;
                    state.interestReserve = 0;
                    if (state.localLiquidity >= remaining) {
                        state.localLiquidity -= remaining;
                    } else {
                        state.localLiquidity = 0;
                    }
                }
            }
        }

        // Repay what we can
        uint256 repaidAmount = 0;
        if (redeemedAmount > 0) {
            repaidAmount = _repayMorpho(
                config.outputToken,
                redemption.borrowedAmount
            );
        }

        // Reward liquidator
        uint256 reward = (redeemedAmount * LIQUIDATION_BONUS_BPS) / BPS_SCALE;
        if (
            reward > 0 && redeemedAmount >= redemption.borrowedAmount + reward
        ) {
            IERC20(config.outputToken).safeTransfer(msg.sender, reward);
        }

        redemption.settled = true;
        totalPendingRedemptions[redemption.rwaToken] -= redemption.rwaAmount;

        emit StaleRedemptionLiquidated(redemptionId, msg.sender, reward);
    }

    /* ═══════════════════════════════════════════ FEE CALCULATION ═══════════════════════════════════════════ */

    /// @notice Calculate fee for instant redemption based on settlement period
    /// @param rwaToken The RWA token
    /// @param amount The output amount
    /// @return fee Total fee including interest buffer
    function calculateRedemptionFee(
        address rwaToken,
        uint256 amount
    ) public view returns (uint256 fee) {
        RWAConfig storage config = rwaConfigs[rwaToken];
        uint256 period = config.settlementPeriod;
        uint256 feeBps;

        // Tier-based fee structure
        if (period < 1 hours) {
            feeBps = INSTANT_FEE_BPS;
        } else if (period < 1 days) {
            feeBps = SAME_DAY_FEE_BPS;
        } else if (period < 7 days) {
            feeBps = SHORT_FEE_BPS;
        } else if (period < 30 days) {
            feeBps = STANDARD_FEE_BPS;
        } else {
            feeBps = EXTENDED_FEE_BPS;
        }

        uint256 baseFee = (amount * feeBps) / BPS_SCALE;

        // Add interest buffer estimate (uses inherited _estimateInterestCost)
        uint256 interestBuffer = _estimateInterestCost(
            config.outputToken,
            amount,
            period
        );

        // Apply interest buffer multiplier for safety
        interestBuffer = (interestBuffer * INTEREST_BUFFER) / WAD_UNIT;

        fee = baseFee + interestBuffer;
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Get redemption details
    function getRedemption(
        bytes32 redemptionId
    ) external view returns (ActiveRedemption memory) {
        return redemptions[redemptionId];
    }

    /// @notice Check if an RWA token is enabled
    function isRWAEnabled(address rwaToken) external view returns (bool) {
        return rwaConfigs[rwaToken].enabled;
    }

    /// @notice Quote instant redemption output
    /// @param rwaToken The RWA token
    /// @param amount Input amount
    /// @return outputAmount Net output after fees
    /// @return fee Total fee
    function quoteInstantRedeem(
        address rwaToken,
        uint256 amount
    ) external view returns (uint256 outputAmount, uint256 fee) {
        RWAConfig storage config = rwaConfigs[rwaToken];
        if (!config.enabled) return (0, 0);

        (, uint256 expectedOutput) = config.adapter.getRedemptionQuote(
            rwaToken,
            amount
        );
        fee = calculateRedemptionFee(rwaToken, expectedOutput);
        outputAmount = expectedOutput - fee;
    }
}
