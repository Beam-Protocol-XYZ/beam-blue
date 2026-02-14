// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {BaseRedemptionAdapter} from "./BaseRedemptionAdapter.sol";
import {IRedemptionAdapter} from "../interfaces/IRedemptionAdapter.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";

/// @notice Minimal interface for Ondo redemption
interface IOndoRedemption {
    function requestRedemption(
        address token,
        uint256 amount
    ) external returns (bytes32);

    function claimRedemption(bytes32 requestId) external returns (uint256);

    function isRedemptionReady(bytes32 requestId) external view returns (bool);

    function getRedemptionAmount(
        bytes32 requestId
    ) external view returns (uint256);
}

/// @notice Interface for Ondo token price
interface IOndoToken {
    function getPrice() external view returns (uint256);
}

/// @title OndoAdapter
/// @notice Adapter for Ondo Finance RWA tokens (USDY, OUSG)
/// @dev Integrates with Ondo's redemption mechanism
contract OndoAdapter is BaseRedemptionAdapter {
    using SafeTransferLib for IERC20;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    /// @notice Ondo redemption contract
    IOndoRedemption public ondoRedemption;

    /// @notice Track request IDs to output amounts
    mapping(bytes32 => uint256) public requestAmounts;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event OndoRedemptionSet(address indexed ondoRedemption);

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error OndoRedemptionNotSet();

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(
        address _redemptionFacility,
        address _owner,
        address _ondoRedemption
    ) BaseRedemptionAdapter(_redemptionFacility, _owner) {
        if (_ondoRedemption != address(0)) {
            ondoRedemption = IOndoRedemption(_ondoRedemption);
        }
    }

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    function setOndoRedemption(address _ondoRedemption) external onlyOwner {
        if (_ondoRedemption == address(0)) revert ZeroAddress();
        ondoRedemption = IOndoRedemption(_ondoRedemption);
        emit OndoRedemptionSet(_ondoRedemption);
    }

    /* ═══════════════════════════════════════════ REDEMPTION ═══════════════════════════════════════════ */

    /// @inheritdoc IRedemptionAdapter
    function initiateRedemption(
        address rwaToken,
        uint256 amount,
        address /* receiver */
    ) external override onlyFacility returns (bytes32 requestId) {
        _validateToken(rwaToken);
        if (address(ondoRedemption) == address(0))
            revert OndoRedemptionNotSet();

        // Transfer RWA tokens to this adapter
        IERC20(rwaToken).safeTransferFrom(msg.sender, address(this), amount);

        // Approve Ondo redemption contract
        IERC20(rwaToken).safeApprove(address(ondoRedemption), amount);

        // Request redemption from Ondo
        requestId = ondoRedemption.requestRedemption(rwaToken, amount);

        // Store expected output
        requestAmounts[requestId] = _calculateExpectedOutput(rwaToken, amount);
    }

    /// @inheritdoc IRedemptionAdapter
    function isRedemptionComplete(
        bytes32 requestId
    ) external view override returns (bool) {
        if (address(ondoRedemption) == address(0)) return false;
        return ondoRedemption.isRedemptionReady(requestId);
    }

    /// @inheritdoc IRedemptionAdapter
    function claimRedemption(
        bytes32 requestId
    ) external override onlyFacility returns (uint256 amount) {
        if (address(ondoRedemption) == address(0))
            revert OndoRedemptionNotSet();

        amount = ondoRedemption.claimRedemption(requestId);

        // Transfer output back to facility
        // Note: Ondo typically pays out in USDC
        // The output token should be transferred by Ondo to this contract
        // We then forward it to the redemption facility
    }

    /// @inheritdoc IRedemptionAdapter
    function protocolName() external pure override returns (string memory) {
        return "Ondo Finance";
    }

    /* ═══════════════════════════════════════════ INTERNAL ═══════════════════════════════════════════ */

    /// @dev Calculate expected USDC output based on Ondo token price
    function _calculateExpectedOutput(
        address rwaToken,
        uint256 amount
    ) internal view override returns (uint256) {
        // USDY/OUSG typically have a price function
        // Returns rebasing value in USDC terms
        try IOndoToken(rwaToken).getPrice() returns (uint256 price) {
            // Price is typically in 1e18 scale
            return (amount * price) / 1e18;
        } catch {
            // Fallback: assume 1:1 for stablecoins
            return amount;
        }
    }
}
