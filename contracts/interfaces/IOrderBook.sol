pragma solidity >=0.5.0;

interface IOrderBook {
    //take order when move price by uniswap v2 pair
    function takeOrderWhenMovePrice(address tokenIn, uint amountIn, address to)
    external
    returns (uint amountOut, address[] memory accounts, uint[] memory amounts);
}
