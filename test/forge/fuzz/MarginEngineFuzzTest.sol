// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {console} from "../../../lib/forge-std/src/console.sol";

import {Id, MarketParams, IMorpho} from "../../../src/interfaces/IMorpho.sol";
import {IMarginEngine} from "../../../src/interfaces/IMarginEngine.sol";
import {IStrategy} from "../../../src/interfaces/IStrategy.sol";
import {MarginEngine} from "../../../src/margin/MarginEngine.sol";
import {MorphoMarketStrategy} from "../../../src/margin/MorphoMarketStrategy.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {IrmMock} from "../../../src/mocks/IrmMock.sol";
import {Morpho} from "../../../src/Morpho.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {Constants} from "../helpers/Constants.sol";

contract MarginEngineFuzzTest is Test {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    uint256 internal constant ORACLE_PRICE_SCALE = Constants.ORACLE_PRICE_SCALE;
    uint256 internal constant DEFAULT_LLTV = 0.9e18; // 90% LLTV
    uint256 internal constant DEFAULT_MAX_LEVERAGE = 10e18; // 10x

    IMorpho internal morpho;
    MarginEngine internal marginEngine;
    MorphoMarketStrategy internal strategy;

    ERC20Mock internal collateralToken;
    ERC20Mock internal loanToken;
    OracleMock internal pairOracle;
    IrmMock internal irm;

    MarketParams internal marketParams;
    Id internal marketId;

    address internal OWNER = makeAddr("Owner");
    address internal USER = makeAddr("User");
    address internal LIQUIDATOR = makeAddr("Liquidator");
    address internal SUPPLIER = makeAddr("Supplier");

    function setUp() public virtual {
        morpho = IMorpho(address(new Morpho(OWNER)));

        collateralToken = new ERC20Mock();
        loanToken = new ERC20Mock();

        pairOracle = new OracleMock();
        pairOracle.setPrice(ORACLE_PRICE_SCALE);

        irm = new IrmMock();

        vm.startPrank(OWNER);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        vm.stopPrank();

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

        vm.prank(OWNER);
        morpho.setUncollateralizedBorrower(
            marketId,
            address(marginEngine),
            true
        );

        strategy = new MorphoMarketStrategy(address(morpho), marketId);

        vm.startPrank(OWNER);
        marginEngine.setMarginPairConfig(
            address(collateralToken),
            address(loanToken),
            address(pairOracle),
            marketId,
            DEFAULT_LLTV,
            DEFAULT_MAX_LEVERAGE
        );
        marginEngine.setStrategyWhitelist(address(strategy), true);
        vm.stopPrank();

        loanToken.setBalance(SUPPLIER, 100_000_000e18);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 100_000_000e18, 0, SUPPLIER, "");
        vm.stopPrank();

        collateralToken.setBalance(USER, 100_000_000e18);
        vm.startPrank(USER);
        collateralToken.approve(address(marginEngine), type(uint256).max);
        vm.stopPrank();
    }

    function testFuzz_openPosition_and_closePosition(
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 priceMultiplier
    ) public {
        collateralAmount = bound(collateralAmount, 1e6, 1_000_000e18);
        priceMultiplier = bound(priceMultiplier, 1e16, 100e18); // 0.01x to 100x
        uint256 currentPrice = (ORACLE_PRICE_SCALE * priceMultiplier) / 1e18;
        pairOracle.setPrice(currentPrice);

        // Calculate max borrow based on leverage and price
        // leverage <= 10x means (collateralValue + borrowValue) / collateralValue <= 10
        // Which means borrowValue <= 9 * collateralValue
        // borrowAmount <= 9 * (collateralAmount * currentPrice / ORACLE_PRICE_SCALE)
        uint256 maxBorrow = (9 * collateralAmount * currentPrice) /
            ORACLE_PRICE_SCALE;

        if (maxBorrow > 90_000_000e18) maxBorrow = 90_000_000e18;
        if (maxBorrow < 1e6) {
            vm.assume(false);
        }

        borrowAmount = bound(borrowAmount, 1e6, maxBorrow);

        // Open Position
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
        assertTrue(pos.active);
        assertEq(pos.collateralAmount, collateralAmount);
        assertTrue(pos.borrowShares > 0);

        uint256 collateralBefore = collateralToken.balanceOf(USER);

        // Close Position
        vm.prank(USER);
        (uint256 returned, ) = marginEngine.closePosition(positionId);

        assertTrue(returned > 0);
        assertEq(collateralToken.balanceOf(USER), collateralBefore + returned);
        assertFalse(marginEngine.getPosition(positionId).active);
    }

    function testFuzz_liquidate(
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 priceDropPercent
    ) public {
        collateralAmount = bound(collateralAmount, 10e18, 1_000_000e18);

        // Ensure starting highly leveraged but healthy
        uint256 startPrice = ORACLE_PRICE_SCALE;
        pairOracle.setPrice(startPrice);
        uint256 maxBorrowLeverage = (9 * collateralAmount * startPrice) /
            ORACLE_PRICE_SCALE;
        if (maxBorrowLeverage > 90_000_000e18)
            maxBorrowLeverage = 90_000_000e18;
        if (maxBorrowLeverage < 2e6) vm.assume(false);

        // Bound to very high leverage to make it easier to liquidate
        borrowAmount = bound(
            borrowAmount,
            maxBorrowLeverage / 2 + 1e6,
            maxBorrowLeverage
        );

        // Calculate max borrow limit for health
        uint256 effectiveCollateralValue = (collateralAmount * startPrice) /
            ORACLE_PRICE_SCALE +
            borrowAmount;
        uint256 maxBorrowLimit = (effectiveCollateralValue * DEFAULT_LLTV) /
            1e18;

        borrowAmount = bound(borrowAmount, 1e18, maxBorrowLimit);

        vm.prank(USER);
        bytes32 positionId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            collateralAmount,
            borrowAmount,
            address(strategy)
        );

        // Drop price
        priceDropPercent = bound(priceDropPercent, 10, 99);
        uint256 newPrice = (startPrice * (100 - priceDropPercent)) / 100;
        pairOracle.setPrice(newPrice);

        if (marginEngine.isLiquidatable(positionId)) {
            collateralToken.setBalance(LIQUIDATOR, 0); // Start with 0

            // Execute liquidation
            vm.prank(LIQUIDATOR);
            marginEngine.liquidate(positionId, 0);

            // Verify liquidator got something
            uint256 liqBal = collateralToken.balanceOf(LIQUIDATOR);
            assertTrue(liqBal > 0);

            IMarginEngine.Position memory pos = marginEngine.getPosition(
                positionId
            );
            assertFalse(pos.active);
        } else {
            // Should revert if still healthy
            vm.prank(LIQUIDATOR);
            vm.expectRevert(IMarginEngine.PositionHealthy.selector);
            marginEngine.liquidate(positionId, 0);
        }
    }
}
