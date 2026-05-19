// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

// ─── Mock Bridge ──────────────────────────────────────────────────────────────
contract MockBridge {
    string  public lastKasPayoutAddress;
    uint64  public lastUnlockAmountSompi;
    uint256 public lastValue;
    uint64  public mockFeeAmountSompi; // simulate bridge protocol fee
    bool    public shouldRevert;

    function setMockFee(uint64 _fee) external { mockFeeAmountSompi = _fee; }
    function setShouldRevert(bool _r) external { shouldRevert = _r; }

    function quoteFee(address, uint64) external view returns (uint64) {
        return mockFeeAmountSompi;
    }

    function requestExit(string calldata kasPayoutAddress, uint64 unlockAmountSompi)
        external
        payable
        returns (uint32 requestId, bytes32 messageId)
    {
        if (shouldRevert) revert("bridge reverted");
        lastKasPayoutAddress = kasPayoutAddress;
        lastUnlockAmountSompi = unlockAmountSompi;
        lastValue = msg.value;
        return (1, bytes32(uint256(1)));
    }

    receive() external payable {}
}

// ─── Tests ────────────────────────────────────────────────────────────────────
contract FeeCollectorTest is Test {
    FeeCollector public fc;
    MockBridge   public mockBridge;

    address owner      = makeAddr("owner");
    address withdrawer = makeAddr("withdrawer");
    address user       = makeAddr("user");
    address stranger   = makeAddr("stranger");

    uint256 constant DEFAULT_FEE_RATE   = 75;  // 0.75%
    uint256 constant FEE_DENOM          = 10_000;
    uint256 constant SOMPI_SCALE        = 1e10;
    uint64  constant MIN_UNLOCK_SOMPI   = 1_000 * 1e8; // 1,000 KAS
    uint256 constant MIN_WEI            = uint256(MIN_UNLOCK_SOMPI) * SOMPI_SCALE; // 1,000 KAS in wei

    string constant KAS_ADDR = "kaspa:qypr0qj7luv26laqlquan9n2zu7wyen87fkdw3kx3kd69ymyw3tj4tsh467xzf2";

    function setUp() public {
        mockBridge = new MockBridge();
        fc = new FeeCollector(owner, withdrawer, DEFAULT_FEE_RATE, address(mockBridge));
        vm.deal(user, 1_000_000 ether);
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(fc.owner(), owner);
        assertEq(fc.withdrawer(), withdrawer);
        assertEq(fc.feeRate(), DEFAULT_FEE_RATE);
        assertEq(address(fc.bridge()), address(mockBridge));
        assertEq(fc.SOMPI_SCALE(), SOMPI_SCALE);
        assertEq(fc.MIN_UNLOCK_SOMPI(), MIN_UNLOCK_SOMPI);
    }

    function test_constructor_revertZeroOwner() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(address(0), withdrawer, DEFAULT_FEE_RATE, address(mockBridge));
    }

    function test_constructor_revertZeroWithdrawer() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(owner, address(0), DEFAULT_FEE_RATE, address(mockBridge));
    }

    function test_constructor_revertZeroBridge() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(owner, withdrawer, DEFAULT_FEE_RATE, address(0));
    }

    function test_constructor_revertFeeRateTooHigh() public {
        vm.expectRevert(FeeCollector.FeeRateTooHigh.selector);
        new FeeCollector(owner, withdrawer, 1_001, address(mockBridge));
    }

    // ─── setOwner ─────────────────────────────────────────────────────────────

    function test_setOwner() public {
        address nw = makeAddr("nw");
        vm.prank(owner);
        fc.setOwner(nw);
        assertEq(fc.owner(), nw);
    }

    function test_setOwner_revertNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotOwner.selector);
        fc.setOwner(stranger);
    }

    function test_setOwner_revertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fc.setOwner(address(0));
    }

    // ─── setWithdrawer ────────────────────────────────────────────────────────

    function test_setWithdrawer() public {
        address nw = makeAddr("nw");
        vm.prank(owner);
        fc.setWithdrawer(nw);
        assertEq(fc.withdrawer(), nw);
    }

    function test_setWithdrawer_revertNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotOwner.selector);
        fc.setWithdrawer(stranger);
    }

    // ─── setFeeRate ───────────────────────────────────────────────────────────

    function test_setFeeRate() public {
        vm.prank(owner);
        fc.setFeeRate(100);
        assertEq(fc.feeRate(), 100);
    }

    function test_setFeeRate_toZero() public {
        vm.prank(owner);
        fc.setFeeRate(0);
        assertEq(fc.feeRate(), 0);
    }

    function test_setFeeRate_revertNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotOwner.selector);
        fc.setFeeRate(100);
    }

    function test_setFeeRate_revertTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.FeeRateTooHigh.selector);
        fc.setFeeRate(1_001);
    }

    function test_setFeeRate_exactMax() public {
        vm.prank(owner);
        fc.setFeeRate(1_000);
        assertEq(fc.feeRate(), 1_000);
    }

    // ─── calculateFee ─────────────────────────────────────────────────────────

    function test_calculateFee_default() public view {
        uint256 amount = 10_000 ether;
        (uint256 fee, uint256 net) = fc.calculateFee(amount);
        assertEq(fee, (amount * DEFAULT_FEE_RATE) / FEE_DENOM);
        assertEq(net, amount - fee);
    }

    function testFuzz_calculateFee(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);
        (uint256 fee, uint256 net) = fc.calculateFee(amount);
        assertEq(fee + net, amount);
    }

    // ─── bridgeToL1 ──────────────────────────────────────────────────────────

    // Helper: compute what the contract will forward to the bridge
    function _expectedBridgeWei(uint256 grossWei) internal view returns (
        uint256 ourFee,
        uint256 netWei,
        uint64  actualUnlock,
        uint256 bridgeWei,
        uint256 totalFee
    ) {
        ourFee      = (grossWei * DEFAULT_FEE_RATE) / FEE_DENOM;
        netWei      = grossWei - ourFee;
        uint64 tentative = uint64(netWei / SOMPI_SCALE);
        uint64 bFee      = mockBridge.mockFeeAmountSompi();
        actualUnlock = tentative - bFee;
        bridgeWei    = uint256(tentative) * SOMPI_SCALE; // = (actualUnlock + bFee) * SOMPI_SCALE
        totalFee     = ourFee + (netWei - bridgeWei);
    }

    function test_bridgeToL1_basic() public {
        uint256 grossWei = 10_000 ether; // 10,000 KAS
        (uint256 ourFee,, uint64 actualUnlock, uint256 bridgeWei, uint256 totalFee) =
            _expectedBridgeWei(grossWei);

        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit FeeCollector.FeeCollected(user, totalFee);
        fc.bridgeToL1{value: grossWei}(KAS_ADDR);

        assertEq(address(fc).balance, totalFee);
        assertEq(mockBridge.lastValue(), bridgeWei);
        assertEq(mockBridge.lastUnlockAmountSompi(), actualUnlock);
        assertEq(mockBridge.lastKasPayoutAddress(), KAS_ADDR);
    }

    function test_bridgeToL1_zeroFeeRate() public {
        vm.prank(owner);
        fc.setFeeRate(0);

        uint256 grossWei    = 5_000 ether;
        uint64  unlockSompi = uint64(grossWei / SOMPI_SCALE);
        uint256 bridgeWei   = uint256(unlockSompi) * SOMPI_SCALE;
        uint256 dust        = grossWei - bridgeWei;

        vm.prank(user);
        fc.bridgeToL1{value: grossWei}(KAS_ADDR);

        // Only dust (if any) stays; bridge gets bridgeWei
        assertEq(address(fc).balance, dust);
        assertEq(mockBridge.lastValue(), bridgeWei);
    }

    function test_bridgeToL1_withBridgeFee() public {
        // Simulate bridge charging 1 KAS protocol fee
        uint64 protocolFeeSompi = 1 * 1e8; // 1 KAS
        mockBridge.setMockFee(protocolFeeSompi);

        uint256 grossWei      = 5_000 ether;
        uint256 ourFee        = (grossWei * DEFAULT_FEE_RATE) / FEE_DENOM;
        uint256 netWei        = grossWei - ourFee;
        uint64  tentative     = uint64(netWei / SOMPI_SCALE);
        uint64  actualUnlock  = tentative - protocolFeeSompi;
        uint256 bridgeWei     = uint256(tentative) * SOMPI_SCALE;

        vm.prank(user);
        fc.bridgeToL1{value: grossWei}(KAS_ADDR);

        // Bridge receives (actualUnlock + bridgeFee) * SOMPI_SCALE = tentative * SOMPI_SCALE
        assertEq(mockBridge.lastValue(), bridgeWei);
        // requestExit is called with actualUnlock (user gets this on L1)
        assertEq(mockBridge.lastUnlockAmountSompi(), actualUnlock);
    }

    function test_bridgeToL1_revertZeroValue() public {
        vm.prank(user);
        vm.expectRevert(FeeCollector.InsufficientValue.selector);
        fc.bridgeToL1{value: 0}(KAS_ADDR);
    }

    function test_bridgeToL1_revertBelowMinimum_tooSmall() public {
        // Send just under 1,000 KAS (after fee, net < min)
        // At 0.75% fee: to get >= 1000 KAS net, need >= 1007.55... KAS gross
        // Send exactly 1,000 KAS → net ~992.5 KAS → unlockSompi < MIN
        uint256 exactMin = MIN_WEI; // 1,000 KAS

        vm.prank(user);
        vm.expectRevert(FeeCollector.BelowMinimum.selector);
        fc.bridgeToL1{value: exactMin}(KAS_ADDR);
    }

    function test_bridgeToL1_exactlyMinAfterFee() public {
        // Need net wei / SOMPI_SCALE >= MIN_UNLOCK_SOMPI
        // net = gross * (1 - 0.0075); gross = MIN_WEI / 0.9925
        // gross = 1000e18 * 10000 / 9925 + 1 wei buffer
        uint256 grossWei = (MIN_WEI * FEE_DENOM) / (FEE_DENOM - DEFAULT_FEE_RATE) + SOMPI_SCALE;

        vm.prank(user);
        fc.bridgeToL1{value: grossWei}(KAS_ADDR);

        assertGe(mockBridge.lastUnlockAmountSompi(), MIN_UNLOCK_SOMPI);
    }

    function test_bridgeToL1_revertBridgeReverts() public {
        mockBridge.setShouldRevert(true);
        vm.prank(user);
        vm.expectRevert();
        fc.bridgeToL1{value: 5_000 ether}(KAS_ADDR);
    }

    function testFuzz_bridgeToL1(uint256 grossWei) public {
        // Bound: must be enough to clear min after fee (≈1007.55 KAS)
        uint256 minGross = (MIN_WEI * FEE_DENOM) / (FEE_DENOM - DEFAULT_FEE_RATE) + SOMPI_SCALE;
        grossWei = bound(grossWei, minGross, 500_000 ether);
        vm.deal(user, grossWei);

        (,, uint64 actualUnlock, uint256 bridgeWei, uint256 totalFee) =
            _expectedBridgeWei(grossWei);

        vm.prank(user);
        fc.bridgeToL1{value: grossWei}(KAS_ADDR);

        assertEq(address(fc).balance, totalFee);
        assertEq(mockBridge.lastValue(), bridgeWei);
        assertGe(mockBridge.lastUnlockAmountSompi(), MIN_UNLOCK_SOMPI);
        assertEq(mockBridge.lastUnlockAmountSompi(), actualUnlock);
    }

    // ─── withdrawNative ───────────────────────────────────────────────────────

    function _accumulateFee() internal {
        uint256 gross = 5_000 ether;
        vm.deal(user, gross);
        vm.prank(user);
        fc.bridgeToL1{value: gross}(KAS_ADDR);
    }

    function test_withdrawNative_byWithdrawer() public {
        _accumulateFee();
        uint256 bal = address(fc).balance;
        assertTrue(bal > 0);

        vm.prank(withdrawer);
        fc.withdrawNative(payable(withdrawer), bal);
        assertEq(withdrawer.balance, bal);
        assertEq(address(fc).balance, 0);
    }

    function test_withdrawNative_byOwner() public {
        _accumulateFee();
        uint256 bal = address(fc).balance;

        vm.prank(owner);
        fc.withdrawNative(payable(owner), bal);
        assertEq(owner.balance, bal);
    }

    function test_withdrawNative_revertNotWithdrawer() public {
        _accumulateFee();
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotWithdrawer.selector);
        fc.withdrawNative(payable(stranger), 1 ether);
    }

    function test_withdrawNative_revertInsufficientBalance() public {
        vm.deal(address(fc), 1 ether);
        vm.prank(withdrawer);
        vm.expectRevert(FeeCollector.InsufficientBalance.selector);
        fc.withdrawNative(payable(withdrawer), 2 ether);
    }

    function test_withdrawAllNative() public {
        _accumulateFee();
        uint256 bal = address(fc).balance;

        vm.prank(withdrawer);
        fc.withdrawAllNative(payable(withdrawer));
        assertEq(withdrawer.balance, bal);
        assertEq(address(fc).balance, 0);
    }

    function test_withdrawAllNative_revertEmpty() public {
        vm.prank(withdrawer);
        vm.expectRevert(FeeCollector.InsufficientBalance.selector);
        fc.withdrawAllNative(payable(withdrawer));
    }

    function test_receive_nativeToken() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(fc).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(fc).balance, 1 ether);
    }
}
