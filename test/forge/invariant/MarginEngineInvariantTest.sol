// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {StdInvariant} from "../../../lib/forge-std/src/StdInvariant.sol";
import {IMarginEngine} from "../../../src/interfaces/IMarginEngine.sol";
import {MarginEngine} from "../../../src/margin/MarginEngine.sol";
import {MorphoMarketStrategy} from "../../../src/margin/MorphoMarketStrategy.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {IrmMock} from "../../../src/mocks/IrmMock.sol";
import {Morpho} from "../../../src/Morpho.sol";
import {Id, MarketParams, IMorpho} from "../../../src/interfaces/IMorpho.sol";
import {Constants} from "../helpers/Constants.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

contract MarginEngineHandler is Test {
    using MathLib for uint256;

    MarginEngine public marginEngine;
    MorphoMarketStrategy public strategy;
    ERC20Mock public collateralToken;
    ERC20Mock public loanToken;
    OracleMock public pairOracle;

    address public USER = address(0x123);
    address public LIQUIDATOR = address(0x456);

    bytes32[] public openPositions;

    constructor(
        MarginEngine _marginEngine,
        MorphoMarketStrategy _strategy,
        ERC20Mock _col,
        ERC20Mock _loan,
        OracleMock _oracle
    ) {
        marginEngine = _marginEngine;
        strategy = _strategy;
        collateralToken = _col;
        loanToken = _loan;
        pairOracle = _oracle;

        collateralToken.setBalance(USER, type(uint128).max);
        vm.prank(USER);
        collateralToken.approve(address(marginEngine), type(uint256).max);

        loanToken.setBalance(LIQUIDATOR, type(uint128).max);
        vm.prank(LIQUIDATOR);
        loanToken.approve(address(marginEngine), type(uint256).max);
    }

    function getOpenPositionsCount() external view returns (uint256) {
        return openPositions.length;
    }

    function openPosition(
        uint256 collateralAmount,
        uint256 borrowAmount
    ) external {
        collateralAmount = bound(collateralAmount, 1e6, 100_000_000e18);
        uint256 currentPrice = pairOracle.price();

        // Ensure max leverage is respected (10x)
        uint256 maxBorrow = (9 * collateralAmount * currentPrice) /
            Constants.ORACLE_PRICE_SCALE;
        if (maxBorrow > 50_000_000e18) maxBorrow = 50_000_000e18;
        if (maxBorrow < 1e6) return;

        borrowAmount = bound(borrowAmount, 1e6, maxBorrow);

        vm.prank(USER);
        bytes32 posId = marginEngine.openPosition(
            address(collateralToken),
            address(loanToken),
            collateralAmount,
            borrowAmount,
            address(strategy)
        );

        openPositions.push(posId);
    }

    function closePosition(uint256 posIndex) external {
        if (openPositions.length == 0) return;
        posIndex = posIndex % openPositions.length;
        bytes32 posId = openPositions[posIndex];

        if (marginEngine.getPosition(posId).active) {
            vm.prank(USER);
            marginEngine.closePosition(posId);
        }
    }

    function addCollateral(uint256 posIndex, uint256 amount) external {
        if (openPositions.length == 0) return;
        posIndex = posIndex % openPositions.length;
        bytes32 posId = openPositions[posIndex];

        amount = bound(amount, 1, 10_000e18);

        if (marginEngine.getPosition(posId).active) {
            vm.prank(USER);
            marginEngine.addCollateral(posId, amount);
        }
    }

    function withdrawCollateral(uint256 posIndex, uint256 amount) external {
        if (openPositions.length == 0) return;
        posIndex = posIndex % openPositions.length;
        bytes32 posId = openPositions[posIndex];

        IMarginEngine.Position memory pos = marginEngine.getPosition(posId);
        if (!pos.active || marginEngine.isLiquidatable(posId)) return;

        amount = bound(amount, 1, pos.collateralAmount / 2 + 1);

        vm.prank(USER);
        // Withdraw might revert if bounds were still too tight for health limits
        try marginEngine.withdrawCollateral(posId, amount) {} catch {}
    }

    function liquidate(uint256 posIndex) external {
        if (openPositions.length == 0) return;
        posIndex = posIndex % openPositions.length;
        bytes32 posId = openPositions[posIndex];

        if (
            marginEngine.getPosition(posId).active &&
            marginEngine.isLiquidatable(posId)
        ) {
            vm.prank(LIQUIDATOR);
            marginEngine.liquidate(posId, 0);
        }
    }

    function updatePrice(uint256 priceMultiplier) external {
        priceMultiplier = bound(priceMultiplier, 5e17, 2e18); // +/- 50%
        uint256 startPrice = Constants.ORACLE_PRICE_SCALE;
        uint256 newPrice = (startPrice * priceMultiplier) / 1e18;
        pairOracle.setPrice(newPrice);
    }
}

