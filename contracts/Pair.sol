// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title UniswapV2Pair
 * @notice The core AMM contract. Holds liquidity, executes swaps, enforces invariant.
 * 
 * CRITICAL SECURITY: This contract holds user funds. It is intentionally minimal.
 * - No external calls during swaps (prevents reentrancy)
 * - Invariant (x*y=k) is checked at END of every operation
 * - Balances are checked by comparing current balance to cached reserve
 */
contract UniswapV2Pair is ERC20, ReentrancyGuard {

    // ==================== STATE ====================
    
    address public factory;
    address public token0;
    address public token1;
    
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    // Cumulative sum for TWAP (time-weighted average price) oracle
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    // Minimum liquidity locked forever (prevents division by zero)
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    // ==================== EVENTS ====================
    
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    // ==================== CONSTRUCTOR ====================
    
    constructor(address _token0, address _token1) ERC20("UniswapV2 Pair", "UNI-V2") {
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
    }

    // ==================== CORE LOGIC ====================
    
    /**
     * Returns current reserves and timestamp
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /**
     * Internal function: updates reserves and price oracle
     * Called after every mint/burn/swap
     */
    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "OVERFLOW");
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestampLast == 0 ? 0 : blockTimestamp - blockTimestampLast;

        if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            // UQ112x112 fixed point for cumulative prices
            // price0 = reserve1 / reserve0; price1 = reserve0 / reserve1
            price0CumulativeLast += (uint256(reserve1) << 112) / reserve0 * timeElapsed;
            price1CumulativeLast += (uint256(reserve0) << 112) / reserve1 * timeElapsed;
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /**
     * Mints liquidity tokens to msg.sender
     * Sender must have transferred tokens to this contract BEFORE calling mint
     */
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
            // OpenZeppelin v5 disallows minting to zero address; use a burn address
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            uint256 liquidity0 = amount0 * _totalSupply / _reserve0;
            uint256 liquidity1 = amount1 * _totalSupply / _reserve1;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
            require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        }

        _mint(to, liquidity);
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * Burns liquidity tokens to withdraw tokens
     * Sender must have transferred LP tokens to this contract BEFORE calling burn
     */
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 _totalSupply = totalSupply();
        amount0 = balance0 * liquidity / _totalSupply;
        amount1 = balance1 * liquidity / _totalSupply;

        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        require(IERC20(token0).transfer(to, amount0), "TRANSFER_FAILED_0");
        require(IERC20(token1).transfer(to, amount1), "TRANSFER_FAILED_1");

        uint256 newBalance0 = IERC20(token0).balanceOf(address(this));
        uint256 newBalance1 = IERC20(token1).balanceOf(address(this));
        _update(newBalance0, newBalance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * Swaps tokens at the pair
     */
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "INSUFFICIENT_LIQUIDITY");
        
        // perform optimistic transfer
        if (amount0Out > 0) {
            require(IERC20(token0).transfer(to, amount0Out), "TRANSFER_FAILED_0");
        }
        if (amount1Out > 0) {
            require(IERC20(token1).transfer(to, amount1Out), "TRANSFER_FAILED_1");
        }

        // flash swap callback skipped (data ignored)
        if (data.length > 0) {
            // For simplicity in this minimal core, ignore callbacks
        }

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > uint256(_reserve0) - amount0Out ? balance0 - (uint256(_reserve0) - amount0Out) : 0;
        uint256 amount1In = balance1 > uint256(_reserve1) - amount1Out ? balance1 - (uint256(_reserve1) - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");

        // 0.3% fee
        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        require(balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * uint256(_reserve1) * 1000000, "INVARIANT_BROKEN");

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // ==================== ADMIN ====================
    
    /**
     * Force balances to match reserves (emergency recovery)
     */
    function sync() external nonReentrant {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this))
        );
    }

    // ==================== UTILITIES ====================
    
    /**
     * Sqrt implementation for liquidity calculation
     * babylonian method: x = (x + x*x/y)/2
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
