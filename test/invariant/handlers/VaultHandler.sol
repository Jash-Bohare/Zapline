// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LPVault} from "src/LPVault.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract VaultHandler is Test {
    using SafeERC20 for IERC20;

    LPVault public immutable vault;
    TwapOracle public immutable oracle;
    IUniswapV2Router02 public immutable router;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    address public immutable pair;

    address[] public actors;
    uint256 public ghostDeposited;
    uint256 public ghostRedeemed;
    mapping(address => uint256) public ghostActorShares;

    constructor(address _vault, address _oracle, address _router, address _usdc, address _weth, address _pair) {
        vault = LPVault(_vault);
        oracle = TwapOracle(_oracle);
        router = IUniswapV2Router02(_router);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        pair = _pair;

        actors.push(makeAddr("inv.actor1"));
        actors.push(makeAddr("inv.actor2"));
        actors.push(makeAddr("inv.actor3"));
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 10 * 1e6, 5_000 * 1e6); // 10 to 5,000 USDC

        deal(address(usdc), actor, amount);
        vm.startPrank(actor);
        usdc.forceApprove(address(vault), amount);
        uint256 shares = vault.deposit(amount, actor);
        vm.stopPrank();

        ghostDeposited += amount;
        ghostActorShares[actor] += shares;
    }

    function redeem(uint256 actorSeed, uint256 fractionBps) external {
        address actor = actors[actorSeed % actors.length];
        uint256 actorShares = vault.balanceOf(actor);
        if (actorShares == 0) return;

        fractionBps = bound(fractionBps, 1, 10000);
        uint256 sharesToRedeem = (actorShares * fractionBps) / 10000;
        if (sharesToRedeem == 0) return;

        vm.startPrank(actor);
        uint256 assetsOut = vault.redeem(sharesToRedeem, actor, actor);
        vm.stopPrank();

        ghostRedeemed += assetsOut;
        ghostActorShares[actor] -= sharesToRedeem;
    }

    function poolSwap(bool direction, uint256 rawAmount) external {
        address swapper = makeAddr("inv.swapper");
        if (direction) {
            uint256 usdcAmt = bound(rawAmount, 10_000 * 1e6, 200_000 * 1e6);
            deal(address(usdc), swapper, usdcAmt);
            vm.startPrank(swapper);
            usdc.forceApprove(address(router), usdcAmt);
            address[] memory path = new address[](2);
            path[0] = address(usdc);
            path[1] = address(weth);
            router.swapExactTokensForTokens(usdcAmt, 0, path, swapper, block.timestamp);
            vm.stopPrank();
        } else {
            uint256 wethAmt = bound(rawAmount, 5 ether, 50 ether);
            deal(address(weth), swapper, wethAmt);
            vm.startPrank(swapper);
            weth.forceApprove(address(router), wethAmt);
            address[] memory path = new address[](2);
            path[0] = address(weth);
            path[1] = address(usdc);
            router.swapExactTokensForTokens(wethAmt, 0, path, swapper, block.timestamp);
            vm.stopPrank();
        }
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 600, 3600); // 10 min to 1 hour
        vm.warp(block.timestamp + secs);
        oracle.update(pair);
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}
