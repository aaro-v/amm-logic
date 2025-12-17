// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {UniswapV2Factory} from "contracts/Factory.sol";
import {UniswapV2Pair} from "contracts/Pair.sol";
import {MockERC20} from "contracts/MockERC20.sol";
import {TWAPConsumer} from "contracts/TWAPConsumer.sol";

contract TWAPConsumerTest is Test {
    UniswapV2Factory factory;
    UniswapV2Pair pair;
    MockERC20 token0;
    MockERC20 token1;
    TWAPConsumer consumer;

    address attacker = address(0xBADA55);

    function setUp() public {
        token0 = new MockERC20("Token0", "T0", 1_000_000 ether);
        token1 = new MockERC20("Token1", "T1", 1_000_000 ether);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        factory = new UniswapV2Factory(address(this));
        address pairAddress = factory.createPair(address(token0), address(token1));
        pair = UniswapV2Pair(pairAddress);

        // Seed the pool
        token0.transfer(address(pair), 10_000 ether);
        token1.transfer(address(pair), 10_000 ether);
        pair.mint(address(this));

        // Advance time slightly so price cumulatives begin accruing
        vm.warp(block.timestamp + 1);
        pair.sync();

        consumer = new TWAPConsumer();
        consumer.recordObservation(pairAddress);

        token0.approve(address(consumer), type(uint256).max);
        token1.approve(address(consumer), type(uint256).max);
    }

    function testExecuteLimitOrderSucceedsAfterWindow() public {
        vm.warp(block.timestamp + 3605);
        pair.sync();

        uint256 before = token1.balanceOf(address(this));
        consumer.executeLimitOrder(address(pair), 10 ether, 0, 3600, true);
        uint256 afterBal = token1.balanceOf(address(this));

        assertGt(afterBal, before, "Should receive tokens when TWAP window satisfied");
    }

    function testTwapBlocksFlashAttack() public {
        vm.warp(block.timestamp + 5);

        // Attacker manipulates the pool using a large swap
        token0.transfer(attacker, 1_000 ether);
        token1.transfer(attacker, 1_000 ether);
        vm.startPrank(attacker);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 amountIn = 500 ether;
        token0.transfer(address(pair), amountIn);
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * uint256(reserve1);
        uint256 denominator = uint256(reserve0) * 1000 + amountInWithFee;
        uint256 amountOut = numerator / denominator;

        pair.swap(0, amountOut, attacker, "");
        vm.stopPrank();

        assertGt(token1.balanceOf(attacker), 1_000 ether, "Attacker benefited from manipulation");

        vm.expectRevert("TWAP: INSUFFICIENT_WINDOW");
        consumer.executeLimitOrder(address(pair), 10 ether, 0, 3_600, true);
    }
}
