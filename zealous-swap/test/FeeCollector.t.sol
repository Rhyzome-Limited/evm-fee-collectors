// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {FeeCollector, IZealousSwapRouter} from "../src/FeeCollector.sol";

// ─── Minimal ERC-20 mock ──────────────────────────────────────────────────────
contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ─── Mock Router ─────────────────────────────────────────────────────────────
/// Simulates Zealous Swap Router: simply sends `amountOutMin` of tokenOut to `to`.
contract MockRouter {
    address public wkas;

    constructor(address _wkas) {
        wkas = _wkas;
    }

    function WKAS() external view returns (address) {
        return wkas;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256, /* amountOutMin */
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        // Consume tokenIn from caller
        MockToken(path[0]).transferFrom(msg.sender, address(this), amountIn);
        // Send tokenOut 1:1 for simplicity
        MockToken(path[path.length - 1]).transfer(to, amountIn);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }

    function swapExactTokensForKAS(
        uint256 amountIn,
        uint256, /* amountOutMin */
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        MockToken(path[0]).transferFrom(msg.sender, address(this), amountIn);
        payable(to).transfer(amountIn); // 1:1 KAS out
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }

    function swapExactKASForTokens(
        uint256, /* amountOutMin */
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external payable returns (uint256[] memory amounts) {
        MockToken(path[path.length - 1]).transfer(to, msg.value); // 1:1
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata, bool)
        external
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }

    receive() external payable {}
}