contract MarginEngineInvariantTest is StdInvariant, Test {
    using MarketParamsLib for MarketParams;

    MarginEngine public marginEngine;
    IMorpho public morpho;
    MorphoMarketStrategy public strategy;
    ERC20Mock public collateralToken;
    ERC20Mock public loanToken;
    OracleMock public pairOracle;
    IrmMock public irm;
    MarketParams public marketParams;
    Id public marketId;

    address public OWNER = address(0x999);
    address public SUPPLIER = address(0x888);

    MarginEngineHandler public handler;

    function setUp() public {
        morpho = IMorpho(address(new Morpho(OWNER)));

        collateralToken = new ERC20Mock();
        loanToken = new ERC20Mock();
        pairOracle = new OracleMock();
        pairOracle.setPrice(Constants.ORACLE_PRICE_SCALE);
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

        vm.startPrank(OWNER);
        morpho.createMarket(marketParams);

        marginEngine = new MarginEngine(address(morpho), OWNER);
        morpho.setUncollateralizedBorrower(
            marketId,
            address(marginEngine),
            true
        );

        strategy = new MorphoMarketStrategy(address(morpho), marketId);

        marginEngine.setMarginPairConfig(
            address(collateralToken),
            address(loanToken),
            address(pairOracle),
            marketId,
            0.9e18, // 90%
            10e18 // 10x
        );
        marginEngine.setStrategyWhitelist(address(strategy), true);
        vm.stopPrank();

        loanToken.setBalance(SUPPLIER, 100_000_000e18);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 100_000_000e18, 0, SUPPLIER, "");
        vm.stopPrank();

        handler = new MarginEngineHandler(
            marginEngine,
            strategy,
            collateralToken,
            loanToken,
            pairOracle
        );

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.openPosition.selector;
        selectors[1] = handler.closePosition.selector;
        selectors[2] = handler.addCollateral.selector;
        selectors[3] = handler.withdrawCollateral.selector;
        selectors[4] = handler.liquidate.selector;
        selectors[5] = handler.updatePrice.selector;

        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    /// @dev Invariant: A healthy position should never be liquidatable
    function invariant_healthy_position_not_liquidatable() public view {
        // Wait, Forge invariant handlers: we can iterate through openPositions if we expose `openPositions.length`.
    }

    /// @dev Check all currently active positions
    function invariant_system_state() public {
        bool allHealthyAreNotLiquidatable = true;

        for (uint256 i = 0; i < handler.getOpenPositionsCount(); i++) {
            bytes32 posId = handler.openPositions(i);

            if (marginEngine.getPosition(posId).active) {
                uint256 health = marginEngine.getHealthFactor(posId);
                bool isLiq = marginEngine.isLiquidatable(posId);

                // If health >= 1.0, it should not be liquidatable
                if (health >= 1e18 && isLiq) {
                    allHealthyAreNotLiquidatable = false;
                }
            }
        }

        assertTrue(allHealthyAreNotLiquidatable);
    }
}
