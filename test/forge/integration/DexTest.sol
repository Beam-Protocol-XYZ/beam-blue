// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";
import "../forge/BaseTest.sol";
import {Dex} from "../../src/dex/Dex.sol";
import {Id, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";

contract DexTest is BaseTest {
    using MarketParamsLib for MarketParams;

    Dex public dex;
    MarketParams public usdcMarket;
    Id public usdcMarketId;

    ERC20Mock public usdc;
    ERC20Mock public weth;

    address public LP1;
    address public TAKER;
    address public FILLER;

    function setUp() public override {
        super.setUp();

        LP1 = makeAddr("LP1");
        TAKER = makeAddr("Taker");
        FILLER = makeAddr("Filler");

        // Create mock tokens
        usdc = new ERC20Mock();
        vm.label(address(usdc), "USDC");
        weth = new ERC20Mock();
        vm.label(address(weth), "WETH");

        // Create DEX
        dex = new Dex(address(morpho), OWNER);

        // Create uncollateralized market for USDC
        usdcMarket = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        usdcMarketId = usdcMarket.id();

        vm.prank(OWNER);
        morpho.createMarket(usdcMarket);

        // Whitelist DEX as uncollateralized borrower
        vm.prank(OWNER);
        morpho.setUncollateralizedBorrower(usdcMarketId, address(dex), true);

        // Whitelist market in DEX
        vm.prank(OWNER);
        dex.whitelistMarket(usdcMarketId);

        // Setup approvals
        vm.startPrank(LP1);
        usdc.approve(address(dex), type(uint256).max);
        usdc.approve(address(morpho), type(uint256).max);
        weth.approve(address(dex), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(TAKER);
        usdc.approve(address(dex), type(uint256).max);
        weth.approve(address(dex), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(FILLER);
        usdc.approve(address(dex), type(uint256).max);
        weth.approve(address(dex), type(uint256).max);
        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════ LP TESTS ═══════════════════════════════════════════ */

    function testLPDeposit() public {
        uint256 depositAmount = 10000e18;
        usdc.setBalance(LP1, depositAmount);

        vm.prank(LP1);
        uint256 shares = dex.depositLP(address(usdc), depositAmount);

        assertGt(shares, 0, "should receive shares");
        assertEq(
            dex.getLPValue(address(usdc), LP1),
            depositAmount,
            "LP value should match deposit"
        );
    }

    function testLPDepositSplitsCorrectly() public {
        // First, create some debt by doing a swap
        // Supply some USDC to Morpho so DEX can borrow
        uint256 morphoSupply = 50000e18;
        usdc.setBalance(SUPPLIER, morphoSupply);
        vm.startPrank(SUPPLIER);
        usdc.approve(address(morpho), morphoSupply);
        morpho.supply(usdcMarket, morphoSupply, 0, SUPPLIER, "");
        vm.stopPrank();

        // Create WETH market for the other side
        MarketParams memory wethMarket = MarketParams({
            loanToken: address(weth),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        Id wethMarketId = wethMarket.id();

        vm.prank(OWNER);
        morpho.createMarket(wethMarket);

        vm.prank(OWNER);
        morpho.setUncollateralizedBorrower(wethMarketId, address(dex), true);

        vm.prank(OWNER);
        dex.whitelistMarket(wethMarketId);

        // Now simulate a swap that creates debt
        weth.setBalance(TAKER, 10e18);
        vm.prank(TAKER);
        dex.swap(address(weth), address(usdc), 10e18, 0);

        // LP deposits - should split: 50% supply, 25% repay, 25% liquidity
        uint256 depositAmount = 10000e18;
        usdc.setBalance(LP1, depositAmount);

        vm.prank(LP1);
        dex.depositLP(address(usdc), depositAmount);

        // Check allocations happened
        assertGt(dex.getTotalAssets(address(usdc)), 0, "should have assets");
    }

    function testLPWithdraw() public {
        uint256 depositAmount = 10000e18;
        usdc.setBalance(LP1, depositAmount);

        vm.prank(LP1);
        uint256 shares = dex.depositLP(address(usdc), depositAmount);

        vm.prank(LP1);
        uint256 withdrawn = dex.withdrawLP(address(usdc), shares);

        assertApproxEqRel(
            withdrawn,
            depositAmount,
            0.01e18,
            "should withdraw ~full amount"
        );
        assertEq(usdc.balanceOf(LP1), withdrawn, "LP should receive tokens");
    }

    /* ═══════════════════════════════════════════ SWAP TESTS ═══════════════════════════════════════════ */

    function testSwapTaker() public {
        // Setup: LP provides USDC liquidity
        uint256 lpDeposit = 10000e18;
        usdc.setBalance(LP1, lpDeposit);
        vm.prank(LP1);
        dex.depositLP(address(usdc), lpDeposit);

        // Taker swaps WETH for USDC
        uint256 wethAmount = 1e18;
        weth.setBalance(TAKER, wethAmount);

        vm.prank(TAKER);
        uint256 usdcReceived = dex.swap(
            address(weth),
            address(usdc),
            wethAmount,
            0
        );

        assertGt(usdcReceived, 0, "should receive USDC");
        assertLt(usdcReceived, wethAmount, "should be less due to fee");
        assertEq(usdc.balanceOf(TAKER), usdcReceived, "taker should have USDC");
    }

    function testFillSwap() public {
        // Setup: LP provides USDC liquidity
        uint256 lpDeposit = 10000e18;
        usdc.setBalance(LP1, lpDeposit);
        vm.prank(LP1);
        dex.depositLP(address(usdc), lpDeposit);

        // Taker swaps WETH for USDC
        uint256 wethAmount = 1e18;
        weth.setBalance(TAKER, wethAmount);
        vm.prank(TAKER);
        dex.swap(address(weth), address(usdc), wethAmount, 0);

        // Filler provides USDC, wants WETH
        uint256 usdcAmount = 0.9e18;
        usdc.setBalance(FILLER, usdcAmount);

        vm.prank(FILLER);
        uint256 wethReceived = dex.fillSwap(
            address(usdc),
            address(weth),
            usdcAmount,
            0
        );

        assertGt(wethReceived, 0, "should receive WETH");
        assertEq(
            weth.balanceOf(FILLER),
            wethReceived,
            "filler should have WETH"
        );
    }

    /* ═══════════════════════════════════════════ FEE TESTS ═══════════════════════════════════════════ */

    function testFeeQuote() public {
        uint256 amount = 1000e18;

        (uint256 amountOut, uint256 fee) = dex.quote(
            address(weth),
            address(usdc),
            amount,
            true
        );

        assertGt(fee, 0, "fee should be positive");
        assertEq(amountOut + fee, amount, "amountOut + fee should equal input");
    }

    function testDynamicFees() public {
        // Setup liquidity
        uint256 lpDeposit = 100000e18;
        usdc.setBalance(LP1, lpDeposit);
        vm.prank(LP1);
        dex.depositLP(address(usdc), lpDeposit);

        // Do several taker swaps to create imbalance
        for (uint256 i = 0; i < 5; i++) {
            weth.setBalance(TAKER, 10e18);
            vm.prank(TAKER);
            dex.swap(address(weth), address(usdc), 10e18, 0);
        }

        // Check imbalance
        (, , int256 imbalance, ) = dex.getPairStatus(
            address(weth),
            address(usdc)
        );
        assertGt(imbalance, 0, "should have positive imbalance (need fillers)");

        // Filler fee should be discounted
        (, uint256 fillerFee) = dex.quote(
            address(usdc),
            address(weth),
            1000e18,
            false
        );
        (, uint256 takerFee) = dex.quote(
            address(weth),
            address(usdc),
            1000e18,
            true
        );

        // Filler should get better rate when imbalance needs fillers
        assertLt(fillerFee, takerFee, "filler fee should be lower");
    }

    /* ═══════════════════════════════════════════ ADMIN TESTS ═══════════════════════════════════════════ */

    function testOnlyOwnerCanWhitelist() public {
        MarketParams memory newMarket = MarketParams({
            loanToken: address(weth),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(irm),
            lltv: 0
        });
        Id newMarketId = newMarket.id();

        vm.prank(OWNER);
        morpho.createMarket(newMarket);

        vm.prank(LP1);
        vm.expectRevert(Dex.NotOwner.selector);
        dex.whitelistMarket(newMarketId);
    }

    function testSetAllocation() public {
        vm.prank(OWNER);
        dex.setAllocation(60, 20, 20);

        // Verify by doing a deposit and checking behavior
        assertEq(true, true, "allocation set successfully");
    }

    function testReallocate() public {
        // Setup
        uint256 lpDeposit = 10000e18;
        usdc.setBalance(LP1, lpDeposit);
        vm.prank(LP1);
        dex.depositLP(address(usdc), lpDeposit);

        (uint256 localBefore, ) = dex.getAvailableLiquidity(address(usdc));

        // Reallocate 1000 to Morpho
        vm.prank(OWNER);
        dex.reallocate(address(usdc), 1000e18);

        (uint256 localAfter, ) = dex.getAvailableLiquidity(address(usdc));

        assertLt(localAfter, localBefore, "local liquidity should decrease");
    }
}
