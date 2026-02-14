// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {BaseRedemptionAdapter} from "./BaseRedemptionAdapter.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";

/// @notice Minimal interface for Maple pool
interface IMaplePool {
    function requestRedeem(
        uint256 shares,
        address owner
    ) external returns (uint256 escrowShares);

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function previewRedeem(uint256 shares) external view returns (uint256);

    function unrealizedLosses() external view returns (uint256);
}

/// @notice Interface for Maple withdrawal manager
interface IMapleWithdrawalManager {
    function processRedemptions(uint256 shares) external;

    function isInExitWindow(address owner) external view returns (bool);

    function lockedShares(address owner) external view returns (uint256);
}

/// @title MapleAdapter
/// @notice Adapter for Maple Finance pool tokens
/// @dev Maple has epoch-based withdrawals with exit windows
contract MapleAdapter is BaseRedemptionAdapter {
    using SafeTransferLib for IERC20;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    /// @notice Maple pool for each LP token
    mapping(address lpToken => address pool) public pools;

    /// @notice Withdrawal manager for each pool
    mapping(address pool => address manager) public withdrawalManagers;

    /// @notice Track redemption requests
    struct MapleRequest {
        address lpToken;
        address pool;
        uint256 shares;
        address receiver;
        uint256 timestamp;
        bool claimed;
    }
    mapping(bytes32 => MapleRequest) public requests;

    uint256 private _requestNonce;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event PoolConfigured(
        address indexed lpToken,
        address indexed pool,
        address withdrawalManager
    );

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error PoolNotConfigured();
    error NotInExitWindow();
    error AlreadyClaimed();

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(
        address _redemptionFacility,
        address _owner
    ) BaseRedemptionAdapter(_redemptionFacility, _owner) {}

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    /// @notice Configure Maple pool for LP token
    function configurePool(
        address lpToken,
        address pool,
        address withdrawalManager
    ) external onlyOwner {
        if (lpToken == address(0) || pool == address(0)) revert ZeroAddress();
        pools[lpToken] = pool;
        withdrawalManagers[pool] = withdrawalManager;
        emit PoolConfigured(lpToken, pool, withdrawalManager);
    }

    /* ═══════════════════════════════════════════ REDEMPTION ═══════════════════════════════════════════ */

    /// @inheritdoc BaseRedemptionAdapter
    function initiateRedemption(
        address rwaToken,
        uint256 amount,
        address receiver
    ) external override onlyFacility returns (bytes32 requestId) {
        _validateToken(rwaToken);

        address pool = pools[rwaToken];
        if (pool == address(0)) revert PoolNotConfigured();

        // Transfer LP tokens to adapter
        IERC20(rwaToken).safeTransferFrom(msg.sender, address(this), amount);

        // Approve and request redemption
        IERC20(rwaToken).approve(pool, amount);
        IMaplePool(pool).requestRedeem(amount, address(this));

        // Generate request ID
        requestId = keccak256(
            abi.encodePacked(rwaToken, receiver, amount, _requestNonce++)
        );

        requests[requestId] = MapleRequest({
            lpToken: rwaToken,
            pool: pool,
            shares: amount,
            receiver: receiver,
            timestamp: block.timestamp,
            claimed: false
        });
    }

    /// @inheritdoc BaseRedemptionAdapter
    function isRedemptionComplete(
        bytes32 requestId
    ) external view override returns (bool) {
        MapleRequest storage req = requests[requestId];
        if (req.pool == address(0) || req.claimed) return false;

        address manager = withdrawalManagers[req.pool];
        if (manager == address(0)) {
            // No withdrawal manager, check if shares are unlocked
            return true;
        }

        // Check if in exit window
        return IMapleWithdrawalManager(manager).isInExitWindow(address(this));
    }

    /// @inheritdoc BaseRedemptionAdapter
    function claimRedemption(
        bytes32 requestId
    ) external override onlyFacility returns (uint256 amount) {
        MapleRequest storage req = requests[requestId];
        if (req.pool == address(0)) revert PoolNotConfigured();
        if (req.claimed) revert AlreadyClaimed();

        address manager = withdrawalManagers[req.pool];
        if (manager != address(0)) {
            if (
                !IMapleWithdrawalManager(manager).isInExitWindow(address(this))
            ) {
                revert NotInExitWindow();
            }
        }

        // Redeem from pool
        amount = IMaplePool(req.pool).redeem(
            req.shares,
            req.receiver,
            address(this)
        );

        req.claimed = true;
    }

    /// @inheritdoc BaseRedemptionAdapter
    function protocolName() external pure override returns (string memory) {
        return "Maple Finance";
    }

    /* ═══════════════════════════════════════════ INTERNAL ═══════════════════════════════════════════ */

    /// @dev Calculate expected output using pool's conversion and accounting for losses
    function _calculateExpectedOutput(
        address rwaToken,
        uint256 amount
    ) internal view override returns (uint256) {
        address pool = pools[rwaToken];
        if (pool == address(0)) return amount;

        try IMaplePool(pool).previewRedeem(amount) returns (uint256 assets) {
            return assets;
        } catch {
            try IMaplePool(pool).convertToAssets(amount) returns (
                uint256 assets
            ) {
                return assets;
            } catch {
                return amount;
            }
        }
    }
}
