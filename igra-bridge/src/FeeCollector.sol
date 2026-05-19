// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─── Igra KasExitBridge interface ────────────────────────────────────────────
// Bridges iKAS (Igra L2) back to KAS (Kaspa L1).
// Proxy: 0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0 (Igra Mainnet, chain 38833)
interface IKasExitBridge {
    /// @notice Quote the bridge fee for a given exit amount.
    /// @param originBurner      Address that will call requestExit.
    /// @param unlockAmountSompi Amount to unlock on L1, in sompi.
    /// @return feeAmountSompi   Bridge protocol fee in sompi (currently 0).
    function quoteFee(address originBurner, uint64 unlockAmountSompi)
        external
        view
        returns (uint64 feeAmountSompi);

    /// @notice Submit an exit request. msg.value MUST equal exactly
    ///         (unlockAmountSompi + feeAmountSompi) * SOMPI_SCALE.
    /// @param kasPayoutAddress  L1 Kaspa address (e.g. "kaspa:qr...").
    /// @param unlockAmountSompi Amount to unlock on L1, in sompi (min 1000 KAS = 1e11 sompi).
    function requestExit(string calldata kasPayoutAddress, uint64 unlockAmountSompi)
        external
        payable
        returns (uint32 requestId, bytes32 messageId);
}

/// @title FeeCollector
/// @notice Wraps the Igra KasExitBridge `requestExit` and charges a configurable
///         fee on every bridge transaction. Fee is deducted from `msg.value`
///         before forwarding to the bridge contract.
///
///         Unit conversion:
///           1 KAS = 1e8 sompi = 1e18 wei
///           SOMPI_SCALE = 1e10  (sompi × 1e10 = wei)
///
///         Minimum bridge: 1,000 KAS (enforced by the bridge contract).
///         Any wei dust from integer division is retained as additional fee.
///
///         Default fee rate: 0.75% (75 / 10000).
contract FeeCollector {
    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_RATE    = 1_000;  // 10% hard cap
    uint256 public constant SOMPI_SCALE     = 1e10;   // wei per sompi
    uint64  public constant MIN_UNLOCK_SOMPI = 1_000 * 1e8; // 1,000 KAS in sompi

    // ─── State ───────────────────────────────────────────────────────────────
    address public owner;
    address public withdrawer;
    uint256 public feeRate;           // basis points (e.g. 75 = 0.75%)
    IKasExitBridge public immutable bridge;

    // ─── Events ──────────────────────────────────────────────────────────────
    event OwnerSet(address indexed previousOwner, address indexed newOwner);
    event WithdrawerSet(address indexed previousWithdrawer, address indexed newWithdrawer);
    event FeeRateSet(uint256 previousFeeRate, uint256 newFeeRate);
    event FeeCollected(address indexed from, uint256 feeAmount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────
    error NotOwner();
    error NotWithdrawer();
    error ZeroAddress();
    error FeeRateTooHigh();
    error TransferFailed();
    error InsufficientValue();
    error InsufficientBalance();
    error BelowMinimum();         // net amount < 1,000 KAS after fee deduction

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
    /// @param _owner       Admin: can change feeRate / withdrawer.
    /// @param _withdrawer  Address allowed to withdraw accumulated fees.
    /// @param _feeRate     Fee in basis points (75 = 0.75%, max 1000 = 10%).
    /// @param _bridge      Igra KasExitBridge proxy address.
    constructor(address _owner, address _withdrawer, uint256 _feeRate, address _bridge) {
        if (_owner == address(0))      revert ZeroAddress();
        if (_withdrawer == address(0)) revert ZeroAddress();
        if (_bridge == address(0))     revert ZeroAddress();
        if (_feeRate > MAX_FEE_RATE)   revert FeeRateTooHigh();

        owner      = _owner;
        withdrawer = _withdrawer;
        feeRate    = _feeRate;
        bridge     = IKasExitBridge(_bridge);

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

    function setFeeRate(uint256 _feeRate) external onlyOwner {
        if (_feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        emit FeeRateSet(feeRate, _feeRate);
        feeRate = _feeRate;
    }

    // ─── Fee helpers ─────────────────────────────────────────────────────────

    /// @notice Preview the our fee and net wei for a given gross value.
    function calculateFee(uint256 amount) external view returns (uint256 fee, uint256 netAmount) {
        fee       = (amount * feeRate) / FEE_DENOMINATOR;
        netAmount = amount - fee;
    }

    // ─── Bridge wrapper ──────────────────────────────────────────────────────

    /// @notice Bridge iKAS from Igra to Kaspa L1. Our fee is deducted from
    ///         `msg.value`; the remainder is converted to sompi and forwarded
    ///         to the bridge contract.
    ///
    ///         The bridge requires msg.value to be exactly
    ///         `(unlockAmountSompi + bridgeFee) * SOMPI_SCALE`.
    ///         Any wei dust from integer truncation is kept as additional fee.
    ///
    /// @param kasPayoutAddress  L1 Kaspa address (e.g. "kaspa:qr...").
    function bridgeToL1(string calldata kasPayoutAddress) external payable {
        if (msg.value == 0) revert InsufficientValue();

        // 1. Deduct our fee
        uint256 ourFee  = (msg.value * feeRate) / FEE_DENOMINATOR;
        uint256 netWei  = msg.value - ourFee;

        // 2. Convert net wei → sompi (truncate; dust stays as fee)
        //    Safe: netWei / 1e10 fits uint64 for any realistic KAS amount
        //    (uint64 max ≈ 1.8e19 sompi = 184 billion KAS)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 tentativeUnlock = uint64(netWei / SOMPI_SCALE);
        if (tentativeUnlock < MIN_UNLOCK_SOMPI) revert BelowMinimum();

        // 3. Quote bridge protocol fee (currently 0)
        //    Bridge fee is deducted from the unlock amount — the user receives
        //    (tentativeUnlock - bridgeFee) on L1. Total wei forwarded to bridge
        //    stays constant at tentativeUnlock * SOMPI_SCALE.
        uint64 bridgeFee      = bridge.quoteFee(address(this), tentativeUnlock);
        uint64 actualUnlock   = tentativeUnlock - bridgeFee;
        if (actualUnlock < MIN_UNLOCK_SOMPI) revert BelowMinimum();

        // 4. bridgeWei = (actualUnlock + bridgeFee) * SOMPI_SCALE = tentativeUnlock * SOMPI_SCALE
        //    This is always <= netWei (truncation dust retained as fee)
        uint256 bridgeWei = uint256(tentativeUnlock) * SOMPI_SCALE;

        // 5. Dust from truncation stays alongside ourFee
        uint256 totalFee = ourFee + (netWei - bridgeWei);
        if (totalFee > 0) emit FeeCollected(msg.sender, totalFee);

        // 6. Forward exact amount to bridge
        bridge.requestExit{value: bridgeWei}(kasPayoutAddress, actualUnlock);
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
