// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

// ─── Mock Bridge ──────────────────────────────────────────────────────────────
contract MockBridge {
    bytes public lastKaspaAddress;
    uint256 public lastValue;

    function lockForExit(bytes calldata kaspaAddress) external payable {
        lastKaspaAddress = kaspaAddress;
        lastValue = msg.value;
    }

    receive() external payable {}
}

// ─── Tests ────────────────────────────────────────────────────────────────────
contract FeeCollectorTest is Test {
    FeeCollector public fc;
    MockBridge public mockBridge;

    address owner      = makeAddr("owner");
    address withdrawer = makeAddr("withdrawer");
    address user       = makeAddr("user");
    address stranger   = makeAddr("stranger");

    uint256 constant DEFAULT_FEE_RATE = 75; // 0.75%
    uint256 constant FEE_DENOM = 10_000;
    string  constant L1_ADDR = "kaspa:qypr0qj7luv26laqlquan9n2zu7wyen87fkdw3kx3kd69ymyw3tj4tsh467xzf2";

    function setUp() public {
        mockBridge = new MockBridge();
        vm.prank(owner);
        fc = new FeeCollector(owner, withdrawer, DEFAULT_FEE_RATE, address(mockBridge));
        vm.deal(user, 1_000 ether);
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(fc.owner(), owner);
        assertEq(fc.withdrawer(), withdrawer);
        assertEq(fc.feeRate(), DEFAULT_FEE_RATE);
        assertEq(address(fc.bridge()), address(mockBridge));
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

    // ─── transferOwnership / acceptOwnership ──────────────────────────────────

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        fc.transferOwnership(newOwner);
        assertEq(fc.owner(), owner);
        assertEq(fc.pendingOwner(), newOwner);
        vm.prank(newOwner);
        fc.acceptOwnership();
        assertEq(fc.owner(), newOwner);
        assertEq(fc.pendingOwner(), address(0));
    }

    function test_transferOwnership_revertNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotOwner.selector);
        fc.transferOwnership(stranger);
    }

    function test_transferOwnership_revertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fc.transferOwnership(address(0));
    }

    function test_acceptOwnership_revertNotPending() public {
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotPendingOwner.selector);
        fc.acceptOwnership();
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
        uint256 amount = 10 ether;
        (uint256 fee, uint256 net) = fc.calculateFee(amount);
        assertEq(fee, (amount * DEFAULT_FEE_RATE) / FEE_DENOM);
        assertEq(net, amount - fee);
    }

    function testFuzz_calculateFee(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);
        (uint256 fee, uint256 net) = fc.calculateFee(amount);
        assertEq(fee + net, amount);
    }

    // ─── bridgeToL1 ───────────────────────────────────────────────────────────

    function test_bridgeToL1_basic() public {
        uint256 ikasIn = 10 ether;
        uint256 expectedFee = (ikasIn * DEFAULT_FEE_RATE) / FEE_DENOM;
        uint256 expectedNet = ikasIn - expectedFee;

        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit FeeCollector.FeeCollected(user, expectedFee);
        fc.bridgeToL1{value: ikasIn}(L1_ADDR);

        // Fee stays in FeeCollector
        assertEq(address(fc).balance, expectedFee);
        // Bridge received net amount
        assertEq(mockBridge.lastValue(), expectedNet);
        assertEq(address(mockBridge).balance, expectedNet);
    }

    function test_bridgeToL1_kaspaAddressPassedAsBytes() public {
        vm.prank(user);
        fc.bridgeToL1{value: 5 ether}("kaspa:qtest");

        // KasBridge receives raw UTF-8 bytes (no hex encoding)
        assertEq(mockBridge.lastKaspaAddress(), bytes("kaspa:qtest"));
    }

    function test_bridgeToL1_zeroFeeRate() public {
        vm.prank(owner);
        fc.setFeeRate(0);

        uint256 ikasIn = 5 ether;
        vm.prank(user);
        fc.bridgeToL1{value: ikasIn}(L1_ADDR);

        assertEq(address(fc).balance, 0);
        assertEq(mockBridge.lastValue(), ikasIn);
    }

    function test_bridgeToL1_revertZeroValue() public {
        vm.prank(user);
        vm.expectRevert(FeeCollector.InsufficientValue.selector);
        fc.bridgeToL1{value: 0}(L1_ADDR);
    }

    function test_bridgeToL1_revertInvalidAddress_empty() public {
        vm.prank(user);
        vm.expectRevert(FeeCollector.InvalidAddress.selector);
        fc.bridgeToL1{value: 5 ether}("");
    }

    function test_bridgeToL1_revertInvalidAddress_noPrefix() public {
        vm.prank(user);
        vm.expectRevert(FeeCollector.InvalidAddress.selector);
        fc.bridgeToL1{value: 5 ether}("qypr0qj7luv26laqlquan9n2zu7wyen87fkdw3k");
    }

    function test_bridgeToL1_revertInvalidAddress_tooLong() public {
        vm.prank(user);
        vm.expectRevert(FeeCollector.InvalidAddress.selector);
        // 101 bytes — exceeds max of 100
        fc.bridgeToL1{value: 5 ether}(
            "kaspa:qypr0qj7luv26laqlquan9n2zu7wyen87fkdw3kx3kd69ymyw3tj4tsh467xzf222222222222222222222222222222222"
        );
    }

    function test_bridgeToL1_maxLengthAddress() public {
        // exactly 100 bytes: "kaspa:" (6) + 94 'a' chars = 100
        string memory addr100 = "kaspa:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        assertEq(bytes(addr100).length, 100);
        vm.prank(user);
        fc.bridgeToL1{value: 5 ether}(addr100);
        assertEq(mockBridge.lastValue(), 5 ether - (5 ether * DEFAULT_FEE_RATE) / FEE_DENOM);
    }

    function testFuzz_bridgeToL1(uint256 ikasIn) public {
        ikasIn = bound(ikasIn, 1 ether, 500 ether);
        vm.deal(user, ikasIn);

        uint256 expectedFee = (ikasIn * DEFAULT_FEE_RATE) / FEE_DENOM;
        uint256 expectedNet = ikasIn - expectedFee;

        vm.prank(user);
        fc.bridgeToL1{value: ikasIn}(L1_ADDR);

        assertEq(address(fc).balance, expectedFee);
        assertEq(mockBridge.lastValue(), expectedNet);
    }

    // ─── withdrawNative ───────────────────────────────────────────────────────

    function _accumulateFee(uint256 amount) internal {
        vm.prank(user);
        fc.bridgeToL1{value: amount}(L1_ADDR);
    }

    function test_withdrawNative_byWithdrawer() public {
        _accumulateFee(10 ether);
        uint256 bal = address(fc).balance;

        vm.prank(withdrawer);
        fc.withdrawNative(payable(withdrawer), bal);
        assertEq(withdrawer.balance, bal);
        assertEq(address(fc).balance, 0);
    }

    function test_withdrawNative_byOwner() public {
        _accumulateFee(10 ether);
        uint256 bal = address(fc).balance;

        vm.prank(owner);
        fc.withdrawNative(payable(owner), bal);
        assertEq(owner.balance, bal);
    }

    function test_withdrawNative_revertNotWithdrawer() public {
        _accumulateFee(10 ether);
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
        _accumulateFee(10 ether);
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
