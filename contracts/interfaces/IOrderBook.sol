pragma solidity >=0.5.0;

interface IOrderBook {
    function takeOrderWhenMovePrice(address tokenIn, uint amountIn, address to)
    external
    returns (uint amountOutLeft, address[] memory accounts, uint[] memory amounts);
}
