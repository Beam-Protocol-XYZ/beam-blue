// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, Market, Position, IMorpho} from "../interfaces/IMorpho.sol";
import {ICrossPlatformLending} from "../interfaces/ICrossPlatformLending.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../libraries/MarketParamsLib.sol";
import {UtilsLib} from "../libraries/UtilsLib.sol";

/// @title CrossPlatformLending
/// @notice Per-partner contract bridging Morpho uncollateralized lending with off-chain (real-world) lending
/// @dev Deployed by CrossPlatformFactory. Must be whitelisted as uncollateralized borrower on Morpho.
///
/// Flow A (Off-Chain → On-Chain): Partner borrows from Morpho, disburses crypto to user.
///   Partner later collects repayment off-chain and repays Morpho.
///
/// Flow B (On-Chain → Off-Chain): User locks on-chain collateral, partner provides off-chain loan.
///   User repays on-chain (funds → Morpho) to release collateral, OR partner releases after off-chain repayment.
///   Partner can initiate seizure with a configurable grace period (24–48h).
contract CrossPlatformLending is ICrossPlatformLending {
    using SafeTransferLib for IERC20;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

    /* ═══════════════════════════════════════════ CONSTANTS ═══════════════════════════════════════════ */

    uint256 public constant MIN_SEIZURE_DELAY = 24 hours;
    uint256 public constant MAX_SEIZURE_DELAY = 48 hours;

    /* ═══════════════════════════════════════════ IMMUTABLES ═══════════════════════════════════════════ */

    IMorpho public immutable morpho;
    Id public immutable morphoMarketId;
    address public immutable loanToken;

    /* ═══════════════════════════════════════════ STORAGE ═══════════════════════════════════════════ */

    address public owner;
    address public partner;
    bool public paused;
    uint256 private _locked = 1;
    uint256 public seizureDelay;

    // Approved collateral tokens for off-chain loans
    mapping(address token => bool) public approvedCollaterals;

    // Flow A: Crypto loans
    uint256 public cryptoLoanCount;
    mapping(uint256 loanId => CryptoLoan) public cryptoLoans;

    // Flow B: Off-chain loans
    uint256 public offchainLoanCount;
    mapping(uint256 requestId => OffchainLoan) public offchainLoans;

    // Tracking
    mapping(address user => uint256[]) public userCryptoLoans;
    mapping(address user => uint256[]) public userOffchainLoans;

    /* ═══════════════════════════════════════════ MODIFIERS ═══════════════════════════════════════════ */

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPartner() {
        if (msg.sender != partner) revert NotPartner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked == 2) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /* ═══════════════════════════════════════════ CONSTRUCTOR ═══════════════════════════════════════════ */

    constructor(
        address _morpho,
        address _partner,
        address _owner,
        Id _morphoMarketId,
        uint256 _seizureDelay
    ) {
        if (
            _morpho == address(0) ||
            _partner == address(0) ||
            _owner == address(0)
        ) revert ZeroAddress();
        if (
            _seizureDelay < MIN_SEIZURE_DELAY ||
            _seizureDelay > MAX_SEIZURE_DELAY
        ) revert InvalidDelay();

        morpho = IMorpho(_morpho);
        partner = _partner;
        owner = _owner;
        morphoMarketId = _morphoMarketId;
        seizureDelay = _seizureDelay;

        // Resolve the loan token from the Morpho market and pre-approve Morpho
        MarketParams memory params = morpho.idToMarketParams(_morphoMarketId);
        loanToken = params.loanToken;
        IERC20(loanToken).safeApprove(address(morpho), type(uint256).max);
    }

    /* ═══════════════════════════════════════════ ADMIN ═══════════════════════════════════════════ */

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setPartner(address newPartner) external onlyOwner {
        if (newPartner == address(0)) revert ZeroAddress();
        partner = newPartner;
    }

    /// @inheritdoc ICrossPlatformLending
    function setApprovedCollateral(
        address token,
        bool approved
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        approvedCollaterals[token] = approved;
        emit ApprovedCollateralSet(token, approved);
    }

    /// @inheritdoc ICrossPlatformLending
    function setSeizureDelay(uint256 delay) external onlyOwner {
        if (delay < MIN_SEIZURE_DELAY || delay > MAX_SEIZURE_DELAY)
            revert InvalidDelay();
        seizureDelay = delay;
        emit SeizureDelayUpdated(delay);
    }

    /// @inheritdoc ICrossPlatformLending
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /// @notice Allows partner to withdraw excess tokens held by the contract
    function withdrawTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyPartner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
    }

    /* ═══════════════════════════════════════════ FLOW A: CRYPTO LOANS ═══════════════════════════════════════════ */

    /// @inheritdoc ICrossPlatformLending
    function disburseCryptoLoan(
        address borrower,
        uint256 amount
    ) external onlyPartner whenNotPaused nonReentrant returns (uint256 loanId) {
        if (borrower == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Borrow from Morpho (uncollateralized) and send directly to borrower
        MarketParams memory params = morpho.idToMarketParams(morphoMarketId);
        morpho.borrow(params, amount, 0, address(this), borrower);

        // Track the loan
        loanId = cryptoLoanCount++;
        CryptoLoan storage loan = cryptoLoans[loanId];
        loan.borrower = borrower;
        loan.principal = amount;
        loan.repaidAmount = 0;
        loan.timestamp = block.timestamp;
        loan.active = true;

        userCryptoLoans[borrower].push(loanId);

        emit CryptoLoanDisbursed(loanId, borrower, amount);
    }

    /// @inheritdoc ICrossPlatformLending
    function repayCryptoLoan(
        uint256 loanId,
        uint256 amount
    ) external onlyPartner nonReentrant {
        CryptoLoan storage loan = cryptoLoans[loanId];
        if (!loan.active) revert LoanNotActive();
        if (amount == 0) revert ZeroAmount();

        // Cap repayment at outstanding amount
        uint256 outstanding = loan.principal - loan.repaidAmount;
        uint256 repayAmount = amount > outstanding ? outstanding : amount;

        // Pull tokens from partner
        IERC20(loanToken).safeTransferFrom(
            msg.sender,
            address(this),
            repayAmount
        );

        // Repay to Morpho
        MarketParams memory params = morpho.idToMarketParams(morphoMarketId);
        morpho.repay(params, repayAmount, 0, address(this), "");

        loan.repaidAmount += repayAmount;
        if (loan.repaidAmount >= loan.principal) {
            loan.active = false;
        }

        emit CryptoLoanRepaid(
            loanId,
            repayAmount,
            loan.principal - loan.repaidAmount
        );
    }

    /* ═══════════════════════════════════════════ FLOW B: OFF-CHAIN LOANS ═══════════════════════════════════════════ */

    /// @inheritdoc ICrossPlatformLending
    function requestOffchainLoan(
        address collateralToken,
        uint256 collateralAmount
    ) external whenNotPaused nonReentrant returns (uint256 requestId) {
        if (collateralToken == address(0)) revert ZeroAddress();
        if (collateralAmount == 0) revert ZeroAmount();
        if (!approvedCollaterals[collateralToken]) revert TokenNotApproved();

        // Escrow collateral from user
        IERC20(collateralToken).safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );

        // Create request
        requestId = offchainLoanCount++;
        OffchainLoan storage loan = offchainLoans[requestId];
        loan.user = msg.sender;
        loan.collateralToken = collateralToken;
        loan.collateralAmount = collateralAmount;
        loan.repaymentAmount = 0; // Set by partner on accept
        loan.createdAt = block.timestamp;
        loan.seizureInitTime = 0;
        loan.status = OffchainLoanStatus.PENDING;

        userOffchainLoans[msg.sender].push(requestId);

        emit OffchainLoanRequested(
            requestId,
            msg.sender,
            collateralToken,
            collateralAmount
        );
    }

    /// @inheritdoc ICrossPlatformLending
    function cancelOffchainLoanRequest(
        uint256 requestId
    ) external nonReentrant {
        OffchainLoan storage loan = offchainLoans[requestId];
        if (loan.user != msg.sender) revert NotLoanUser();
        if (loan.status != OffchainLoanStatus.PENDING) revert InvalidStatus();

        loan.status = OffchainLoanStatus.RELEASED;

        // Return collateral
        IERC20(loan.collateralToken).safeTransfer(
            msg.sender,
            loan.collateralAmount
        );

        emit OffchainLoanCancelled(requestId, msg.sender);
    }

    /// @inheritdoc ICrossPlatformLending
    function acceptOffchainLoan(
        uint256 requestId,
        uint256 repaymentAmount
    ) external onlyPartner {
        OffchainLoan storage loan = offchainLoans[requestId];
        if (loan.status != OffchainLoanStatus.PENDING) revert InvalidStatus();
        if (repaymentAmount == 0) revert ZeroAmount();

        loan.repaymentAmount = repaymentAmount;
        loan.status = OffchainLoanStatus.ACTIVE;

        emit OffchainLoanAccepted(requestId, repaymentAmount);
    }

    /// @inheritdoc ICrossPlatformLending
    function repayOffchainLoanOnchain(uint256 requestId) external nonReentrant {
        OffchainLoan storage loan = offchainLoans[requestId];
        if (loan.user != msg.sender) revert NotLoanUser();
        if (
            loan.status != OffchainLoanStatus.ACTIVE &&
            loan.status != OffchainLoanStatus.SEIZURE_PENDING
        ) revert InvalidStatus();

        uint256 repayAmount = loan.repaymentAmount;

        // Pull loan tokens from user
        IERC20(loanToken).safeTransferFrom(
            msg.sender,
            address(this),
            repayAmount
        );

        // Repay to Morpho lending market (capped at contract's outstanding borrow)
        MarketParams memory params = morpho.idToMarketParams(morphoMarketId);
        Market memory mkt = morpho.market(morphoMarketId);

        Position memory morphoPos = morpho.position(
            morphoMarketId,
            address(this)
        );
        if (morphoPos.borrowShares > 0) {
            uint256 outstandingDebt = uint256(morphoPos.borrowShares)
                .toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
            uint256 toRepay = repayAmount > outstandingDebt
                ? outstandingDebt
                : repayAmount;
            if (toRepay > 0) {
                morpho.repay(params, toRepay, 0, address(this), "");
            }
        }

        // Release collateral to user
        IERC20(loan.collateralToken).safeTransfer(
            loan.user,
            loan.collateralAmount
        );
        loan.status = OffchainLoanStatus.RELEASED;

        emit OffchainLoanRepaidOnchain(requestId, msg.sender, repayAmount);
        emit CollateralReleased(
            requestId,
            loan.user,
            loan.collateralToken,
            loan.collateralAmount
        );
    }

    /// @inheritdoc ICrossPlatformLending
    function initiateSeizure(uint256 requestId) external onlyPartner {
        OffchainLoan storage loan = offchainLoans[requestId];
        if (loan.status != OffchainLoanStatus.ACTIVE) revert InvalidStatus();

        loan.seizureInitTime = block.timestamp;
        loan.status = OffchainLoanStatus.SEIZURE_PENDING;

        emit SeizureInitiated(requestId, block.timestamp + seizureDelay);
    }

    /// @inheritdoc ICrossPlatformLending
    function seizeCollateral(
        uint256 requestId
    ) external onlyPartner nonReentrant {
        OffchainLoan storage loan = offchainLoans[requestId];
        if (loan.status != OffchainLoanStatus.SEIZURE_PENDING)
            revert InvalidStatus();
        if (block.timestamp < loan.seizureInitTime + seizureDelay)
            revert SeizureDelayNotElapsed();

        loan.status = OffchainLoanStatus.SEIZED;

        // Transfer collateral to partner
        IERC20(loan.collateralToken).safeTransfer(
            partner,
            loan.collateralAmount
        );

        emit CollateralSeized(
            requestId,
            loan.collateralToken,
            loan.collateralAmount
        );
    }

    /// @inheritdoc ICrossPlatformLending
    function releaseCollateral(
        uint256 requestId
    ) external onlyPartner nonReentrant {
        OffchainLoan storage loan = offchainLoans[requestId];
        if (
            loan.status != OffchainLoanStatus.ACTIVE &&
            loan.status != OffchainLoanStatus.SEIZURE_PENDING
        ) revert InvalidStatus();

        loan.status = OffchainLoanStatus.RELEASED;

        // Return collateral to user
        IERC20(loan.collateralToken).safeTransfer(
            loan.user,
            loan.collateralAmount
        );

        emit CollateralReleased(
            requestId,
            loan.user,
            loan.collateralToken,
            loan.collateralAmount
        );
    }

    /* ═══════════════════════════════════════════ VIEW FUNCTIONS ═══════════════════════════════════════════ */

    /// @notice Get details of a crypto loan
    function getCryptoLoan(
        uint256 loanId
    ) external view returns (CryptoLoan memory) {
        return cryptoLoans[loanId];
    }

    /// @notice Get details of an off-chain loan
    function getOffchainLoan(
        uint256 requestId
    ) external view returns (OffchainLoan memory) {
        return offchainLoans[requestId];
    }

    /// @notice Get all crypto loan IDs for a user
    function getUserCryptoLoans(
        address user
    ) external view returns (uint256[] memory) {
        return userCryptoLoans[user];
    }

    /// @notice Get all off-chain loan IDs for a user
    function getUserOffchainLoans(
        address user
    ) external view returns (uint256[] memory) {
        return userOffchainLoans[user];
    }

    /// @notice Get the contract's outstanding borrow from Morpho
    function getOutstandingMorphoBorrow() external view returns (uint256) {
        Market memory mkt = morpho.market(morphoMarketId);
        Position memory morphoPos = morpho.position(
            morphoMarketId,
            address(this)
        );
        if (morphoPos.borrowShares == 0) return 0;
        return
            uint256(morphoPos.borrowShares).toAssetsUp(
                mkt.totalBorrowAssets,
                mkt.totalBorrowShares
            );
    }
}
