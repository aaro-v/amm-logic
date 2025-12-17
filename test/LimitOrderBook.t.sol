// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {UniswapV2Factory} from "contracts/Factory.sol";
import {UniswapV2Pair} from "contracts/Pair.sol";
import {MockERC20} from "contracts/MockERC20.sol";
import {LimitOrderBook} from "contracts/LimitOrderBook.sol";

contract LimitOrderBookTest is Test {
    UniswapV2Factory factory;
    UniswapV2Pair pair;
    MockERC20 token0;
    MockERC20 token1;
    LimitOrderBook lob;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token0 = new MockERC20("Token0", "T0", 1_000_000 ether);
        token1 = new MockERC20("Token1", "T1", 1_000_000 ether);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        factory = new UniswapV2Factory(address(this));
        address pairAddress = factory.createPair(address(token0), address(token1));
        pair = UniswapV2Pair(pairAddress);
        lob = new LimitOrderBook(address(factory));

        // Seed liquidity: 1000 T0 : 1000 T1 => Price 1:1
        token0.transfer(address(pair), 1_000 ether);
        token1.transfer(address(pair), 1_000 ether);
        pair.mint(address(this));

        // Fund Alice
        token0.transfer(alice, 100 ether);
        token1.transfer(alice, 100 ether);
    }

    function testPlaceAndExecuteOrder() public {
        // Alice wants to sell 10 T0 for at least 9 T1
        // Current price is ~1:1, so this should execute immediately
        vm.startPrank(alice);
        token0.approve(address(lob), 10 ether);
        uint256 orderId = lob.placeOrder(address(token0), address(token1), 10 ether, 9 ether);
        vm.stopPrank();

        uint256 aliceT1Before = token1.balanceOf(alice);

        // Bob (keeper) executes
        vm.startPrank(bob);
        lob.executeOrder(orderId);
        vm.stopPrank();

        uint256 aliceT1After = token1.balanceOf(alice);
        assertGt(aliceT1After, aliceT1Before);
        
        // Check order is inactive
        (,,,,,, bool active) = lob.orders(orderId);
        assertFalse(active);
    }

    function testExecutionFailsIfPriceBad() public {
        // Alice wants to sell 10 T0 for 20 T1 (Price 1:2)
        // Current price is 1:1, so this should fail
        vm.startPrank(alice);
        token0.approve(address(lob), 10 ether);
        uint256 orderId = lob.placeOrder(address(token0), address(token1), 10 ether, 20 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert("LOB: INSUFFICIENT_OUTPUT");
        lob.executeOrder(orderId);
        vm.stopPrank();
    }

    function testCancelOrder() public {
        vm.startPrank(alice);
        token0.approve(address(lob), 10 ether);
        uint256 orderId = lob.placeOrder(address(token0), address(token1), 10 ether, 9 ether);
        
        uint256 balBefore = token0.balanceOf(alice);
        lob.cancelOrder(orderId);
        uint256 balAfter = token0.balanceOf(alice);

        assertEq(balAfter, balBefore + 10 ether);
        
        (,,,,,, bool active) = lob.orders(orderId);
        assertFalse(active);
        vm.stopPrank();
    }
}
