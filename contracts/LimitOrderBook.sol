// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Pair.sol";
import "./Factory.sol";

/**
 * @title LimitOrderBook
 * @notice Allows users to place limit orders that can be executed by anyone when the spot price satisfies the order.
 */
contract LimitOrderBook {
    struct Order {
        uint256 id;
        address maker;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bool active;
    }

    UniswapV2Factory public factory;
    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;

    event OrderPlaced(uint256 indexed orderId, address indexed maker, address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut);
    event OrderExecuted(uint256 indexed orderId, address indexed executor, uint256 amountOut);
    event OrderCancelled(uint256 indexed orderId);

    constructor(address _factory) {
        factory = UniswapV2Factory(_factory);
    }

    /**
     * @notice Place a limit order by depositing tokens.
     */
    function placeOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256) {
        require(amountIn > 0, "LOB: ZERO_AMOUNT");
        require(tokenIn != tokenOut, "LOB: SAME_TOKEN");

        // Transfer tokens to this contract
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            maker: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            active: true
        });

        emit OrderPlaced(orderId, msg.sender, tokenIn, tokenOut, amountIn, minAmountOut);
        return orderId;
    }

    /**
     * @notice Cancel an active order and withdraw tokens.
     */
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(order.active, "LOB: ORDER_NOT_ACTIVE");
        require(order.maker == msg.sender, "LOB: NOT_MAKER");

        order.active = false;
        IERC20(order.tokenIn).transfer(order.maker, order.amountIn);

        emit OrderCancelled(orderId);
    }

    /**
     * @notice Execute an order if the current spot price allows it.
     * @dev Anyone can call this (keepers).
     */
    function executeOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(order.active, "LOB: ORDER_NOT_ACTIVE");

        address pairAddress = factory.getPair(order.tokenIn, order.tokenOut);
        require(pairAddress != address(0), "LOB: PAIR_NOT_FOUND");
        UniswapV2Pair pair = UniswapV2Pair(pairAddress);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        address token0 = pair.token0();
        
        (uint112 reserveIn, uint112 reserveOut) = order.tokenIn == token0 
            ? (reserve0, reserve1) 
            : (reserve1, reserve0);

        // Calculate amountOut based on current reserves
        // amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
        uint256 amountInWithFee = order.amountIn * 997;
        uint256 numerator = amountInWithFee * uint256(reserveOut);
        uint256 denominator = uint256(reserveIn) * 1000 + amountInWithFee;
        uint256 amountOut = numerator / denominator;

        require(amountOut >= order.minAmountOut, "LOB: INSUFFICIENT_OUTPUT");

        // Mark inactive before interaction to prevent reentrancy
        order.active = false;

        // Transfer tokens to pair
        IERC20(order.tokenIn).transfer(pairAddress, order.amountIn);

        // Swap
        // If tokenIn is token0, we want amountOut of token1 (amount1Out)
        // If tokenIn is token1, we want amountOut of token0 (amount0Out)
        (uint256 amount0Out, uint256 amount1Out) = order.tokenIn == token0 
            ? (uint256(0), amountOut) 
            : (amountOut, uint256(0));

        pair.swap(amount0Out, amount1Out, order.maker, "");

        emit OrderExecuted(orderId, msg.sender, amountOut);
    }
}
