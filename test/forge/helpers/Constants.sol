// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

library Constants {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    
    // Test specific constants
    uint256 internal constant BLOCK_TIME = 1;
    uint256 internal constant HIGH_COLLATERAL_AMOUNT = 1e35;
    uint256 internal constant MIN_TEST_AMOUNT = 100;
    uint256 internal constant MAX_TEST_AMOUNT = 1e32;
    
    // Bounds
    uint256 internal constant MIN_TEST_LLTV = 0.01e18;
    uint256 internal constant MAX_TEST_LLTV = 0.99e18;
    uint256 internal constant DEFAULT_TEST_LLTV = 0.8e18;
    
    uint256 internal constant MIN_COLLATERAL_PRICE = 1e10;
    uint256 internal constant MAX_COLLATERAL_PRICE = 1e40;
    uint256 internal constant MAX_COLLATERAL_ASSETS = type(uint128).max;

    uint256 internal constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
}
