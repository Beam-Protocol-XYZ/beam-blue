// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../../lib/forge-std/src/Test.sol";
import {console} from "../../../../lib/forge-std/src/console.sol";

import {Id, MarketParams, IMorpho} from "../../../../src/interfaces/IMorpho.sol";
import {IMarginEngine} from "../../../../src/interfaces/IMarginEngine.sol";
import {IStrategy} from "../../../../src/interfaces/IStrategy.sol";
import {MarginEngine} from "../../../../src/margin/MarginEngine.sol";
import {MorphoMarketStrategy} from "../../../../src/margin/MorphoMarketStrategy.sol";
import {ERC20Mock} from "../../../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../../../src/mocks/OracleMock.sol";
import {IrmMock} from "../../../../src/mocks/IrmMock.sol";
import {Morpho} from "../../../../src/Morpho.sol";
import {MathLib, WAD} from "../../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {Constants} from "../../helpers/Constants.sol";

/// @title MarginEngineTest
/// @notice Tests for MarginEngine with Morpho's exact health formula
contract MarginEngineTest is Test {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /* ═══════════════════════════════════════════ CONSTANTS ═══════════════════════════════════════════ */

    uint256 internal constant ORACLE_PRICE_SCALE = Constants.ORACLE_PRICE_SCALE;
    uint256 internal constant DEFAULT_LLTV = 0.9e18; // 90% LLTV
    uint256 internal constant DEFAULT_MAX_LEVERAGE = 10e18; // 10x
    uint256 internal constant MORPHO_LLTV = 0.8e18;

    /* ═══════════════════════════════════════════ STATE ═══════════════════════════════════════════ */

    IMorpho internal morpho;
    MarginEngine internal marginEngine;
    MorphoMarketStrategy internal strategy;

    ERC20Mock internal collateralToken;
    ERC20Mock internal loanToken;
    OracleMock internal pairOracle;
    IrmMock internal irm;

    MarketParams internal marketParams;
    Id internal marketId;

    address internal OWNER;
    address internal USER;
    address internal LIQUIDATOR;
    address internal SUPPLIER;

    /* ═══════════════════════════════════════════ SETUP ═══════════════════════════════════════════ */

    function setUp() public virtual {
        OWNER = makeAddr("Owner");
        USER = makeAddr("User");
        LIQUIDATOR = makeAddr("Liquidator");
        SUPPLIER = makeAddr("Supplier");

        morpho = IMorpho(address(new Morpho(OWNER)));

        collateralToken = new ERC20Mock();
        vm.label(address(collateralToken), "CollateralToken");

        loanToken = new ERC20Mock();
        vm.label(address(loanToken), "LoanToken");

        // Oracle: 1 collateral = 1 loan token (1:1) - used by MarginEngine pair config
        pairOracle = new OracleMock();
        pairOracle.setPrice(ORACLE_PRICE_SCALE);

        irm = new IrmMock();

        vm.startPrank(OWNER);
        morpho.enableIrm(address(irm));
        // Enable lltv=0 for uncollateralized markets
        morpho.enableLltv(0);
        vm.stopPrank();

        // Create an UNCOLLATERALIZED Morpho market for MarginEngine borrowing
        // This is required because Morpho's _isUncollateralizedMarketBorrower
        // checks: collateralToken==0, oracle==0, lltv==0
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        marketId = marketParams.id();

        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        marginEngine = new MarginEngine(address(morpho), OWNER);
        vm.label(address(marginEngine), "MarginEngine");

        // Whitelist MarginEngine as uncollateralized borrower
        vm.prank(OWNER);
        morpho.setUncollateralizedBorrower(
            marketId,
            address(marginEngine),
            true
        );

        strategy = new MorphoMarketStrategy(address(morpho), marketId);
        vm.label(address(strategy), "Strategy");

        // Configure margin pair — MarginEngine enforces its own LLTV and leverage checks
        vm.startPrank(OWNER);
        marginEngine.setMarginPairConfig(
            address(collateralToken),
            address(loanToken),
            address(pairOracle),
            marketId,
            DEFAULT_LLTV, // 90% LLTV for margin health
            DEFAULT_MAX_LEVERAGE // 10x max leverage
        );
        marginEngine.setStrategyWhitelist(address(strategy), true);
        vm.stopPrank();

        // Supply liquidity into the uncollateralized market
        loanToken.setBalance(SUPPLIER, 1_000_000e18);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1_000_000e18, 0, SUPPLIER, "");
        vm.stopPrank();

        // Setup user
        collateralToken.setBalance(USER, 100_000e18);
        vm.startPrank(USER);
        collateralToken.approve(address(marginEngine), type(uint256).max);
        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════ OPEN POSITION TESTS ═══════════════════════════════════════════ */

    function test_openPosition_success() public {
        uint256 collateralAmount = 1000e18;
        uint256 borrowAmount = 5000e18; // 5x leverage

        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            collateralAmount,
            borrowAmount,
            address(strategy)
        );

        IMarginEngine.Position memory pos = marginEngine.getPosition(
            positionId
        );
        assertEq(pos.user, USER);
        assertEq(pos.collateralAmount, collateralAmount);
        assertTrue(pos.borrowShares > 0);
        assertTrue(pos.strategyShares > 0);
        assertTrue(pos.active);
    }

    function test_openPosition_atMaxLeverage() public {
        uint256 collateralAmount = 1000e18;
        // At 1:1 oracle, 10x leverage means borrow 10000
        uint256 borrowAmount = 10000e18;

        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            collateralAmount,
            borrowAmount,
            address(strategy)
        );

        assertTrue(marginEngine.getPosition(positionId).active);
    }

    function test_openPosition_reverts_exceedsMaxLeverage() public {
        vm.prank(USER);
        vm.expectRevert(IMarginEngine.ExceedsMaxLeverage.selector);
        marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            11000e18, // 11x > 10x max
            address(strategy)
        );
    }

    /* ═══════════════════════════════════════════ HEALTH FACTOR TESTS ═══════════════════════════════════════════ */

    function test_healthFactor_calculation() public {
        // Open position at 5x leverage
        // collateral = 1000, borrow = 5000, strategy = 5000
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            5000e18,
            address(strategy)
        );

        // Health = maxBorrow / borrowed
        // effectiveCollateral = 1000 + 5000 (strategy) = 6000
        // maxBorrow = 6000 * 1 * 0.9 = 5400
        // borrowed = 5000
        // Health = 5400 / 5000 = 1.08
        uint256 health = marginEngine.getHealthFactor(positionId);
        assertApproxEqRel(health, 1.08e18, 0.01e18);
    }

    function test_isLiquidatable_false_whenHealthy() public {
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            5000e18,
            address(strategy)
        );

        assertFalse(marginEngine.isLiquidatable(positionId));
    }

    function test_isLiquidatable_true_afterPriceDrop() public {
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            8000e18, // High leverage
            address(strategy)
        );

        // Drop collateral price 50%
        pairOracle.setPrice(Constants.ORACLE_PRICE_SCALE / 2);

        // Now: effectiveCollateral = 1000 + 8000 = 9000 (in collateral terms)
        // But collateral value in loan = 9000 * 0.5 = 4500 loan tokens
        // maxBorrow = 4500 * 0.9 = 4050
        // borrowed = 8000
        // 4050 < 8000 => unhealthy
        assertTrue(marginEngine.isLiquidatable(positionId));
    }

    /* ═══════════════════════════════════════════ COLLATERAL TESTS ═══════════════════════════════════════════ */

    function test_addCollateral() public {
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            5000e18,
            address(strategy)
        );

        vm.prank(USER);
        marginEngine.addCollateral(positionId, 500e18);

        assertEq(
            marginEngine.getPosition(positionId).collateralAmount,
            1500e18
        );
    }

    function test_withdrawCollateral_whenHealthy() public {
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            10000e18, // lots of collateral
            5000e18,
            address(strategy)
        );

        vm.prank(USER);
        marginEngine.withdrawCollateral(positionId, 1000e18);

        assertEq(
            marginEngine.getPosition(positionId).collateralAmount,
            9000e18
        );
    }

    function test_withdrawCollateral_reverts_whenUnhealthy() public {
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            8000e18, // Near limit
            address(strategy)
        );

        vm.prank(USER);
        vm.expectRevert(IMarginEngine.PositionNotHealthy.selector);
        marginEngine.withdrawCollateral(positionId, 500e18);
    }

    /* ═══════════════════════════════════════════ LIQUIDATION TESTS ═══════════════════════════════════════════ */

    function test_liquidate_success() public {
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            8000e18,
            address(strategy)
        );

        // Make position unhealthy
        pairOracle.setPrice(Constants.ORACLE_PRICE_SCALE / 2);
        assertTrue(marginEngine.isLiquidatable(positionId));

        uint256 liquidatorBalBefore = collateralToken.balanceOf(LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        marginEngine.liquidate(positionId, 0);

        uint256 liquidatorBalAfter = collateralToken.balanceOf(LIQUIDATOR);
        assertTrue(liquidatorBalAfter > liquidatorBalBefore);
    }

    function test_liquidate_reverts_whenHealthy() public {
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            5000e18,
            address(strategy)
        );

        vm.prank(LIQUIDATOR);
        vm.expectRevert(IMarginEngine.PositionHealthy.selector);
        marginEngine.liquidate(positionId, 0);
    }

    /* ═══════════════════════════════════════════ CLOSE POSITION TESTS ═══════════════════════════════════════════ */

    function test_closePosition() public {
        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            5000e18,
            address(strategy)
        );

        uint256 collateralBefore = collateralToken.balanceOf(USER);

        vm.prank(USER);
        (uint256 returned, int256 pnl) = marginEngine.closePosition(positionId);

        assertTrue(returned > 0);
        assertEq(collateralToken.balanceOf(USER), collateralBefore + returned);
        assertFalse(marginEngine.getPosition(positionId).active);
    }

    /* ═══════════════════════════════════════════ VIEW TESTS ═══════════════════════════════════════════ */

    function test_getMaxBorrowable() public {
        // At 1:1 price and 10x leverage
        uint256 maxBorrow = marginEngine.getMaxBorrowable(
            address(collateralToken),
            address(loanToken),
            1000e18
        );
        assertEq(maxBorrow, 10000e18);
    }

    function test_getMaxBorrowable_withDifferentPrice() public {
        // 1 collateral = 2 loan tokens
        pairOracle.setPrice(2 * Constants.ORACLE_PRICE_SCALE);

        uint256 maxBorrow = marginEngine.getMaxBorrowable(
            address(collateralToken),
            address(loanToken),
            1000e18
        );
        // 1000 * 2 * 10 = 20000
        assertEq(maxBorrow, 20000e18);
    }

    function test_getPairConfig() public {
        MarginEngine.MarginPairConfig memory config = marginEngine
            .getPairConfig(address(collateralToken), address(loanToken));

        assertEq(config.oracle, address(pairOracle));
        assertEq(config.lltv, DEFAULT_LLTV);
        assertEq(config.maxLeverage, DEFAULT_MAX_LEVERAGE);
        assertTrue(config.enabled);
    }

    /* ═══════════════════════════════════════════ ADMIN TESTS ═══════════════════════════════════════════ */

    function test_setPaused() public {
        vm.prank(OWNER);
        marginEngine.setPaused(true);

        vm.prank(USER);
        vm.expectRevert(IMarginEngine.Paused.selector);
        marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            1000e18,
            5000e18,
            address(strategy)
        );
    }
}