// ─── Tests ────────────────────────────────────────────────────────────────────
contract FeeCollectorTest is Test {
    FeeCollector public fc;
    MockToken public tokenIn;
    MockToken public tokenOut;
    MockRouter public mockRouter;

    address owner = makeAddr("owner");
    address withdrawer = makeAddr("withdrawer");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address stranger = makeAddr("stranger");

    uint256 constant DEFAULT_FEE_RATE = 75; // 0.75%
    uint256 constant FEE_DENOM = 10_000;

    function setUp() public {
        tokenIn = new MockToken("Token In", "TIN", 18);
        tokenOut = new MockToken("Token Out", "TOUT", 18);
        mockRouter = new MockRouter(address(tokenOut)); // WKAS = tokenOut for tests

        vm.prank(owner);
        fc = new FeeCollector(owner, withdrawer, DEFAULT_FEE_RATE, address(mockRouter));

        // Give the mock router some tokenOut to pay swappers
        tokenOut.mint(address(mockRouter), 1_000_000e18);
        // Fund router with KAS for KAS-out swaps
        vm.deal(address(mockRouter), 1_000 ether);
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(fc.owner(), owner);
        assertEq(fc.withdrawer(), withdrawer);
        assertEq(fc.feeRate(), DEFAULT_FEE_RATE);
        assertEq(address(fc.router()), address(mockRouter));
    }

    function test_constructor_revertZeroOwner() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(address(0), withdrawer, DEFAULT_FEE_RATE, address(mockRouter));
    }

    function test_constructor_revertZeroWithdrawer() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(owner, address(0), DEFAULT_FEE_RATE, address(mockRouter));
    }

    function test_constructor_revertZeroRouter() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(owner, withdrawer, DEFAULT_FEE_RATE, address(0));
    }

    function test_constructor_revertFeeRateTooHigh() public {
        vm.expectRevert(FeeCollector.FeeRateTooHigh.selector);
        new FeeCollector(owner, withdrawer, 1_001, address(mockRouter));
    }

    // ─── setOwner ─────────────────────────────────────────────────────────────

    function test_setOwner() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        fc.setOwner(newOwner);
        assertEq(fc.owner(), newOwner);
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
        uint256 amount = 1_000e18;
        (uint256 fee, uint256 net) = fc.calculateFee(amount);
        assertEq(fee, (amount * DEFAULT_FEE_RATE) / FEE_DENOM);
        assertEq(net, amount - fee);
    }

    function testFuzz_calculateFee(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);
        (uint256 fee, uint256 net) = fc.calculateFee(amount);
        assertEq(fee + net, amount);
    }

    // ─── swapExactTokensForTokens ─────────────────────────────────────────────

    function _mintAndApprove(address token, address from, uint256 amount) internal {
        MockToken(token).mint(from, amount);
        vm.prank(from);
        MockToken(token).approve(address(fc), amount);
    }

    function test_swapExactTokensForTokens() public {
        uint256 amountIn = 1_000e18;
        _mintAndApprove(address(tokenIn), user, amountIn);

        uint256 expectedFee = (amountIn * DEFAULT_FEE_RATE) / FEE_DENOM;
        uint256 expectedNet = amountIn - expectedFee;

        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit FeeCollector.FeeCollected(address(tokenIn), user, expectedFee);
        fc.swapExactTokensForTokens(amountIn, 0, path, recipient, block.timestamp);

        // Fee stays in FeeCollector
        assertEq(tokenIn.balanceOf(address(fc)), expectedFee);
        // Recipient gets net output
        assertEq(tokenOut.balanceOf(recipient), expectedNet);
    }

    function test_swapExactTokensForTokens_revertInvalidPath() public {
        address[] memory path = new address[](1);
        path[0] = address(tokenIn);
        vm.prank(user);
        vm.expectRevert(FeeCollector.InvalidPath.selector);
        fc.swapExactTokensForTokens(1e18, 0, path, recipient, block.timestamp);
    }

    function testFuzz_swapExactTokensForTokens(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 1_000_000e18);
        _mintAndApprove(address(tokenIn), user, amountIn);

        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);

        uint256 expectedFee = (amountIn * DEFAULT_FEE_RATE) / FEE_DENOM;

        vm.prank(user);
        fc.swapExactTokensForTokens(amountIn, 0, path, recipient, block.timestamp);

        assertEq(tokenIn.balanceOf(address(fc)), expectedFee);
    }

    // ─── swapExactTokensForKAS ────────────────────────────────────────────────

    function test_swapExactTokensForKAS() public {
        uint256 amountIn = 500e18;
        _mintAndApprove(address(tokenIn), user, amountIn);

        uint256 expectedFee = (amountIn * DEFAULT_FEE_RATE) / FEE_DENOM;
        uint256 expectedNet = amountIn - expectedFee;

        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut); // tokenOut acts as WKAS in mock

        vm.prank(user);
        fc.swapExactTokensForKAS(amountIn, 0, path, recipient, block.timestamp);

        assertEq(tokenIn.balanceOf(address(fc)), expectedFee);
        assertEq(recipient.balance, expectedNet); // mock pays KAS 1:1
    }

    // ─── swapExactKASForTokens ────────────────────────────────────────────────

    function test_swapExactKASForTokens() public {
        uint256 kasIn = 10 ether;
        vm.deal(user, kasIn);

        uint256 expectedFee = (kasIn * DEFAULT_FEE_RATE) / FEE_DENOM;
        uint256 netValue = kasIn - expectedFee;

        address[] memory path = new address[](2);
        path[0] = address(tokenOut); // WKAS
        path[1] = address(tokenOut);

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit FeeCollector.FeeCollected(address(0), user, expectedFee);
        fc.swapExactKASForTokens{value: kasIn}(0, path, recipient, block.timestamp);

        // KAS fee stays in FeeCollector
        assertEq(address(fc).balance, expectedFee);
        // Router received net KAS and sent tokenOut to recipient
        assertEq(tokenOut.balanceOf(recipient), netValue);
    }

    // ─── getAmountsOut ────────────────────────────────────────────────────────

    function test_getAmountsOut_deductsFee() public view {
        uint256 amountIn = 1_000e18;
        uint256 expectedNet = amountIn - (amountIn * DEFAULT_FEE_RATE) / FEE_DENOM;

        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);

        uint256[] memory amounts = fc.getAmountsOut(amountIn, path, false);
        // Mock router returns 1:1, so amounts[0] == netAmountIn
        assertEq(amounts[0], expectedNet);
    }

    // ─── withdraw ─────────────────────────────────────────────────────────────

    function _doSwapToAccumulateFee(uint256 amount) internal {
        _mintAndApprove(address(tokenIn), user, amount);
        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);
        vm.prank(user);
        fc.swapExactTokensForTokens(amount, 0, path, recipient, block.timestamp);
    }

    function test_withdraw_byWithdrawer() public {
        _doSwapToAccumulateFee(1_000e18);
        uint256 bal = tokenIn.balanceOf(address(fc));

        vm.prank(withdrawer);
        fc.withdraw(address(tokenIn), withdrawer, bal);
        assertEq(tokenIn.balanceOf(withdrawer), bal);
        assertEq(tokenIn.balanceOf(address(fc)), 0);
    }

    function test_withdraw_byOwner() public {
        _doSwapToAccumulateFee(1_000e18);
        uint256 bal = tokenIn.balanceOf(address(fc));
        vm.prank(owner);
        fc.withdraw(address(tokenIn), owner, bal);
        assertEq(tokenIn.balanceOf(owner), bal);
    }

    function test_withdraw_revertNotWithdrawer() public {
        _doSwapToAccumulateFee(1_000e18);
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotWithdrawer.selector);
        fc.withdraw(address(tokenIn), stranger, 1);
    }

    function test_withdrawAll() public {
        _doSwapToAccumulateFee(2_000e18);
        uint256 bal = tokenIn.balanceOf(address(fc));
        vm.prank(withdrawer);
        fc.withdrawAll(address(tokenIn), withdrawer);
        assertEq(tokenIn.balanceOf(withdrawer), bal);
    }

    function test_withdrawNative() public {
        vm.deal(address(fc), 5 ether);
        vm.prank(withdrawer);
        fc.withdrawNative(payable(withdrawer), 2 ether);
        assertEq(address(fc).balance, 3 ether);
        assertEq(withdrawer.balance, 2 ether);
    }

    function test_withdrawNative_revertInsufficientBalance() public {
        vm.deal(address(fc), 1 ether);
        vm.prank(withdrawer);
        vm.expectRevert(FeeCollector.InsufficientBalance.selector);
        fc.withdrawNative(payable(withdrawer), 2 ether);
    }

    function test_receive_nativeToken() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(fc).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(fc).balance, 1 ether);
    }
}
