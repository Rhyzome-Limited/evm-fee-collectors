// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

// ─── Zealous Swap Router interface (subset we need) ───────────────────────────
interface IZealousSwapRouter {
    function WKAS() external pure returns (address);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForKAS(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactKASForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path, bool isDiscountEligible)
        external
        view
        returns (uint256[] memory amounts);
}

/// @title FeeCollector
/// @notice Wraps the Zealous Swap Router and charges a fee on every swap.
///         Default fee rate is 0.75% (75 / 10000).
///         The fee is deducted from the input token *before* forwarding to the router.
contract FeeCollector {
    // ─── Constants ──────────────────────────────────────────────────────────
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_RATE = 1_000; // 10% hard cap

    // ─── State ───────────────────────────────────────────────────────────────
    address public owner;
    address public withdrawer;
    uint256 public feeRate; // basis points (e.g. 75 = 0.75%)
    IZealousSwapRouter public immutable router;

    // ─── Events ──────────────────────────────────────────────────────────────
    event OwnerSet(address indexed previousOwner, address indexed newOwner);
    event WithdrawerSet(address indexed previousWithdrawer, address indexed newWithdrawer);
    event FeeRateSet(uint256 previousFeeRate, uint256 newFeeRate);
    event FeeCollected(address indexed token, address indexed from, uint256 feeAmount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────
    error NotOwner();
    error NotWithdrawer();
    error ZeroAddress();
    error FeeRateTooHigh();
    error TransferFailed();
    error InsufficientBalance();
    error InvalidPath();

    // ─── Modifiers ───────────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyWithdrawer() {
        if (msg.sender != withdrawer && msg.sender != owner) revert NotWithdrawer();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────
    /// @param _owner         Initial owner (can set fee rate / withdrawer).
    /// @param _withdrawer    Address allowed to withdraw accumulated fees.
    /// @param _feeRate       Fee in basis points (75 = 0.75%).
    /// @param _router        Zealous Swap Router address.
    constructor(address _owner, address _withdrawer, uint256 _feeRate, address _router) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_withdrawer == address(0)) revert ZeroAddress();
        if (_router == address(0)) revert ZeroAddress();
        if (_feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();

        owner = _owner;
        withdrawer = _withdrawer;
        feeRate = _feeRate;
        router = IZealousSwapRouter(_router);

        emit OwnerSet(address(0), _owner);
        emit WithdrawerSet(address(0), _withdrawer);
        emit FeeRateSet(0, _feeRate);
    }

    // ─── Admin setters ───────────────────────────────────────────────────────

    function setOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnerSet(owner, _newOwner);
        owner = _newOwner;
    }

    function setWithdrawer(address _newWithdrawer) external onlyOwner {
        if (_newWithdrawer == address(0)) revert ZeroAddress();
        emit WithdrawerSet(withdrawer, _newWithdrawer);
        withdrawer = _newWithdrawer;
    }

    /// @param _feeRate New fee rate in basis points. Must be <= MAX_FEE_RATE.
    function setFeeRate(uint256 _feeRate) external onlyOwner {
        if (_feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        emit FeeRateSet(feeRate, _feeRate);
        feeRate = _feeRate;
    }

    // ─── Fee helpers ─────────────────────────────────────────────────────────

    /// @notice Preview the fee and net amount for a given gross amount.
    function calculateFee(uint256 amount) external view returns (uint256 fee, uint256 netAmount) {
        fee = (amount * feeRate) / FEE_DENOMINATOR;
        netAmount = amount - fee;
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    function _takeFee(address token, address from, uint256 amount)
        internal
        returns (uint256 netAmount)
    {
        // Pull full amount from caller
        bool ok = IERC20(token).transferFrom(from, address(this), amount);
        if (!ok) revert TransferFailed();

        uint256 fee = (amount * feeRate) / FEE_DENOMINATOR;
        netAmount = amount - fee;

        if (fee > 0) emit FeeCollected(token, from, fee);

        // Reset to 0 first to support tokens (e.g. USDT) that require allowance
        // to be zero before setting a new value, then approve the net amount.
        IERC20(token).approve(address(router), 0);
        IERC20(token).approve(address(router), netAmount);
    }

    // ─── Swap wrappers ───────────────────────────────────────────────────────

    /// @notice Swap exact `amountIn` of tokenIn → tokenOut via Zealous Swap.
    ///         Fee is charged on `amountIn`; the router receives `amountIn - fee`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        uint256 netAmountIn = _takeFee(path[0], msg.sender, amountIn);
        amounts = router.swapExactTokensForTokens(netAmountIn, amountOutMin, path, to, deadline);
    }

    /// @notice Swap exact `amountIn` of token → KAS via Zealous Swap.
    function swapExactTokensForKAS(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        uint256 netAmountIn = _takeFee(path[0], msg.sender, amountIn);
        amounts = router.swapExactTokensForKAS(netAmountIn, amountOutMin, path, to, deadline);
    }

    /// @notice Swap KAS → tokens via Zealous Swap. Fee is deducted from msg.value.
    function swapExactKASForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        uint256 fee = (msg.value * feeRate) / FEE_DENOMINATOR;
        uint256 netValue = msg.value - fee;

        if (fee > 0) emit FeeCollected(address(0), msg.sender, fee);

        amounts =
            router.swapExactKASForTokens{value: netValue}(amountOutMin, path, to, deadline);
    }

    /// @notice Quote: how much output you get for `amountIn` after fee deduction.
    function getAmountsOut(uint256 amountIn, address[] calldata path, bool isDiscountEligible)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 fee = (amountIn * feeRate) / FEE_DENOMINATOR;
        uint256 netAmountIn = amountIn - fee;
        amounts = router.getAmountsOut(netAmountIn, path, isDiscountEligible);
    }

    // ─── Withdrawal ──────────────────────────────────────────────────────────

    function withdraw(address token, address to, uint256 amount) external onlyWithdrawer {
        if (to == address(0)) revert ZeroAddress();
        if (amount > IERC20(token).balanceOf(address(this))) revert InsufficientBalance();
        bool ok = IERC20(token).transfer(to, amount);
        if (!ok) revert TransferFailed();
        emit Withdrawn(token, to, amount);
    }

    function withdrawAll(address token, address to) external onlyWithdrawer {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert InsufficientBalance();
        bool ok = IERC20(token).transfer(to, bal);
        if (!ok) revert TransferFailed();
        emit Withdrawn(token, to, bal);
    }

    function withdrawNative(address payable to, uint256 amount) external onlyWithdrawer {
        if (to == address(0)) revert ZeroAddress();
        if (amount > address(this).balance) revert InsufficientBalance();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NativeWithdrawn(to, amount);
    }

    // ─── Receive native token ────────────────────────────────────────────────
    receive() external payable {}
}
