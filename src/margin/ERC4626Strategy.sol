// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";

/* ═══════════════════════════════════════════ INTERFACES ═══════════════════════════════════════════ */

/// @notice Minimal ERC-4626 interface
interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
}

/// @title ERC4626Strategy
/// @notice Adapter that wraps any ERC-4626 vault as an IStrategy
/// @dev Thin wrapper for compatibility with standard ERC-4626 vaults
contract ERC4626Strategy is IStrategy {
    using SafeTransferLib for IERC20;

    /* ═══════════════════════════════════════════ IMMUTABLES ═══════════════════════════════════════════ */

    IERC4626 public immutable vault;
    address public immutable underlyingAsset;

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(address _vault) {
        vault = IERC4626(_vault);
        underlyingAsset = vault.asset();

        // Approve vault to spend underlying
        IERC20(underlyingAsset).safeApprove(_vault, type(uint256).max);
    }

    /* ═══════════════════════════════════════════ DEPOSIT/WITHDRAW ═══════════════════════════════════════════ */

    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        IERC20(underlyingAsset).safeTransferFrom(
            msg.sender,
            address(this),
            assets
        );
        shares = vault.deposit(assets, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares) {
        shares = vault.withdraw(assets, receiver, owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        assets = vault.redeem(shares, receiver, owner);
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares) {
        return vault.previewDeposit(assets);
    }

    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256 shares) {
        return vault.previewWithdraw(assets);
    }

    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets) {
        return vault.previewRedeem(shares);
    }

    function convertToAssets(
        uint256 shares
    ) external view returns (uint256 assets) {
        return vault.convertToAssets(shares);
    }

    function convertToShares(
        uint256 assets
    ) external view returns (uint256 shares) {
        return vault.convertToShares(assets);
    }

    function asset() external view returns (address) {
        return underlyingAsset;
    }

    function totalAssets() external view returns (uint256) {
        return vault.totalAssets();
    }

    function maxDeposit(address receiver) external view returns (uint256) {
        return vault.maxDeposit(receiver);
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return vault.maxWithdraw(owner);
    }
}
