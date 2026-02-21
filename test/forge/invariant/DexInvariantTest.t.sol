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

contract DexHandler is Test {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;

    Dex public dex;
    ERC20Mock public usdc;
    ERC20Mock public weth;
    OracleMock public oracle;

    address[] public lps;
    address[] public users;

    uint256 public constant INITIAL_BALANCE = 1_000_000e18;

    constructor(
        Dex _dex,
        ERC20Mock _usdc,
        ERC20Mock _weth,
        OracleMock _oracle
    ) {
        dex = _dex;
        usdc = _usdc;
        weth = _weth;
        oracle = _oracle;

        for (uint160 i = 100; i < 103; i++) {
            address lp = address(i);
            lps.push(lp);
            usdc.setBalance(lp, INITIAL_BALANCE);
            weth.setBalance(lp, INITIAL_BALANCE);
            vm.prank(lp);
            usdc.approve(address(dex), type(uint256).max);
            vm.prank(lp);
            weth.approve(address(dex), type(uint256).max);
        }

        for (uint160 i = 200; i < 203; i++) {
            address user = address(i);
            users.push(user);
            usdc.setBalance(user, INITIAL_BALANCE);
            weth.setBalance(user, INITIAL_BALANCE);
            vm.prank(user);
            usdc.approve(address(dex), type(uint256).max);
            vm.prank(user);
            weth.approve(address(dex), type(uint256).max);
        }
    }

    function depositLP_USDC(uint256 lpIdx, uint256 amount) public {
        lpIdx = bound(lpIdx, 0, lps.length - 1);
        amount = bound(amount, 10000, 10_000e18);
        address lp = lps[lpIdx];

        vm.prank(lp);
        dex.depositLP(address(usdc), amount);
    }

    function depositLP_WETH(uint256 lpIdx, uint256 amount) public {
        lpIdx = bound(lpIdx, 0, lps.length - 1);
        amount = bound(amount, 10000, 10_000e18);
        address lp = lps[lpIdx];

        vm.prank(lp);
        dex.depositLP(address(weth), amount);
    }

    function forward_swap_USDC_WETH(uint256 userIdx, uint256 amountIn) public {
        userIdx = bound(userIdx, 0, users.length - 1);
        amountIn = bound(amountIn, 1e6, 1000e18);
        address user = users[userIdx];

        vm.prank(user);
        try dex.swap(address(usdc), address(weth), amountIn, 0, false) returns (
            uint256
        ) {} catch {}
    }

    function reverse_swap_USDC_WETH(uint256 userIdx, uint256 amountIn) public {
        userIdx = bound(userIdx, 0, users.length - 1);
        amountIn = bound(amountIn, 1e6, 1000e18);
        address user = users[userIdx];

        vm.prank(user);
        try dex.swap(address(usdc), address(weth), amountIn, 0, true) returns (
            uint256
        ) {} catch {}
    }

    function forward_swap_WETH_USDC(uint256 userIdx, uint256 amountIn) public {
        userIdx = bound(userIdx, 0, users.length - 1);
        amountIn = bound(amountIn, 1e6, 1000e18);
        address user = users[userIdx];

        vm.prank(user);
        try dex.swap(address(weth), address(usdc), amountIn, 0, false) returns (
            uint256
        ) {} catch {}
    }

    function reverse_swap_WETH_USDC(uint256 userIdx, uint256 amountIn) public {
        userIdx = bound(userIdx, 0, users.length - 1);
        amountIn = bound(amountIn, 1e6, 1000e18);
        address user = users[userIdx];

        vm.prank(user);
        try dex.swap(address(weth), address(usdc), amountIn, 0, true) returns (
            uint256
        ) {} catch {}
    }

    function removeLP_USDC(uint256 lpIdx, uint256 shares) public {
        lpIdx = bound(lpIdx, 0, lps.length - 1);
        address lp = lps[lpIdx];
        (uint256 maxShares, ) = dex.lpPositions(address(usdc), lp);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);

        vm.prank(lp);
        try dex.withdrawLP(address(usdc), shares) {} catch {}
    }

    function removeLP_WETH(uint256 lpIdx, uint256 shares) public {
        lpIdx = bound(lpIdx, 0, lps.length - 1);
        address lp = lps[lpIdx];
        (uint256 maxShares, ) = dex.lpPositions(address(weth), lp);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);

        vm.prank(lp);
        try dex.withdrawLP(address(weth), shares) {} catch {}
    }
}

contract DexInvariantTest is Test {
    using MarketParamsLib for MarketParams;

    Dex public dex;
    DexHandler public handler;
    ERC20Mock public usdc;
    ERC20Mock public weth;
    OracleMock public oracle;
    Morpho public morpho;
    IrmMock public irm;
    Id public usdcMarketId;
    Id public wethMarketId;

    address public OWNER = address(0x99);

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

        handler = new DexHandler(dex, usdc, weth, oracle);

        targetContract(address(handler));
    }

    /// @notice Invariant: Total getTotalAssets >= 0 for each token (implicitly true, but verifies no reverts)
    /// @dev The real solvency check is that total assets can be computed without underflow
    function invariant_SystemSolvency() public {
        // These calls should never revert — if they do, internal accounting is broken
        uint256 totalUSDCAssets = dex.getTotalAssets(address(usdc));
        uint256 totalWETHAssets = dex.getTotalAssets(address(weth));

        // getTotalAssets should always be >= outstanding LP share value
        // Since shares are pro-rata of totalAssets, this is tautologically true,
        // but the computation itself is the real test (no underflows/overflows).
        uint256 usdcShares = dex.totalLPShares(address(usdc));
        uint256 wethShares = dex.totalLPShares(address(weth));

        // If there are outstanding shares, totalAssets must be > 0
        if (usdcShares > 0) {
            assertGt(totalUSDCAssets, 0, "USDC: shares exist but no assets");
        }
        if (wethShares > 0) {
            assertGt(totalWETHAssets, 0, "WETH: shares exist but no assets");
        }
    }

    /// @notice Invariant: Contract token balance must match sum of internal states
    function invariant_BalanceConsistency() public {
        _checkBalance(address(usdc));
        _checkBalance(address(weth));
    }

    function _checkBalance(address token) internal {
        (
            ,
            // morphoSupplyShares
            uint256 localLiquidity,
            uint256 totalHeldBalance, // totalBorrowed // totalRepaid // totalLPDeposits
            ,
            ,
            ,
            uint256 lpFeeReserve,
            uint256 interestReserve,
            uint256 protocolFees
        ) = dex.tokenState(token);

        uint256 expectedBalance = localLiquidity +
            totalHeldBalance +
            lpFeeReserve +
            interestReserve +
            protocolFees;
        uint256 actualBalance = ERC20Mock(token).balanceOf(address(dex));

        assertEq(actualBalance, expectedBalance, "Balance mismatch");
    }
}
