// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {UniswapV2Factory} from "contracts/Factory.sol";
import {UniswapV2Pair} from "contracts/Pair.sol";
import {MockERC20} from "contracts/MockERC20.sol";

contract AMMTest is Test {
    UniswapV2Factory factory;
    UniswapV2Pair pair;
    MockERC20 token0;
    MockERC20 token1;

    address owner;
    address alice;
    address bob;

    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 constant LIQUIDITY_AMOUNT0 = 100 ether;
    uint256 constant LIQUIDITY_AMOUNT1 = 50 ether;

    function setUp() public {
        owner = address(this);
        alice = address(0xA11CE);
        bob = address(0xB0B);

        token0 = new MockERC20("Token0", "T0", INITIAL_SUPPLY);
        token1 = new MockERC20("Token1", "T1", INITIAL_SUPPLY);

        // Ensure canonical ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        factory = new UniswapV2Factory(owner);

        // Distribute tokens
        token0.transfer(alice, 10_000 ether);
        token1.transfer(alice, 10_000 ether);
        token0.transfer(bob, 10_000 ether);
        token1.transfer(bob, 10_000 ether);

        // Create pair for subsequent tests
        address pairAddr = factory.createPair(address(token0), address(token1));
        pair = UniswapV2Pair(pairAddr);
    }

    // Pair Creation
    function testCreatePairCanonical() public {
        address addr = factory.getPair(address(token0), address(token1));
        assertTrue(addr != address(0));
        address addr2 = factory.getPair(address(token1), address(token0));
        assertEq(addr2, addr);
    }

    function testCreatePairExistsReverts() public {
        vm.expectRevert(bytes("PAIR_EXISTS"));
        factory.createPair(address(token0), address(token1));
    }

    function testCreatePairIdenticalReverts() public {
        vm.expectRevert(bytes("IDENTICAL_ADDRESSES"));
        factory.createPair(address(token0), address(token0));
    }

    function testCreatePairZeroAddressReverts() public {
        vm.expectRevert(bytes("ZERO_ADDRESS"));
        factory.createPair(address(token0), address(0));
    }

    // Liquidity Provision
    function testMintLiquidity() public {
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        uint256 aliceLp = pair.balanceOf(alice);
        assertGt(aliceLp, 0);
    }

    function testInvariantAfterMint() public {
        // First mint
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 k = uint256(reserve0) * uint256(reserve1);
        assertGt(k, 0);
    }

    function testSecondProviderAddsLiquidity() public {
        // First mint
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 bobAmount0 = 50 ether;
        uint256 bobAmount1 = uint256(bobAmount0) * uint256(r1) / uint256(r0);

        vm.startPrank(bob);
        token0.transfer(address(pair), bobAmount0);
        token1.transfer(address(pair), bobAmount1);
        pair.mint(bob);
        vm.stopPrank();

        uint256 bobLp = pair.balanceOf(bob);
        assertGt(bobLp, 0);
    }

    // Swap Mechanics
    function testSwapToken0ForToken1() public {
        // Seed liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        uint256 swapAmount = 10 ether;
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        uint256 amountInWithFee = swapAmount * 997;
        uint256 numerator = amountInWithFee * uint256(reserve1);
        uint256 denominator = uint256(reserve0) * 1000 + amountInWithFee;
        uint256 expectedOut = numerator / denominator;

        vm.startPrank(bob);
        uint256 beforeBal = token1.balanceOf(bob);
        token0.transfer(address(pair), swapAmount);
        pair.swap(0, expectedOut, bob, "");
        uint256 afterBal = token1.balanceOf(bob);
        vm.stopPrank();

        assertGt(afterBal, beforeBal);
        assertGe(afterBal - beforeBal, expectedOut - 1); // rounding tolerance
    }

    function testInvariantAfterSwap() public {
        // Seed liquidity and do a swap
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        vm.startPrank(bob);
        token0.transfer(address(pair), 10 ether);
        pair.swap(0, 1 ether, bob, "");
        vm.stopPrank();

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 k = uint256(reserve0) * uint256(reserve1);
        assertGt(k, 0);
    }

    function testSwapInvariantBrokenReverts() public {
        // Seed liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        // Try to drain pool: send some token0 then ask for nearly all token1
        vm.startPrank(alice);
        token0.transfer(address(pair), 1000 ether);
        vm.expectRevert(bytes("INVARIANT_BROKEN"));
        pair.swap(0, uint256(reserve1) - 1, alice, "");
        vm.stopPrank();
    }

    // Liquidity Withdrawal
    function testBurnLiquidityTokens() public {
        // Seed liquidity for Alice
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        uint256 aliceLpBefore = pair.balanceOf(alice);
        uint256 token0Before = token0.balanceOf(alice);
        uint256 token1Before = token1.balanceOf(alice);

        uint256 burnAmount = aliceLpBefore / 2;
        vm.startPrank(alice);
        pair.transfer(address(pair), burnAmount);
        pair.burn(alice);
        vm.stopPrank();

        uint256 token0After = token0.balanceOf(alice);
        uint256 token1After = token1.balanceOf(alice);
        assertGt(token0After, token0Before);
        assertGt(token1After, token1Before);
    }

    function testMintThenBurnReversible() public {
        // Seed base liquidity so ratios exist
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 initialK = uint256(r0) * uint256(r1);
        assertGt(initialK, 0);

        // Mint small amount
        uint256 testAmount0 = 1 ether;
        uint256 testAmount1 = 0.5 ether;
        token0.transfer(address(pair), testAmount0);
        token1.transfer(address(pair), testAmount1);
        uint256 lpBefore = pair.balanceOf(owner);
        pair.mint(owner);
        uint256 lpAfter = pair.balanceOf(owner);
        uint256 liquidityMinted = lpAfter - lpBefore;

        // Burn same amount
        pair.transfer(address(pair), liquidityMinted);
        uint256 token0Before = token0.balanceOf(owner);
        pair.burn(owner);
        uint256 token0After = token0.balanceOf(owner);

        uint256 recovered = token0After - token0Before;
        assertGe(recovered, testAmount0 - 0.01 ether);
    }

    // Price Oracle
    function testCumulativePrices() public {
        // Seed liquidity
        vm.startPrank(alice);
        token0.transfer(address(pair), LIQUIDITY_AMOUNT0);
        token1.transfer(address(pair), LIQUIDITY_AMOUNT1);
        pair.mint(alice);
        vm.stopPrank();

        uint256 p0c1 = pair.price0CumulativeLast();
        uint256 p1c1 = pair.price1CumulativeLast();

        // Do a swap
        vm.startPrank(alice);
        token0.transfer(address(pair), 5 ether);
        pair.swap(0, 1 ether, alice, "");
        vm.stopPrank();

        // Advance time and sync to update cumulative
        vm.warp(block.timestamp + 1);
        pair.sync();

        uint256 p0c2 = pair.price0CumulativeLast();
        uint256 p1c2 = pair.price1CumulativeLast();

        assertGe(p0c2, p0c1);
        assertGe(p1c2, p1c1);
    }
}
