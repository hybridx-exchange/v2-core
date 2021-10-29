pragma solidity >=0.5.0;

interface IOrderBook {
    //orderbook合约初始化函数
    function initialize(
        address baseToken,
        address quoteToken,
        uint priceStep,
        uint minAmount)
    external;

    //创建限价买订单
    function createBuyLimitOrder(
        address user,
        uint amountOffer,
        uint price,
        address to)
    external
    returns (uint);

    //创建限价买订单
    function createSellLimitOrder(
        address user,
        uint amountOffer,
        uint price,
        address to)
    external
    returns (uint);

    //取消订单
    function cancelLimitOrder(uint orderId) external;

    //用户订单
    function userOrders(address user) external view returns (uint[] memory orderIds);

    //市场订单
    function marketOrder(uint orderId) external view returns (uint[] memory order);

    //市场订单薄
    function marketBook(
        uint8 direction,
        uint32 maxSize)
    external
    view
    returns (uint[] memory prices, uint[] memory amounts);

    //下一个价格对应的订单-用于遍历
    function nextOrder(
        uint8 direction,
        uint curPrice)
    external
    view
    returns (uint nextPrice, uint[] memory amounts);

    //下一个价格对应的订单薄-用于遍历所有订单薄
    function nextBook(
        uint8 direction,
        uint curPrice)
    external
    view
    returns (uint nextPrice, uint amount);

    //吃特定价格的限价买单
    function takeBuyLimitOrder(
        uint amountOffer,
        uint price)
    external
    returns (address[] memory accounts, uint[] memory amounts, uint amountUsed);

    //吃特定价格的限价卖单
    function takeSellLimitOrder(
        uint amountOffer,
        uint price)
    external
    returns (address[] memory accounts, uint[] memory amounts, uint amountUsed);

    //根据tokenIn/tokenOut判断交易方向
    function tradeDirection(
        address tokenIn,
        address tokenOut)
    external
    view
    returns (uint8);

    //价格小数点位数
    function priceDecimal() external view returns (uint8);

    //基准token -- 比如btc
    function baseToken() external view returns (address);
    //计价token -- 比如usd
    function quoteToken() external view returns (address);
    //价格间隔
    function priceStep() external view returns (uint);
    //更新价格间隔
    function priceStepUpdate(uint newPriceStep) external;
    //最小数量
    function minAmount() external view returns (uint);
    //更新最小数量
    function minAmountUpdate(uint newMinAmount) external;
}
