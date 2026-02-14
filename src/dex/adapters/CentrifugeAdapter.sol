// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {BaseRedemptionAdapter} from "./BaseRedemptionAdapter.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";

/// @notice Minimal interface for Centrifuge pools
interface ICentrifugePool {
    function requestRedeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256);

    function claimRedeem(
        address receiver,
        address owner
    ) external returns (uint256);

    function pendingRedeemRequest(
        address owner
    ) external view returns (uint256);

    function maxRedeem(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title CentrifugeAdapter
/// @notice Adapter for Centrifuge pool token redemptions
/// @dev Integrates with Centrifuge's ERC-7540 async redemption pattern
contract CentrifugeAdapter is BaseRedemptionAdapter {
    using SafeTransferLib for IERC20;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    /// @notice Centrifuge pool for each RWA token
    mapping(address rwaToken => address pool) public pools;

    /// @notice Track redemption requests (rwaToken => owner => requestId)
    mapping(address => mapping(address => bytes32)) public pendingRequests;

    /// @notice Request details
    struct RedemptionRequest {
        address rwaToken;
        address owner;
        uint256 shares;
        uint256 timestamp;
    }
    mapping(bytes32 => RedemptionRequest) public requests;

    uint256 private _requestNonce;

    /* ═══════════════════════════════════════════ EVENTS ═══════════════════════════════════════════ */

    event PoolConfigured(address indexed rwaToken, address indexed pool);

    /* ═══════════════════════════════════════════ ERRORS ═══════════════════════════════════════════ */

    error PoolNotConfigured();
    error RedemptionPending();

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(
        address _redemptionFacility,
        address _owner
    ) BaseRedemptionAdapter(_redemptionFacility, _owner) {}

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    /// @notice Configure pool for an RWA token
    function configurePool(address rwaToken, address pool) external onlyOwner {
        if (rwaToken == address(0) || pool == address(0)) revert ZeroAddress();
        pools[rwaToken] = pool;
        emit PoolConfigured(rwaToken, pool);
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

        // Transfer shares to adapter
        IERC20(rwaToken).safeTransferFrom(msg.sender, address(this), amount);

        // Approve pool
        IERC20(rwaToken).approve(pool, amount);

        // Request redemption via ERC-7540 pattern
        ICentrifugePool(pool).requestRedeem(amount, receiver, address(this));

        // Generate request ID
        requestId = keccak256(
            abi.encodePacked(rwaToken, msg.sender, amount, _requestNonce++)
        );

        requests[requestId] = RedemptionRequest({
            rwaToken: rwaToken,
            owner: receiver,
            shares: amount,
            timestamp: block.timestamp
        });

        pendingRequests[rwaToken][receiver] = requestId;
    }

    /// @inheritdoc BaseRedemptionAdapter
    function isRedemptionComplete(
        bytes32 requestId
    ) external view override returns (bool) {
        RedemptionRequest storage req = requests[requestId];
        if (req.rwaToken == address(0)) return false;

        address pool = pools[req.rwaToken];
        if (pool == address(0)) return false;

        // Check if redemption can be claimed
        return ICentrifugePool(pool).maxRedeem(req.owner) >= req.shares;
    }

    /// @inheritdoc BaseRedemptionAdapter
    function claimRedemption(
        bytes32 requestId
    ) external override onlyFacility returns (uint256 amount) {
        RedemptionRequest storage req = requests[requestId];
        if (req.rwaToken == address(0)) revert TokenNotSupported();

        address pool = pools[req.rwaToken];
        if (pool == address(0)) revert PoolNotConfigured();

        // Claim from Centrifuge pool
        amount = ICentrifugePool(pool).claimRedeem(
            redemptionFacility,
            req.owner
        );

        // Clear pending request
        delete pendingRequests[req.rwaToken][req.owner];
    }

    /// @inheritdoc BaseRedemptionAdapter
    function protocolName() external pure override returns (string memory) {
        return "Centrifuge";
    }

    /* ═══════════════════════════════════════════ INTERNAL ═══════════════════════════════════════════ */

    /// @dev Calculate expected output using pool's conversion rate
    function _calculateExpectedOutput(
        address rwaToken,
        uint256 amount
    ) internal view override returns (uint256) {
        address pool = pools[rwaToken];
        if (pool == address(0)) return amount;

        try ICentrifugePool(pool).convertToAssets(amount) returns (
            uint256 assets
        ) {
            return assets;
        } catch {
            return amount;
        }
    }
}
