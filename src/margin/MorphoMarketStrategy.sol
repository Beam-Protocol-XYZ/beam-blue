// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, Market, Position, IMorpho} from "../interfaces/IMorpho.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../libraries/MarketParamsLib.sol";

/// @title MorphoMarketStrategy
/// @notice Adapter that wraps Morpho supply as an ERC-4626-like strategy
/// @dev Allows MarginEngine to treat Morpho market supply as a strategy target
contract MorphoMarketStrategy is IStrategy {
    using SafeTransferLib for IERC20;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /* ═══════════════════════════════════════════ IMMUTABLES ═══════════════════════════════════════════ */

    IMorpho public immutable morpho;
    Id public immutable marketId;
    address public immutable loanToken;

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(address _morpho, Id _marketId) {
        morpho = IMorpho(_morpho);
        marketId = _marketId;

        MarketParams memory params = morpho.idToMarketParams(_marketId);
        loanToken = params.loanToken;

        // Approve Morpho to spend loan token
        IERC20(loanToken).safeApprove(_morpho, type(uint256).max);
    }

    /* ═══════════════════════════════════════════ DEPOSIT/WITHDRAW ═══════════════════════════════════════════ */

    /// @notice Deposit assets into Morpho market as supply
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        IERC20(loanToken).safeTransferFrom(msg.sender, address(this), assets);

        MarketParams memory params = morpho.idToMarketParams(marketId);
        (, shares) = morpho.supply(params, assets, 0, receiver, "");
    }

    /// @notice Withdraw assets from Morpho market
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares) {
        MarketParams memory params = morpho.idToMarketParams(marketId);
        (, shares) = morpho.withdraw(params, assets, 0, owner, receiver);
    }

    /// @notice Redeem shares for assets from Morpho market
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets) {
        MarketParams memory params = morpho.idToMarketParams(marketId);
        (assets, ) = morpho.withdraw(params, 0, shares, owner, receiver);
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares) {
        Market memory market = morpho.market(marketId);
        shares = assets.toSharesDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );
    }

    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256 shares) {
        Market memory market = morpho.market(marketId);
        shares = assets.toSharesUp(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );
    }

    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets) {
        Market memory market = morpho.market(marketId);
        assets = shares.toAssetsDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );
    }

    function convertToAssets(
        uint256 shares
    ) external view returns (uint256 assets) {
        Market memory market = morpho.market(marketId);
        assets = shares.toAssetsDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );
    }

    function convertToShares(
        uint256 assets
    ) external view returns (uint256 shares) {
        Market memory market = morpho.market(marketId);
        shares = assets.toSharesDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );
    }

    function asset() external view returns (address) {
        return loanToken;
    }

    function totalAssets() external view returns (uint256) {
        Market memory market = morpho.market(marketId);
        return market.totalSupplyAssets;
    }

    function maxDeposit(address) external view returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        Position memory pos = morpho.position(marketId, owner);
        uint256 supplyShares = pos.supplyShares;
        Market memory market = morpho.market(marketId);
        uint256 suppliedAssets = uint256(supplyShares).toAssetsDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );

        // Limited by available liquidity
        uint256 liquidity = market.totalSupplyAssets > market.totalBorrowAssets
            ? market.totalSupplyAssets - market.totalBorrowAssets
            : 0;
        return suppliedAssets < liquidity ? suppliedAssets : liquidity;
    }
}
