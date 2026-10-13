// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {SwapExecutor} from "src/SwapExecutor.sol";
import {V2Library} from "src/libraries/V2Library.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";

contract SwapExecutorTest is ForkBase {
    using SafeERC20 for IERC20;
    SwapExecutor internal executor;

    function setUp() public override {
        super.setUp();
        executor = new SwapExecutor(address(router));
        vm.deal(address(executor), 0);
    }

    /// @notice SW-T01: exact-in USDC -> WETH
    function test_SWT01_ExactInUsdcToWeth() public {
        uint256 amountIn = 1_000 * 1e6; // 1,000 USDC
        fund(alice, usdc, amountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        uint256[] memory quotes = router.getAmountsOut(amountIn, path);
        uint256 expectedOut = quotes[1];
        uint256 minOut = (expectedOut * 995) / 1000; // 0.5% slippage

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(executor), amountIn);
        uint256[] memory amounts = executor.swapExactIn(path, amountIn, minOut, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amounts[0], amountIn);
        assertGe(amounts[1], minOut);
        assertEq(amounts[1], expectedOut);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - amountIn);
        assertEq(weth.balanceOf(alice), aliceWethBefore + expectedOut);

        // Invariant I-SW-1: Executor holds 0 tokens
        assertEq(usdc.balanceOf(address(executor)), 0);
        assertEq(weth.balanceOf(address(executor)), 0);
        assertEq(address(executor).balance, 0);
    }

    /// @notice SW-T02: exact-in output equals quoteExactIn
    function test_SWT02_ExactInMatchesQuote() public {
        uint256 amountIn = 5_000 * 1e6;
        fund(alice, usdc, amountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        uint256[] memory quotes = executor.quoteExactIn(path, amountIn);

        vm.startPrank(alice);
        usdc.approve(address(executor), amountIn);
        uint256[] memory amounts = executor.swapExactIn(path, amountIn, quotes[1], alice, block.timestamp);
        vm.stopPrank();

        assertEq(amounts[1], quotes[1]);
    }

    /// @notice SW-T03: exact-out WETH -> USDC with unused input refunded
    function test_SWT03_ExactOutWethToUsdcRefund() public {
        uint256 amountOut = 2_000 * 1e6; // 2,000 USDC

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(usdc);

        uint256[] memory quotes = router.getAmountsIn(amountOut, path);
        uint256 requiredIn = quotes[0];
        uint256 maxIn = (requiredIn * 105) / 100; // 5% extra provided

        fund(alice, weth, maxIn);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        weth.approve(address(executor), maxIn);
        uint256[] memory amounts = executor.swapExactOut(path, amountOut, maxIn, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amounts[0], requiredIn);
        assertEq(amounts[1], amountOut);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + amountOut);
        assertEq(weth.balanceOf(alice), aliceWethBefore - requiredIn, "Unused WETH must be refunded");

        assertEq(weth.balanceOf(address(executor)), 0);
        assertEq(usdc.balanceOf(address(executor)), 0);
    }

    /// @notice SW-T04: multi-hop USDC -> DAI -> WETH leaves zero balance in executor
    function test_SWT04_MultiHopUsdcDaiWeth() public {
        uint256 amountIn = 10_000 * 1e6;
        fund(alice, usdc, amountIn);

        address[] memory path = new address[](3);
        path[0] = address(usdc);
        path[1] = address(dai);
        path[2] = address(weth);

        vm.startPrank(alice);
        usdc.approve(address(executor), amountIn);
        uint256[] memory amounts = executor.swapExactIn(path, amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(amounts[2], 0);
        assertEq(usdc.balanceOf(address(executor)), 0);
        assertEq(dai.balanceOf(address(executor)), 0);
        assertEq(weth.balanceOf(address(executor)), 0);
    }

    /// @notice SW-T05: ETH -> USDC and USDC -> ETH
    function test_SWT05_EthVariants() public {
        // ETH -> USDC
        uint256 ethIn = 1 ether;
        vm.deal(alice, ethIn);

        address[] memory pathIn = new address[](2);
        pathIn[0] = address(weth);
        pathIn[1] = address(usdc);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        uint256[] memory amountsIn = executor.swapExactETHIn{value: ethIn}(pathIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(amountsIn[1], 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + amountsIn[1]);
        assertEq(address(executor).balance, 0);

        // USDC -> ETH
        uint256 usdcIn = 1_000 * 1e6;
        fund(bob, usdc, usdcIn);

        address[] memory pathOut = new address[](2);
        pathOut[0] = address(usdc);
        pathOut[1] = address(weth);

        uint256 bobEthBefore = bob.balance;
        vm.startPrank(bob);
        usdc.approve(address(executor), usdcIn);
        uint256[] memory amountsOut = executor.swapExactInForETH(pathOut, usdcIn, 0, bob, block.timestamp);
        vm.stopPrank();

        assertGt(amountsOut[1], 0);
        assertEq(bob.balance, bobEthBefore + amountsOut[1]);
        assertEq(address(executor).balance, 0);
        assertEq(usdc.balanceOf(address(executor)), 0);
    }

    /// @notice SW-T06: USDT as input token works with SafeERC20 forceApprove
    function test_SWT06_UsdtInputToken() public {
        uint256 amountIn = 1_000 * 1e6;
        fund(alice, usdt, amountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(weth);

        vm.startPrank(alice);
        usdt.forceApprove(address(executor), amountIn);
        uint256[] memory amounts = executor.swapExactIn(path, amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(amounts[1], 0);
        assertEq(usdt.balanceOf(address(executor)), 0);
    }

    /// @notice SW-T07: Expired deadline reverts
    function test_SWT07_ExpiredDeadlineReverts() public {
        fund(alice, usdc, 1_000 * 1e6);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        vm.startPrank(alice);
        usdc.approve(address(executor), 1_000 * 1e6);
        vm.expectRevert(SwapExecutor.DeadlineExpired.selector);
        executor.swapExactIn(path, 1_000 * 1e6, 0, alice, block.timestamp - 1);
        vm.stopPrank();
    }

    /// @notice SW-T08: minOut too high reverts SlippageExceeded or Router slippage
    function test_SWT08_MinOutTooHighReverts() public {
        fund(alice, usdc, 1_000 * 1e6);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        uint256 quote = router.getAmountsOut(1_000 * 1e6, path)[1];

        vm.startPrank(alice);
        usdc.approve(address(executor), 1_000 * 1e6);
        vm.expectRevert();
        executor.swapExactIn(path, 1_000 * 1e6, quote + 1 ether, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @notice SW-T09: maxIn too low on exact-out reverts
    function test_SWT09_MaxInTooLowReverts() public {
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(usdc);

        uint256 quote = router.getAmountsIn(1_000 * 1e6, path)[0];
        fund(alice, weth, quote);

        vm.startPrank(alice);
        weth.approve(address(executor), quote);
        vm.expectRevert();
        executor.swapExactOut(path, 1_000 * 1e6, quote / 2, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @notice SW-T10: Invalid paths (length < 2, duplicate adjacent, zero address, nonexistent pair)
    function test_SWT10_InvalidPathsRevert() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(executor), 1_000 * 1e6);

        // Path length 1
        address[] memory path1 = new address[](1);
        path1[0] = address(usdc);
        vm.expectRevert(SwapExecutor.InvalidPath.selector);
        executor.swapExactIn(path1, 1_000 * 1e6, 0, alice, block.timestamp);

        // Adjacent duplicates
        address[] memory path2 = new address[](2);
        path2[0] = address(usdc);
        path2[1] = address(usdc);
        vm.expectRevert(SwapExecutor.InvalidPath.selector);
        executor.swapExactIn(path2, 1_000 * 1e6, 0, alice, block.timestamp);

        // Zero address
        address[] memory path3 = new address[](2);
        path3[0] = address(usdc);
        path3[1] = address(0);
        vm.expectRevert(SwapExecutor.InvalidPath.selector);
        executor.swapExactIn(path3, 1_000 * 1e6, 0, alice, block.timestamp);

        // Non-existent pair
        address[] memory path4 = new address[](2);
        path4[0] = address(usdc);
        path4[1] = makeAddr("fakeToken");
        vm.expectRevert(SwapExecutor.PairNotFound.selector);
        executor.swapExactIn(path4, 1_000 * 1e6, 0, alice, block.timestamp);

        vm.stopPrank();
    }

    /// @notice SW-T11: Pause and unpause
    function test_SWT11_PauseUnpause() public {
        fund(alice, usdc, 1_000 * 1e6);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        executor.pause();

        vm.startPrank(alice);
        usdc.approve(address(executor), 1_000 * 1e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.swapExactIn(path, 1_000 * 1e6, 0, alice, block.timestamp);
        vm.stopPrank();

        executor.unpause();

        vm.startPrank(alice);
        uint256[] memory amounts = executor.swapExactIn(path, 1_000 * 1e6, 0, alice, block.timestamp);
        vm.stopPrank();
        assertGt(amounts[1], 0);
    }

    /// @notice SW-T12: Direct ETH sent to executor reverts UnexpectedETH
    function test_SWT12_DirectEthReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(executor).call{value: 1 ether}("");
        assertFalse(ok, "Direct ETH send must revert");
    }

    /// @notice SW-T13: Rescue functions access control
    function test_SWT13_RescueAccessControl() public {
        fund(address(executor), usdc, 500 * 1e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        executor.rescueToken(address(usdc), alice, 500 * 1e6);

        executor.rescueToken(address(usdc), owner, 500 * 1e6);
        assertEq(usdc.balanceOf(owner), 500 * 1e6);
    }

    /// @notice SW-T14: Router allowance is reset to zero after call
    function test_SWT14_AllowanceResetZero() public {
        uint256 amountIn = 1_000 * 1e6;
        fund(alice, usdc, amountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        vm.startPrank(alice);
        usdc.approve(address(executor), amountIn);
        executor.swapExactIn(path, amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertEq(usdc.allowance(address(executor), address(router)), 0, "Router allowance must be 0");
    }

    /// @notice SW-F01: Fuzz swapExactIn with amounts 1 to 1M USDC
    function testFuzz_SWF01_ExactInAmount(uint256 amountIn) public {
        amountIn = bound(amountIn, 1 * 1e6, 1_000_000 * 1e6);
        fund(alice, usdc, amountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        vm.startPrank(alice);
        usdc.approve(address(executor), amountIn);
        uint256[] memory amounts = executor.swapExactIn(path, amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(amounts[1], 0);
        assertEq(usdc.balanceOf(address(executor)), 0);
        assertEq(weth.balanceOf(address(executor)), 0);
    }

    /// @notice SW-F02: Fuzz swapExactOut with different amounts and verify refund
    function testFuzz_SWF02_ExactOutRefund(uint256 amountOut) public {
        amountOut = bound(amountOut, 100 * 1e6, 100_000 * 1e6);

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(usdc);

        uint256 quote = router.getAmountsIn(amountOut, path)[0];
        uint256 maxIn = (quote * 110) / 100; // 10% buffer
        fund(alice, weth, maxIn);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        vm.startPrank(alice);
        weth.approve(address(executor), maxIn);
        uint256[] memory amounts = executor.swapExactOut(path, amountOut, maxIn, alice, block.timestamp);
        vm.stopPrank();

        assertEq(amounts[0], quote);
        assertEq(amounts[1], amountOut);
        assertEq(weth.balanceOf(alice), aliceWethBefore - quote);
        assertEq(weth.balanceOf(address(executor)), 0);
    }

    /// @notice SW-F03: Fuzz vs V2Library.getAmountOut
    function testFuzz_SWF03_V2LibraryParity(uint256 amountIn) public {
        amountIn = bound(amountIn, 10 * 1e6, 500_000 * 1e6);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        (uint256 rIn, uint256 rOut,) = V2Library.getReservesSorted(address(factory), address(usdc), address(weth));
        uint256 libOut = V2Library.getAmountOut(amountIn, rIn, rOut);
        uint256 routerOut = router.getAmountsOut(amountIn, path)[1];

        assertEq(libOut, routerOut, "V2Library.getAmountOut must equal Router.getAmountsOut");
    }
}
