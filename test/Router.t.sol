// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {UniswapV2Factory} from "contracts/Factory.sol";
import {UniswapV2Pair} from "contracts/Pair.sol";
import {MockERC20} from "contracts/MockERC20.sol";
import {Router} from "contracts/Router.sol";
import {WETH9} from "contracts/WETH9.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RouterTest is Test {
    UniswapV2Factory factory;
    Router router;
    WETH9 weth;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;

    address alice = address(0xA11CE);

    function setUp() public {
        factory = new UniswapV2Factory(address(this));
        weth = new WETH9();
        router = new Router(address(factory), address(weth));

        tokenA = new MockERC20("TokenA", "A", 1_000_000 ether);
        tokenB = new MockERC20("TokenB", "B", 1_000_000 ether);
        tokenC = new MockERC20("TokenC", "C", 1_000_000 ether);

        tokenA.transfer(alice, 10_000 ether);
        tokenB.transfer(alice, 10_000 ether);
        tokenC.transfer(alice, 10_000 ether);

        vm.deal(alice, 100 ether);
    }

    function testAddAndRemoveLiquidityTokens() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        uint256 deadline = block.timestamp + 1;
        (,, uint256 liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            100 ether,
            100 ether,
            0,
            0,
            alice,
            deadline
        );
        assertGt(liquidity, 0);

        address pairAddress = factory.getPair(address(tokenA), address(tokenB));
        assertTrue(pairAddress != address(0));

        IERC20(pairAddress).approve(address(router), liquidity);
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            address(tokenA),
            address(tokenB),
            liquidity,
            0,
            0,
            alice,
            deadline
        );

        assertGt(amountA, 0);
        assertGt(amountB, 0);
        vm.stopPrank();
    }

    function testSwapExactTokensForTokensSingleHop() public {
        // Seed A/B pool
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        uint256 deadline = block.timestamp + 1;
        router.addLiquidity(address(tokenA), address(tokenB), 1_000 ether, 1_000 ether, 0, 0, alice, deadline);

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 balBefore = tokenB.balanceOf(alice);
        router.swapExactTokensForTokens(10 ether, 0, path, alice, deadline);
        uint256 balAfter = tokenB.balanceOf(alice);

        assertGt(balAfter, balBefore);
        vm.stopPrank();
    }

    function testSwapExactTokensForTokensMultiHop() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);

        uint256 deadline = block.timestamp + 1;
        // Seed A/B and B/C
        router.addLiquidity(address(tokenA), address(tokenB), 1_000 ether, 1_000 ether, 0, 0, alice, deadline);
        router.addLiquidity(address(tokenB), address(tokenC), 1_000 ether, 1_000 ether, 0, 0, alice, deadline);

        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 balBefore = tokenC.balanceOf(alice);
        router.swapExactTokensForTokens(10 ether, 0, path, alice, deadline);
        uint256 balAfter = tokenC.balanceOf(alice);

        assertGt(balAfter, balBefore);
        vm.stopPrank();
    }

    function testAddLiquidityETHAndSwapEthToTokens() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);

        uint256 deadline = block.timestamp + 1;
        router.addLiquidityETH{value: 10 ether}(
            address(tokenA),
            10 ether,
            0,
            0,
            alice,
            deadline
        );

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(tokenA);

        uint256 balBefore = tokenA.balanceOf(alice);
        router.swapExactETHForTokens{value: 1 ether}(0, path, alice, deadline);
        uint256 balAfter = tokenA.balanceOf(alice);
        assertGt(balAfter, balBefore);
        vm.stopPrank();
    }

    function testSwapTokensForETH() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);

        uint256 deadline = block.timestamp + 1;
        // Seed tokenA/WETH pool
        router.addLiquidityETH{value: 10 ether}(
            address(tokenA),
            10 ether,
            0,
            0,
            alice,
            deadline
        );

        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(weth);

        uint256 ethBefore = alice.balance;
        router.swapExactTokensForETH(1 ether, 0, path, alice, deadline);
        uint256 ethAfter = alice.balance;
        assertGt(ethAfter, ethBefore);
        vm.stopPrank();
    }

    function testDeadlineReverts() public {
        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        vm.expectRevert(Router.Expired.selector);
        router.addLiquidity(address(tokenA), address(tokenB), 1 ether, 1 ether, 0, 0, alice, block.timestamp - 1);
        vm.stopPrank();
    }
}
