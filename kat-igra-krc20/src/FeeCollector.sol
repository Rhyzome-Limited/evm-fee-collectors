// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─── KRC-20 Bridge interface ──────────────────────────────────────────────────
// Bridge.sol on Igra: 0x295ad12c9F62594523Aa460F10a871aA8F1469cd
// Burn bridged ERC-20 tokens to release the original KRC-20 on Kaspa L1.
interface IKrc20Bridge {
    /// @notice Burns `_amount` of bridged ERC-20 `_token` and triggers L1 release.
    /// @param _token        Address of the bridged ERC-20 token on Igra.
    /// @param _amount       Gross token amount to burn (18 decimals).
    /// @param _kaspaAddress Kaspa L1 destination address (bech32 string, e.g. "kaspa:qz...").
    /// @dev  msg.value must equal burnFee() exactly — read it immediately before calling.
    function burnForBridgeBack(address _token, uint256 _amount, string calldata _kaspaAddress)
        external
        payable;

    /// @notice Current flat iKAS fee required per burn call.
    ///         Changes via multi-admin proposal — read immediately before signing.
    function burnFee() external view returns (uint256);
}

/// @title FeeCollector
/// @notice Wraps the KAT Igra `Bridge.sol` `burnForBridgeBack` and charges a
///         percentage fee on the ERC-20 token amount for every KRC-20 withdrawal.
///
///         Fee model:
///           - Our fee:    0.75% of `_amount` (in ERC-20 token, kept by this contract)
///           - Burn fee:   `bridge.burnFee()` iKAS flat (pass-through to Bridge.sol)
///
///         Flow for caller:
///           1. `token.approve(feeCollector, grossAmount)`
///           2. `feeCollector.bridgeToL1{value: bridge.burnFee()}(token, grossAmount, kaspaAddress)`
///
///         This contract keeps the token fee and forwards `netAmount` to the bridge.
///         The iKAS `msg.value` is forwarded exactly to the bridge — no iKAS fee taken.
contract FeeCollector {
    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_RATE = 1_000; // 10% hard cap

    // ─── State ───────────────────────────────────────────────────────────────
    address public owner;
    address public pendingOwner;
    address public withdrawer;
    uint256 public feeRate; // basis points (e.g. 75 = 0.75%)
    IKrc20Bridge public immutable bridge;

    // ─── Events ──────────────────────────────────────────────────────────────
    event OwnerSet(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferProposed(address indexed currentOwner, address indexed proposedOwner);
    event WithdrawerSet(address indexed previousWithdrawer, address indexed newWithdrawer);
    event FeeRateSet(uint256 previousFeeRate, uint256 newFeeRate);
    event FeeCollected(address indexed token, address indexed from, uint256 feeAmount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPendingOwner();
    error NotWithdrawer();
    error ZeroAddress();
    error FeeRateTooHigh();
    error TransferFailed();
    error InsufficientValue();
    error InsufficientBalance();
    error InvalidAddress();
    error IncorrectBurnFee();

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
    /// @param _owner         Admin: can change feeRate / withdrawer.
    /// @param _withdrawer    Address allowed to withdraw accumulated fees.
    /// @param _feeRate       Fee in basis points (75 = 0.75%, max 1000 = 10%).
    /// @param _bridge        KRC-20 Bridge.sol contract address on Igra.
    constructor(address _owner, address _withdrawer, uint256 _feeRate, address _bridge) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_withdrawer == address(0)) revert ZeroAddress();
        if (_bridge == address(0)) revert ZeroAddress();
        if (_feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();

        owner = _owner;
        withdrawer = _withdrawer;
        feeRate = _feeRate;
        bridge = IKrc20Bridge(_bridge);

        emit OwnerSet(address(0), _owner);
        emit WithdrawerSet(address(0), _withdrawer);
        emit FeeRateSet(0, _feeRate);
    }

    // ─── Admin setters ───────────────────────────────────────────────────────

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        pendingOwner = _newOwner;
        emit OwnershipTransferProposed(owner, _newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnerSet(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function setWithdrawer(address _newWithdrawer) external onlyOwner {
        if (_newWithdrawer == address(0)) revert ZeroAddress();
        emit WithdrawerSet(withdrawer, _newWithdrawer);
        withdrawer = _newWithdrawer;
    }

    function setFeeRate(uint256 _feeRate) external onlyOwner {
        if (_feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        emit FeeRateSet(feeRate, _feeRate);
        feeRate = _feeRate;
    }

    // ─── Fee helpers ─────────────────────────────────────────────────────────

    /// @notice Preview the fee and net amount for a given gross token amount.
    function calculateFee(uint256 amount) external view returns (uint256 fee, uint256 netAmount) {
        fee = (amount * feeRate) / FEE_DENOMINATOR;
        netAmount = amount - fee;
    }

    /// @notice Returns the current burn fee required by the upstream bridge (in iKAS).
    ///         Read this immediately before calling bridgeToL1 and pass as msg.value.
    function getBurnFee() external view returns (uint256) {
        return bridge.burnFee();
    }

    // ─── Bridge wrapper ──────────────────────────────────────────────────────

    /// @notice Bridge ERC-20 token from L2 back to KRC-20 on Kaspa L1.
    ///         Our 0.75% fee is deducted from `_amount` (in token).
    ///         The `msg.value` must equal `bridge.burnFee()` exactly — it is
    ///         forwarded to the bridge contract unchanged.
    ///
    /// @param _token        Bridged ERC-20 token address on Igra.
    /// @param _amount       Gross token amount (18 decimals). Caller must have
    ///                      approved this contract for at least `_amount`.
    /// @param _kaspaAddress Kaspa L1 destination address (bech32, e.g. "kaspa:qz...").
    ///                      Max 100 bytes. Must start with "kaspa:".
    ///
    /// @dev  Amount must be a multiple of 1e10 so the bridge's 18→8 decimal
    ///       scaling is lossless: `netAmount % 1e10 == 0`.
    ///       The bridge itself will revert if the net amount is not clean,
    ///       but callers should validate upstream to show a friendly error.
    function bridgeToL1(address _token, uint256 _amount, string calldata _kaspaAddress)
        external
        payable
    {
        if (_token == address(0)) revert ZeroAddress();
        if (_amount == 0) revert InsufficientValue();

        // Validate msg.value == upstream burnFee exactly
        uint256 requiredBurnFee = bridge.burnFee();
        if (msg.value != requiredBurnFee) revert IncorrectBurnFee();

        // Validate Kaspa address: starts with "kaspa:", max 100 bytes
        bytes memory addrBytes = bytes(_kaspaAddress);
        if (addrBytes.length < 7 || addrBytes.length > 100) revert InvalidAddress();
        if (
            addrBytes[0] != "k" || addrBytes[1] != "a" || addrBytes[2] != "s" ||
            addrBytes[3] != "p" || addrBytes[4] != "a" || addrBytes[5] != ":"
        ) revert InvalidAddress();

        // Pull gross amount from caller
        _safeTransferFrom(_token, msg.sender, address(this), _amount);

        // Deduct our fee
        uint256 fee = (_amount * feeRate) / FEE_DENOMINATOR;
        uint256 netAmount = _amount - fee;

        if (fee > 0) emit FeeCollected(_token, msg.sender, fee);

        // Approve bridge for net amount (reset first for USDT-style tokens)
        _safeApprove(_token, address(bridge), 0);
        _safeApprove(_token, address(bridge), netAmount);

        // Forward net amount + exact burnFee to bridge
        bridge.burnForBridgeBack{value: requiredBurnFee}(_token, netAmount, _kaspaAddress);

        // Reset approval to zero
        _safeApprove(_token, address(bridge), 0);
    }

    // ─── Safe ERC-20 helpers ─────────────────────────────────────────────────

    /// @dev Handles both bool-returning and void-returning (e.g. USDT) tokens.
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    // ─── Withdrawal ──────────────────────────────────────────────────────────

    function withdraw(address token, address to, uint256 amount) external onlyWithdrawer {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(0x70a08231, address(this))
        );
        uint256 bal = (ok && data.length == 32) ? abi.decode(data, (uint256)) : 0;
        if (amount > bal) revert InsufficientBalance();
        _safeTransfer(token, to, amount);
        emit Withdrawn(token, to, amount);
    }

    function withdrawAll(address token, address to) external onlyWithdrawer {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(0x70a08231, address(this))
        );
        uint256 bal = (ok && data.length == 32) ? abi.decode(data, (uint256)) : 0;
        if (bal == 0) revert InsufficientBalance();
        _safeTransfer(token, to, bal);
        emit Withdrawn(token, to, bal);
    }

    function withdrawNative(address payable to, uint256 amount) external onlyWithdrawer {
        if (to == address(0)) revert ZeroAddress();
        if (amount > address(this).balance) revert InsufficientBalance();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NativeWithdrawn(to, amount);
    }

    function withdrawAllNative(address payable to) external onlyWithdrawer {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) revert InsufficientBalance();
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit NativeWithdrawn(to, bal);
    }

    // ─── Receive ─────────────────────────────────────────────────────────────
    receive() external payable {}
}
