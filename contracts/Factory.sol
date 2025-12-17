// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Pair.sol";

/**
 * @title UniswapV2Factory
 * @notice Creates and tracks AMM pairs


 */
contract UniswapV2Factory {
    
    // ==================== STATE ====================
    
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    address public feeTo;
    address public feeToSetter;

    // ==================== EVENTS ====================
    
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 length);

    // ==================== CONSTRUCTOR ====================
    
    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    // ==================== CORE LOGIC ====================
    
    /**
     * Creates a new pair for token0/token1
     */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "ZERO_ADDRESS");

        // Canonical ordering: token0 < token1
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        require(getPair[token0][token1] == address(0), "PAIR_EXISTS");

        // Optional: ensure both are contracts
        require(token0.code.length > 0 && token1.code.length > 0, "ZERO_ADDRESS");

        UniswapV2Pair _pair = new UniswapV2Pair(token0, token1);
        pair = address(_pair);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // ==================== ADMIN ====================
    
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        feeToSetter = _feeToSetter;
    }

    // ==================== VIEW ====================
    
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}
