pragma solidity >=0.5.0;

interface IOrderBookFactory {
    event OrderBookCreated(address, address, address, address, uint, uint);
    function WETH() external pure returns (address);
    function pairFactory() external pure returns (address);
    function getOrderBook(address tokenA, address tokenB) external view returns (address orderBook);
    function allOrderBooks(uint) external view returns (address orderBook);
    function createOrderBook(address baseToken, address quoteToken, uint priceStep, uint minAmount) external;
}