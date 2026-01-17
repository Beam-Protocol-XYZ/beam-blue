// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

/// @title IStrategy
/// @notice Unified interface for deployment strategies (vaults, markets)
/// @dev Compatible with ERC-4626 vaults and Morpho market adapters
interface IStrategy {
    /// @notice Deposit assets into the strategy
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive the shares
    /// @return shares Amount of shares minted
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Withdraw assets from the strategy
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address to receive the assets
    /// @param owner Address whose shares to burn
    /// @return shares Amount of shares burned
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    /// @notice Redeem shares for assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive the assets
    /// @param owner Address whose shares to burn
    /// @return assets Amount of assets received
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Preview the amount of shares for a deposit
    /// @param assets Amount of assets to deposit
    /// @return shares Expected shares to receive
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Preview the amount of shares burned for a withdrawal
    /// @param assets Amount of assets to withdraw
    /// @return shares Expected shares to burn
    function previewWithdraw(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice Preview the amount of assets for a redemption
    /// @param shares Amount of shares to redeem
    /// @return assets Expected assets to receive
    function previewRedeem(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Convert shares to assets at current exchange rate
    /// @param shares Amount of shares
    /// @return assets Equivalent amount of assets
    function convertToAssets(
        uint256 shares
    ) external view returns (uint256 assets);

    /// @notice Convert assets to shares at current exchange rate
    /// @param assets Amount of assets
    /// @return shares Equivalent amount of shares
    function convertToShares(
        uint256 assets
    ) external view returns (uint256 shares);

    /// @notice The underlying asset of the strategy
    /// @return asset Address of the underlying token
    function asset() external view returns (address);

    /// @notice Total assets under management
    /// @return totalAssets Total assets in the strategy
    function totalAssets() external view returns (uint256);

    /// @notice Maximum deposit allowed for a receiver
    /// @param receiver Address to check
    /// @return maxAssets Maximum assets that can be deposited
    function maxDeposit(address receiver) external view returns (uint256);

    /// @notice Maximum withdrawal allowed for an owner
    /// @param owner Address to check
    /// @return maxAssets Maximum assets that can be withdrawn
    function maxWithdraw(address owner) external view returns (uint256);
}
