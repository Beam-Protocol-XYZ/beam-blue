// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {BaseRedemptionAdapter} from "./BaseRedemptionAdapter.sol";
import {IRedemptionAdapter} from "../interfaces/IRedemptionAdapter.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";

/// @notice Minimal interface for Backed token redemption
interface IBackedToken {
    function burn(address account, uint256 amount) external;

    function getNav() external view returns (uint256);
}

/// @notice Interface for Backed redemption manager
interface IBackedRedemption {
    function requestRedemption(
        address token,
        uint256 amount,
        address beneficiary
    ) external returns (bytes32);

    function executeRedemption(bytes32 requestId) external returns (uint256);

    function isRedemptionReady(bytes32 requestId) external view returns (bool);

    function getRedemptionDetails(
        bytes32 requestId
    )
        external
        view
        returns (
            address token,
            uint256 amount,
            address beneficiary,
            bool executed
        );
}

/// @title BackedAdapter
/// @notice Adapter for Backed Finance tokenized securities (bIB01, bCSPX, etc.)
/// @dev Backed tokens represent tokenized securities with T+2 settlement
contract BackedAdapter is BaseRedemptionAdapter {
    using SafeTransferLib for IERC20;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    /// @notice Backed redemption manager
    IBackedRedemption public backedRedemption;

    /// @notice NAV decimals for price calculation
    uint256 public constant NAV_DECIMALS = 18;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event BackedRedemptionSet(address indexed backedRedemption);

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error BackedRedemptionNotSet();

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(
        address _redemptionFacility,
        address _owner,
        address _backedRedemption
    ) BaseRedemptionAdapter(_redemptionFacility, _owner) {
        if (_backedRedemption != address(0)) {
            backedRedemption = IBackedRedemption(_backedRedemption);
        }
    }

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    function setBackedRedemption(address _backedRedemption) external onlyOwner {
        if (_backedRedemption == address(0)) revert ZeroAddress();
        backedRedemption = IBackedRedemption(_backedRedemption);
        emit BackedRedemptionSet(_backedRedemption);
    }

    /* ═══════════════════════════════════════════ REDEMPTION ═══════════════════════════════════════════ */

    /// @inheritdoc IRedemptionAdapter
    function initiateRedemption(
        address rwaToken,
        uint256 amount,
        address receiver
    ) external override onlyFacility returns (bytes32 requestId) {
        _validateToken(rwaToken);
        if (address(backedRedemption) == address(0))
            revert BackedRedemptionNotSet();

        // Transfer tokens to adapter
        IERC20(rwaToken).safeTransferFrom(msg.sender, address(this), amount);

        // Approve redemption manager
        IERC20(rwaToken).safeApprove(address(backedRedemption), amount);

        // Request redemption
        requestId = backedRedemption.requestRedemption(
            rwaToken,
            amount,
            receiver
        );
    }

    /// @inheritdoc IRedemptionAdapter
    function isRedemptionComplete(
        bytes32 requestId
    ) external view override returns (bool) {
        if (address(backedRedemption) == address(0)) return false;
        return backedRedemption.isRedemptionReady(requestId);
    }

    /// @inheritdoc IRedemptionAdapter
    function claimRedemption(
        bytes32 requestId
    ) external override onlyFacility returns (uint256 amount) {
        if (address(backedRedemption) == address(0))
            revert BackedRedemptionNotSet();

        // Execute the redemption
        amount = backedRedemption.executeRedemption(requestId);
    }

    /// @inheritdoc IRedemptionAdapter
    function protocolName() external pure override returns (string memory) {
        return "Backed Finance";
    }

    /* ═══════════════════════════════════════════ INTERNAL ═══════════════════════════════════════════ */

    /// @dev Calculate expected output based on NAV
    function _calculateExpectedOutput(
        address rwaToken,
        uint256 amount
    ) internal view override returns (uint256) {
        // Backed tokens have NAV (Net Asset Value) representing price
        try IBackedToken(rwaToken).getNav() returns (uint256 nav) {
            // NAV is typically in 18 decimals
            return (amount * nav) / (10 ** NAV_DECIMALS);
        } catch {
            // Fallback: assume 1:1
            return amount;
        }
    }
}
