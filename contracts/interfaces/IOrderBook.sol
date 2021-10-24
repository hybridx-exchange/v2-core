pragma solidity >=0.5.0;

interface IOrderBook {
    function initialize(address baseToken, address quoteToken, uint priceStep, uint minAmount) external;
    function createBuyLimitOrder(address user, uint amountOffer, uint price, address to) external returns (uint);
    function createSellLimitOrder(address user, uint amountOffer, uint price, address to) external returns (uint);
    function cancelLimitOrder(uint orderId) external;
    function tradeDirection(address tokenA, address tokenB) external view returns (uint8);
    function priceDecimal(address tokenA, address tokenB) external view returns (uint8);
    function marketOrder(uint8 direction) external view returns (uint[] memory prices, uint[] memory amounts);
    function marketRangeOrder(uint8 direction, uint price) external view returns (uint[] memory prices, uint[] memory
        amounts);
    function takeBuyLimitOrder(uint amountIn, uint price) external returns (address[] memory accounts, uint[] memory
        amounts, uint amountTake);
    function takeSellLimitOrder(uint amountOut, uint price) external returns (address[] memory accounts, uint[]
        memory amounts, uint amountTake);
    function baseToken() external view returns (address);
    function quoteToken() external view returns (address);
    function priceStep() external view returns (uint);
    function priceStepUpdate(uint newPriceStep) external;
    function minAmount() external view returns (uint);
    function minAmountUpdate(uint newMinAmount) external;
}
