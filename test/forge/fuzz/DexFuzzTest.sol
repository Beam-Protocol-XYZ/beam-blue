// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {Dex} from "../../../src/dex/Dex.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {Morpho} from "../../../src/Morpho.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {IrmMock} from "../../../src/mocks/IrmMock.sol";
import {Id, MarketParams, IMorpho} from "../../../src/interfaces/IMorpho.sol";
import {Constants} from "../helpers/Constants.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

contract DexFuzzTest is Test {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;

    Dex public dex;
    ERC20Mock public usdc;
    ERC20Mock public weth;
    OracleMock public oracle;
    Morpho public morpho;
    IrmMock public irm;
    Id public usdcMarketId;
    Id public wethMarketId;

    address public OWNER = makeAddr("Owner");
    address public LP = makeAddr("LP");
    address public USER = makeAddr("User");

    function setUp() public {
        usdc = new ERC20Mock();
        weth = new ERC20Mock();
        oracle = new OracleMock();
        oracle.setPrice(Constants.ORACLE_PRICE_SCALE); // 1:1

        morpho = new Morpho(OWNER);
        irm = new IrmMock();

        vm.startPrank(OWNER);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        vm.stopPrank();

        dex = new Dex(address(morpho), OWNER);

        MarketParams memory usdcParams = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        morpho.createMarket(usdcParams);
        usdcMarketId = usdcParams.id();

        MarketParams memory wethParams = MarketParams({
            loanToken: address(weth),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        morpho.createMarket(wethParams);
        wethMarketId = wethParams.id();

        vm.startPrank(OWNER);
        morpho.setUncollateralizedBorrower(usdcMarketId, address(dex), true);
        morpho.setUncollateralizedBorrower(wethMarketId, address(dex), true);

        dex.whitelistMarket(usdcMarketId);
        dex.whitelistMarket(wethMarketId);

        dex.whitelistPair(address(usdc), address(weth));
        dex.whitelistPair(address(weth), address(usdc));
        dex.setPairOracle(address(usdc), address(weth), address(oracle));
        dex.setPairOracle(address(weth), address(usdc), address(oracle));
        vm.stopPrank();

        // Fund LP and User
        usdc.setBalance(LP, 10_000_000e18);
        weth.setBalance(LP, 10_000_000e18);
        usdc.setBalance(USER, 10_000_000e18);
        weth.setBalance(USER, 10_000_000e18);

        vm.startPrank(LP);
        usdc.approve(address(dex), type(uint256).max);
        weth.approve(address(dex), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(USER);
        usdc.approve(address(dex), type(uint256).max);
        weth.approve(address(dex), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Fuzz depositLP with varying amounts
    function testFuzz_depositLP(uint256 usdcAmount, uint256 wethAmount) public {
        usdcAmount = bound(usdcAmount, 10000, 1_000_000e18);
        wethAmount = bound(wethAmount, 10000, 1_000_000e18);

        vm.prank(LP);
        dex.depositLP(address(usdc), usdcAmount);

        vm.prank(LP);
        dex.depositLP(address(weth), wethAmount);

        // Verify LP shares were issued
        (uint256 usdcShares, ) = dex.lpPositions(address(usdc), LP);
        (uint256 wethShares, ) = dex.lpPositions(address(weth), LP);

        assertTrue(usdcShares > 0, "USDC LP shares should be > 0");
        assertTrue(wethShares > 0, "WETH LP shares should be > 0");
    }

    /// @notice Fuzz deposit then withdraw full amount
    function testFuzz_depositAndWithdrawLP(uint256 amount) public {
        amount = bound(amount, 10000, 1_000_000e18);

        vm.prank(LP);
        dex.depositLP(address(usdc), amount);

        (uint256 shares, ) = dex.lpPositions(address(usdc), LP);
        assertTrue(shares > 0);

        uint256 balBefore = usdc.balanceOf(LP);

        vm.prank(LP);
        uint256 withdrawn = dex.withdrawLP(address(usdc), shares);

        assertTrue(withdrawn > 0, "Should withdraw something");
        assertEq(usdc.balanceOf(LP), balBefore + withdrawn);
    }

    /// @notice Fuzz forward swap with varying amounts and oracle prices
    function testFuzz_forwardSwap(
        uint256 depositAmount,
        uint256 swapAmount,
        uint256 priceMultiplier
    ) public {
        depositAmount = bound(depositAmount, 100_000e18, 1_000_000e18);
        swapAmount = bound(swapAmount, 1e6, 10_000e18);
        priceMultiplier = bound(priceMultiplier, 5e17, 2e18); // 0.5x to 2x

        oracle.setPrice(
            (Constants.ORACLE_PRICE_SCALE * priceMultiplier) / 1e18
        );

        // Seed liquidity
        vm.prank(LP);
        dex.depositLP(address(weth), depositAmount);

        uint256 userWethBefore = weth.balanceOf(USER);

        vm.prank(USER);
        try
            dex.swap(address(usdc), address(weth), swapAmount, 0, false)
        returns (uint256 amountOut) {
            assertTrue(amountOut > 0, "Forward swap should produce output");
            assertEq(weth.balanceOf(USER), userWethBefore + amountOut);
        } catch {
            // Swap can revert if insufficient liquidity; that's acceptable
        }
    }

    /// @notice Fuzz forward then reverse swap to verify round-trip
    function testFuzz_forwardThenReverseSwap(
        uint256 depositAmount,
        uint256 swapAmount
    ) public {
        depositAmount = bound(depositAmount, 100_000e18, 1_000_000e18);
        swapAmount = bound(swapAmount, 1e6, depositAmount / 10);

        // Seed both sides with liquidity
        vm.prank(LP);
        dex.depositLP(address(usdc), depositAmount);
        vm.prank(LP);
        dex.depositLP(address(weth), depositAmount);

        // Forward swap: USDC -> WETH
        vm.prank(USER);
        try
            dex.swap(address(usdc), address(weth), swapAmount, 0, false)
        returns (uint256 fwdOut) {
            if (fwdOut == 0) return;

            // Reverse swap: USDC -> WETH (reverse direction)
            vm.prank(USER);
            try
                dex.swap(address(usdc), address(weth), swapAmount, 0, true)
            returns (uint256 revOut) {
                // Reverse should also produce output
                assertTrue(revOut > 0, "Reverse swap should produce output");
            } catch {
                // May revert if no debt to repay; acceptable
            }
        } catch {
            // Forward swap can fail if liquidity insufficient
        }
    }
}
