// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./Factory.sol";
import "./Pair.sol";
import "./WETH9.sol";

/**
 * @title Router
 * @notice Minimal UniswapV2-style router for add/remove liquidity and swaps.
 */
contract Router {
    UniswapV2Factory public immutable factory;
    WETH9 public immutable WETH;

    error Expired();
    error InvalidPath();
    error PairNotFound();
    error InsufficientA();
    error InsufficientB();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error EthTransferFailed();

    constructor(address factory_, address weth_) {
        factory = UniswapV2Factory(factory_);
        WETH = WETH9(payable(weth_));
    }

    receive() external payable {
        // only accept ETH from WETH withdraw
        require(msg.sender == address(WETH), "Router: ETH_ONLY_FROM_WETH");
    }

    // -------------------------
    // Math helpers
    // -------------------------

    function _quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256) {
        require(amountA > 0, "Router: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "Router: INSUFFICIENT_LIQUIDITY");
        return amountA * reserveB / reserveA;
    }

    function _getReserves(address tokenA, address tokenB) internal view returns (uint256 reserveA, uint256 reserveB, address pairAddress) {
        pairAddress = factory.getPair(tokenA, tokenB);
        if (pairAddress == address(0)) revert PairNotFound();

        UniswapV2Pair pair = UniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        if (tokenA == pair.token0()) {
            (reserveA, reserveB) = (reserve0, reserve1);
        } else {
            (reserveA, reserveB) = (reserve1, reserve0);
        }
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        require(amountIn > 0, "Router: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "Router: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut,) = _getReserves(path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    function _ensure(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired();
    }

    // -------------------------
    // Liquidity
    // -------------------------

    function _createPairIfNeeded(address tokenA, address tokenB) internal returns (address pairAddress) {
        pairAddress = factory.getPair(tokenA, tokenB);
        if (pairAddress == address(0)) {
            pairAddress = factory.createPair(tokenA, tokenB);
        }
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB, address pairAddress) {
        pairAddress = _createPairIfNeeded(tokenA, tokenB);
        (uint256 reserveA, uint256 reserveB,) = _getReserves(tokenA, tokenB);

        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = _quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert InsufficientB();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
                if (amountAOptimal < amountAMin) revert InsufficientA();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }

        if (amountA < amountAMin) revert InsufficientA();
        if (amountB < amountBMin) revert InsufficientB();
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        _ensure(deadline);

        address pairAddress;
        (amountA, amountB, pairAddress) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);

        IERC20(tokenA).transferFrom(msg.sender, pairAddress, amountA);
        IERC20(tokenB).transferFrom(msg.sender, pairAddress, amountB);

        liquidity = UniswapV2Pair(pairAddress).mint(to);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB) {
        _ensure(deadline);

        address pairAddress = factory.getPair(tokenA, tokenB);
        if (pairAddress == address(0)) revert PairNotFound();

        // transfer LP to pair then burn
        IERC20(pairAddress).transferFrom(msg.sender, pairAddress, liquidity);
        (uint256 amount0, uint256 amount1) = UniswapV2Pair(pairAddress).burn(to);

        UniswapV2Pair pair = UniswapV2Pair(pairAddress);
        if (tokenA == pair.token0()) {
            (amountA, amountB) = (amount0, amount1);
        } else {
            (amountA, amountB) = (amount1, amount0);
        }

        if (amountA < amountAMin) revert InsufficientA();
        if (amountB < amountBMin) revert InsufficientB();
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        _ensure(deadline);

        address pairAddress;
        (amountToken, amountETH, pairAddress) = _addLiquidity(token, address(WETH), amountTokenDesired, msg.value, amountTokenMin, amountETHMin);

        IERC20(token).transferFrom(msg.sender, pairAddress, amountToken);
        WETH.deposit{value: amountETH}();
        require(WETH.transfer(pairAddress, amountETH), "Router: WETH_TRANSFER_FAILED");

        liquidity = UniswapV2Pair(pairAddress).mint(to);

        // refund excess ETH
        if (msg.value > amountETH) {
            (bool ok,) = msg.sender.call{value: msg.value - amountETH}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH) {
        _ensure(deadline);

        address pairAddress = factory.getPair(token, address(WETH));
        if (pairAddress == address(0)) revert PairNotFound();

        IERC20(pairAddress).transferFrom(msg.sender, pairAddress, liquidity);
        (uint256 amount0, uint256 amount1) = UniswapV2Pair(pairAddress).burn(address(this));

        UniswapV2Pair pair = UniswapV2Pair(pairAddress);
        (amountToken, amountETH) = token == pair.token0() ? (amount0, amount1) : (amount1, amount0);

        if (amountToken < amountTokenMin) revert InsufficientA();
        if (amountETH < amountETHMin) revert InsufficientB();

        IERC20(token).transfer(to, amountToken);
        WETH.withdraw(amountETH);
        (bool ok,) = to.call{value: amountETH}("");
        if (!ok) revert EthTransferFailed();
    }

    // -------------------------
    // Swaps
    // -------------------------

    function _swap(uint256[] memory amounts, address[] memory path, address to) internal {
        for (uint256 i = 0; i < path.length - 1; i++) {
            address input = path[i];
            address output = path[i + 1];
            address pairAddress = factory.getPair(input, output);
            if (pairAddress == address(0)) revert PairNotFound();

            UniswapV2Pair pair = UniswapV2Pair(pairAddress);
            address token0 = pair.token0();

            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

            address nextTo = i < path.length - 2 ? factory.getPair(output, path[i + 2]) : to;
            pair.swap(amount0Out, amount1Out, nextTo, "");
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        _ensure(deadline);
        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutput();

        address firstPair = factory.getPair(path[0], path[1]);
        if (firstPair == address(0)) revert PairNotFound();
        IERC20(path[0]).transferFrom(msg.sender, firstPair, amounts[0]);
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        _ensure(deadline);
        if (path.length < 2 || path[0] != address(WETH)) revert InvalidPath();

        amounts = getAmountsOut(msg.value, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutput();

        address firstPair = factory.getPair(path[0], path[1]);
        if (firstPair == address(0)) revert PairNotFound();

        WETH.deposit{value: amounts[0]}();
        require(WETH.transfer(firstPair, amounts[0]), "Router: WETH_TRANSFER_FAILED");

        _swap(amounts, path, to);
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        _ensure(deadline);
        if (path.length < 2 || path[path.length - 1] != address(WETH)) revert InvalidPath();

        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutput();

        address firstPair = factory.getPair(path[0], path[1]);
        if (firstPair == address(0)) revert PairNotFound();
        IERC20(path[0]).transferFrom(msg.sender, firstPair, amounts[0]);

        _swap(amounts, path, address(this));

        uint256 wethOut = amounts[amounts.length - 1];
        WETH.withdraw(wethOut);
        (bool ok,) = to.call{value: wethOut}("");
        if (!ok) revert EthTransferFailed();
    }
}
