// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─── Kasplex Bridge interface ─────────────────────────────────────────────────
// Bridge L2 → L1: send KAS + L1 recipient address encoded as payload.
// Contract: 0x34606e6d01280f49791628b311cf33a808d1f7c6
interface IKasplexBridge {
    /// @param payload ABI-encoded L1 recipient address (as UTF-8 hex string).
    function lockForBridge(bytes calldata payload) external payable returns (bool);
}

/// @title FeeCollector
/// @notice Wraps the Kasplex Bridge `lockForBridge` and charges a fee on every
///         bridge transaction. Fee is deducted from `msg.value` before
///         forwarding to the bridge contract.
///         Default fee rate: 0.75% (75 / 10000).
contract FeeCollector {
    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_RATE = 1_000; // 10% hard cap

    // ─── State ───────────────────────────────────────────────────────────────
    address public owner;
    address public pendingOwner;
    address public withdrawer;
    uint256 public feeRate; // basis points (e.g. 75 = 0.75%)
    IKasplexBridge public immutable bridge;

    // ─── Events ──────────────────────────────────────────────────────────────
    event OwnerSet(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferProposed(address indexed currentOwner, address indexed proposedOwner);
    event WithdrawerSet(address indexed previousWithdrawer, address indexed newWithdrawer);
    event FeeRateSet(uint256 previousFeeRate, uint256 newFeeRate);
    event FeeCollected(address indexed from, uint256 feeAmount);
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
    error BridgeFailed();
    error InvalidAddress();

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
    /// @param _bridge        Kasplex Bridge L2 contract address.
    constructor(address _owner, address _withdrawer, uint256 _feeRate, address _bridge) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_withdrawer == address(0)) revert ZeroAddress();
        if (_bridge == address(0)) revert ZeroAddress();
        if (_feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();

        owner = _owner;
        withdrawer = _withdrawer;
        feeRate = _feeRate;
        bridge = IKasplexBridge(_bridge);

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

    /// @notice Preview the fee and net amount for a given gross value.
    function calculateFee(uint256 amount) external view returns (uint256 fee, uint256 netAmount) {
        fee = (amount * feeRate) / FEE_DENOMINATOR;
        netAmount = amount - fee;
    }

    // ─── Bridge wrapper ──────────────────────────────────────────────────────

    /// @notice Bridge KAS from L2 to L1. Fee is deducted from `msg.value`;
    ///         the remainder is forwarded to the bridge contract.
    /// @param l1Recipient  L1 Kaspa address (UTF-8 encoded, e.g. "kaspa:qy...").
    function bridgeToL1(string calldata l1Recipient) external payable {
        if (msg.value == 0) revert InsufficientValue();

        // Validate Kaspa address: non-empty, starts with "kaspa:", max 90 bytes
        bytes memory addrBytes = bytes(l1Recipient);
        if (addrBytes.length < 7 || addrBytes.length > 90) revert InvalidAddress();
        if (
            addrBytes[0] != "k" || addrBytes[1] != "a" || addrBytes[2] != "s" ||
            addrBytes[3] != "p" || addrBytes[4] != "a" || addrBytes[5] != ":"
        ) revert InvalidAddress();
        uint256 fee = (msg.value * feeRate) / FEE_DENOMINATOR;
        uint256 netValue = msg.value - fee;

        if (fee > 0) emit FeeCollected(msg.sender, fee);

        // Encode L1 address as UTF-8 hex string payload (matching bridge spec)
        bytes memory payload = _encodePayload(l1Recipient);
        bool ok = bridge.lockForBridge{value: netValue}(payload);
        if (!ok) revert BridgeFailed();
    }

    /// @dev Converts the L1 recipient string to its UTF-8 hex representation,
    ///      matching the payload format expected by the Kasplex bridge.
    ///      e.g. "kaspa:q..." → "6b61737061..." (each byte → 2 hex chars)
    function _encodePayload(string calldata l1Recipient)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory src = bytes(l1Recipient);
        bytes memory encoded = new bytes(src.length * 2);
        bytes memory alphabet = "0123456789abcdef";

        for (uint256 i = 0; i < src.length; i++) {
            encoded[i * 2]     = alphabet[uint8(src[i]) >> 4];
            encoded[i * 2 + 1] = alphabet[uint8(src[i]) & 0x0f];
        }
        return encoded;
    }

    // ─── Withdrawal ──────────────────────────────────────────────────────────

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
