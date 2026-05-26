// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

// ─── Mock ERC-20 ─────────────────────────────────────────────────────────────
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─── Mock Bridge ──────────────────────────────────────────────────────────────
contract MockBridge {
    address public lastToken;
    uint256 public lastAmount;
    string  public lastKaspaAddress;
    uint256 public lastValue;
    uint256 public fixedBurnFee = 0.01 ether;

    function burnFee() external view returns (uint256) {
        return fixedBurnFee;
    }

    function setBurnFee(uint256 fee) external {
        fixedBurnFee = fee;
    }

    function burnForBridgeBack(address _token, uint256 _amount, string calldata _kaspaAddress)
        external
        payable
    {
        require(msg.value == fixedBurnFee, "wrong fee");
        // Simulate real bridge pulling tokens from FeeCollector
        (bool ok, bytes memory data) = _token.call(
            abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), _amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
        lastToken = _token;
        lastAmount = _amount;
        lastKaspaAddress = _kaspaAddress;
        lastValue = msg.value;
    }

    receive() external payable {}
}

// ─── Tests ────────────────────────────────────────────────────────────────────
contract FeeCollectorTest is Test {
    FeeCollector public fc;
    MockBridge   public mockBridge;
    MockERC20    public token;

    address owner      = makeAddr("owner");
    address withdrawer = makeAddr("withdrawer");
    address user       = makeAddr("user");
    address stranger   = makeAddr("stranger");

    uint256 constant DEFAULT_FEE_RATE = 75; // 0.75%
    uint256 constant FEE_DENOM = 10_000;
    uint256 constant BURN_FEE  = 0.01 ether;
    string  constant L1_ADDR   = "kaspa:qypr0qj7luv26laqlquan9n2zu7wyen87fkdw3kx3kd69ymyw3tj4tsh467xzf2";

    function setUp() public {
        mockBridge = new MockBridge();
        token = new MockERC20();
        fc = new FeeCollector(owner, withdrawer, DEFAULT_FEE_RATE, address(mockBridge));

        // Fund user with tokens and iKAS
        token.mint(user, 10_000 ether);
        vm.deal(user, 100 ether);
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

    function test_acceptOwnership_revertNotPending() public {
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotPendingOwner.selector);
        fc.acceptOwnership();
    }

    // ─── setWithdrawer / setFeeRate ───────────────────────────────────────────

    function test_setWithdrawer() public {
        address nw = makeAddr("nw");
        vm.prank(owner);
        fc.setWithdrawer(nw);
        assertEq(fc.withdrawer(), nw);
    }

    function test_setFeeRate() public {
        vm.prank(owner);
        fc.setFeeRate(100);
        assertEq(fc.feeRate(), 100);
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

    // ─── calculateFee / getBurnFee ────────────────────────────────────────────

    function test_calculateFee() public view {
        uint256 amount = 1_000 ether;
        (uint256 fee, uint256 net) = fc.calculateFee(amount);
        assertEq(fee, (amount * DEFAULT_FEE_RATE) / FEE_DENOM);
        assertEq(net, amount - fee);
    }

    function testFuzz_calculateFee(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);
        (uint256 fee, uint256 net) = fc.calculateFee(amount);
        assertEq(fee + net, amount);
    }

    function test_getBurnFee() public view {
        assertEq(fc.getBurnFee(), BURN_FEE);
    }

    // ─── bridgeToL1 ──────────────────────────────────────────────────────────

    function _approve(address from, uint256 amount) internal {
        vm.prank(from);
        token.approve(address(fc), amount);
    }

    function test_bridgeToL1_basic() public {
        uint256 gross = 1_000 ether;
        uint256 expectedFee = (gross * DEFAULT_FEE_RATE) / FEE_DENOM;
        uint256 expectedNet = gross - expectedFee;

        _approve(user, gross);
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit FeeCollector.FeeCollected(address(token), user, expectedFee);
        fc.bridgeToL1{value: BURN_FEE}(address(token), gross, L1_ADDR);

        // Fee stays in FeeCollector (in token)
        assertEq(token.balanceOf(address(fc)), expectedFee);
        // Bridge received net token amount
        assertEq(mockBridge.lastAmount(), expectedNet);
        assertEq(mockBridge.lastToken(), address(token));
        assertEq(mockBridge.lastKaspaAddress(), L1_ADDR);
        // Bridge received exact burnFee in iKAS
        assertEq(mockBridge.lastValue(), BURN_FEE);
        // iKAS does NOT stay in FeeCollector
        assertEq(address(fc).balance, 0);
    }

    function test_bridgeToL1_zeroFeeRate() public {
        vm.prank(owner);
        fc.setFeeRate(0);

        uint256 gross = 1_000 ether;
        _approve(user, gross);
        vm.prank(user);
        fc.bridgeToL1{value: BURN_FEE}(address(token), gross, L1_ADDR);

        assertEq(token.balanceOf(address(fc)), 0);
        assertEq(mockBridge.lastAmount(), gross);
    }

    function test_bridgeToL1_revertZeroToken() public {
        vm.prank(user);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fc.bridgeToL1{value: BURN_FEE}(address(0), 1_000 ether, L1_ADDR);
    }

    function test_bridgeToL1_revertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(FeeCollector.InsufficientValue.selector);
        fc.bridgeToL1{value: BURN_FEE}(address(token), 0, L1_ADDR);
    }

    function test_bridgeToL1_revertWrongBurnFee_tooLow() public {
        _approve(user, 1_000 ether);
        vm.prank(user);
        vm.expectRevert(FeeCollector.IncorrectBurnFee.selector);
        fc.bridgeToL1{value: BURN_FEE - 1}(address(token), 1_000 ether, L1_ADDR);
    }

    function test_bridgeToL1_revertWrongBurnFee_tooHigh() public {
        _approve(user, 1_000 ether);
        vm.prank(user);
        vm.expectRevert(FeeCollector.IncorrectBurnFee.selector);
        fc.bridgeToL1{value: BURN_FEE + 1}(address(token), 1_000 ether, L1_ADDR);
    }

    function test_bridgeToL1_revertWrongBurnFee_zero() public {
        _approve(user, 1_000 ether);
        vm.prank(user);
        vm.expectRevert(FeeCollector.IncorrectBurnFee.selector);
        fc.bridgeToL1{value: 0}(address(token), 1_000 ether, L1_ADDR);
    }

    function test_bridgeToL1_revertInvalidAddress_empty() public {
        _approve(user, 1_000 ether);
        vm.prank(user);
        vm.expectRevert(FeeCollector.InvalidAddress.selector);
        fc.bridgeToL1{value: BURN_FEE}(address(token), 1_000 ether, "");
    }

    function test_bridgeToL1_revertInvalidAddress_noPrefix() public {
        _approve(user, 1_000 ether);
        vm.prank(user);
        vm.expectRevert(FeeCollector.InvalidAddress.selector);
        fc.bridgeToL1{value: BURN_FEE}(address(token), 1_000 ether, "qypr0qj7luv26laqlq");
    }

    function test_bridgeToL1_revertInvalidAddress_tooLong() public {
        _approve(user, 1_000 ether);
        vm.prank(user);
        vm.expectRevert(FeeCollector.InvalidAddress.selector);
        fc.bridgeToL1{value: BURN_FEE}(
            address(token),
            1_000 ether,
            "kaspa:qypr0qj7luv26laqlquan9n2zu7wyen87fkdw3kx3kd69ymyw3tj4tsh467xzf222222222222222222222222222222222"
        );
    }

    function test_bridgeToL1_burnFeeChanges() public {
        // Simulate bridge operator changing burnFee
        mockBridge.setBurnFee(0.02 ether);
        vm.deal(user, 100 ether);

        uint256 gross = 1_000 ether;
        _approve(user, gross);
        vm.prank(user);
        fc.bridgeToL1{value: 0.02 ether}(address(token), gross, L1_ADDR);

        assertEq(mockBridge.lastValue(), 0.02 ether);
    }

    function testFuzz_bridgeToL1(uint256 gross) public {
        gross = bound(gross, 1 ether, 5_000 ether);
        token.mint(user, gross);
        vm.prank(user);
        token.approve(address(fc), gross);

        uint256 expectedFee = (gross * DEFAULT_FEE_RATE) / FEE_DENOM;
        uint256 expectedNet = gross - expectedFee;

        vm.prank(user);
        fc.bridgeToL1{value: BURN_FEE}(address(token), gross, L1_ADDR);

        assertEq(token.balanceOf(address(fc)), expectedFee);
        assertEq(mockBridge.lastAmount(), expectedNet);
    }

    // ─── withdraw (ERC-20) ───────────────────────────────────────────────────

    function _accumulateFee(uint256 amount) internal {
        _approve(user, amount);
        vm.prank(user);
        fc.bridgeToL1{value: BURN_FEE}(address(token), amount, L1_ADDR);
    }

    function test_withdraw_byWithdrawer() public {
        _accumulateFee(1_000 ether);
        uint256 bal = token.balanceOf(address(fc));

        vm.prank(withdrawer);
        fc.withdraw(address(token), withdrawer, bal);
        assertEq(token.balanceOf(withdrawer), bal);
        assertEq(token.balanceOf(address(fc)), 0);
    }

    function test_withdraw_byOwner() public {
        _accumulateFee(1_000 ether);
        uint256 bal = token.balanceOf(address(fc));

        vm.prank(owner);
        fc.withdraw(address(token), owner, bal);
        assertEq(token.balanceOf(owner), bal);
    }

    function test_withdraw_revertNotWithdrawer() public {
        _accumulateFee(1_000 ether);
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotWithdrawer.selector);
        fc.withdraw(address(token), stranger, 1 ether);
    }

    function test_withdraw_revertInsufficientBalance() public {
        vm.prank(withdrawer);
        vm.expectRevert(FeeCollector.InsufficientBalance.selector);
        fc.withdraw(address(token), withdrawer, 1 ether);
    }

    function test_withdrawAll() public {
        _accumulateFee(1_000 ether);
        uint256 bal = token.balanceOf(address(fc));

        vm.prank(withdrawer);
        fc.withdrawAll(address(token), withdrawer);
        assertEq(token.balanceOf(withdrawer), bal);
        assertEq(token.balanceOf(address(fc)), 0);
    }

    function test_withdrawAll_revertEmpty() public {
        vm.prank(withdrawer);
        vm.expectRevert(FeeCollector.InsufficientBalance.selector);
        fc.withdrawAll(address(token), withdrawer);
    }

    // ─── withdrawNative ───────────────────────────────────────────────────────

    function test_withdrawNative() public {
        vm.deal(address(fc), 1 ether);
        vm.prank(withdrawer);
        fc.withdrawNative(payable(withdrawer), 1 ether);
        assertEq(withdrawer.balance, 1 ether);
        assertEq(address(fc).balance, 0);
    }

    function test_withdrawAllNative() public {
        vm.deal(address(fc), 2 ether);
        vm.prank(withdrawer);
        fc.withdrawAllNative(payable(withdrawer));
        assertEq(withdrawer.balance, 2 ether);
    }

    function test_withdrawNative_revertNotWithdrawer() public {
        vm.deal(address(fc), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotWithdrawer.selector);
        fc.withdrawNative(payable(stranger), 1 ether);
    }

    function test_receive_nativeToken() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(fc).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(fc).balance, 1 ether);
    }
}
