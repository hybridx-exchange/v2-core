pragma solidity >=0.5.0;

interface IOrderBookFactory {
    function WETH() external pure returns (address);
    function getOrderBook(address tokenA, address tokenB) external view returns (address orderBook);
}