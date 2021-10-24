pragma solidity =0.5.16;

import "../interfaces/IERC20.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IOrderBook.sol";
import "../libraries/HybridLibrary.sol";

contract OrderQueue {
    //每一个价格对应一个订单队列(方向 -> 价格 -> 索引 -> data ================= 订单队列数据<先进先出>)
    mapping(uint8 => mapping(uint => mapping(uint => uint))) private limitOrderQueueMap;
    //每一个价格对应一个订单队列(方向 -> 价格 -> 订单队列头索引)
    mapping(uint8 => mapping(uint => uint)) private limitOrderQueueFront;
    //每一个价格对应一个订单队列(方向 -> 价格 -> 订单队列尾索引)
    mapping(uint8 => mapping(uint => uint)) private limitOrderQueueRear;

    // Queue length，不考虑溢出的情况
    function length(uint8 direction, uint price) internal returns (uint limitOrderQueueLength) {
        limitOrderQueueLength = limitOrderQueueRear[direction][price] - limitOrderQueueFront[direction][price];
    }

    // push
    function push(uint8 direction, uint price, uint data) internal {
        uint rear = limitOrderQueueRear[direction][price];
        limitOrderQueueMap[direction][price][rear] = data;
        limitOrderQueueRear[direction][price]++;
    }

    // pop
    function pop(uint8 direction, uint price) internal returns (uint data){
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        if (front != rear){
            data = limitOrderQueueMap[direction][price][front];
            delete limitOrderQueueMap[direction][price][front];
            limitOrderQueueFront[direction][price]++;
        }
    }

    // del - 调用方保证元素一定存在
    function del(uint8 direction, uint price, uint data) {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        require(front < rear, 'Invalid queue');

        //将元素从尾往前移，如果只有一个元素不需要进入循环
        uint pre = limitOrderQueueMap[direction][price][front];
        for (uint i=front+1; i<rear; i++) {
            if (pre == data) {
                break;
            }

            uint cur = limitOrderQueueMap[direction][price][i];
            //将上一个位置的元素移到当前位置
            limitOrderQueueMap[direction][price][i] = pre;
            //为下一次做准备
            pre = cur;
        }

        //最后一定会找到与data相等的元素
        require(data == cur, 'Invalid data');

        delete limitOrderQueueMap[direction][price][front];
        limitOrderQueueFront[direction][price]++;
    }

    // list
    function list(uint8 direction, uint price) internal returns (uint[] memory allData){
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        for (uint i=front; i<rear; i++) {
            allData[i-front] = limitOrderQueueMap[direction][price][i];
        }
    }

    // listAgg
    function listAgg(uint8 direction, uint price) internal returns (uint dataAgg){
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        for (uint i=front; i<rear; i++){
            dataAgg += limitOrderQueueMap[direction][price][i];
        }
    }
}

contract PriceList {
    //每一个位置对应一个价格数组(方向 -> 价格 -> 下一个价格) 需要对价格排序 （索引表示价格在map中的顺序）
    mapping(uint8 => mapping(uint => uint)) private limitOrderDataArrayMap;
    //每一个位置对应一个价格(方向 -> 长度) （用于遍历所有价格时的边界）
    mapping(uint8 => uint) private limitOrderPriceArrayLength;

    // 链接长度
    function priceLength(uint8 direction) internal returns (uint priceArrayLength) {
        priceArrayLength = limitOrderPriceArrayLength[direction];
    }

    // 查找插入位置-上一个位置 + 当前位置
    function priceLocation(uint8 direction, uint price) internal returns (uint preIndex, uint next) {
        preIndex = 0;
        uint data = limitOrderDataArrayMap[direction][0];
        next = limitOrderDataArrayMap[direction][data];
        if (direction == 1) { //由大到小排列
            while(data > price) {
                preIndex = data;
                data = next;
                next = limitOrderDataArrayMap[direction][data];
                if (next == 0){
                    break;
                }
            }
        }
        else if (direction == 2) {//由小到大排列
            while(data < price) {
                preIndex = data;
                data = next;
                next = limitOrderDataArrayMap[direction][data];
                if (next == 0){
                    break;
                }
            }
        }
    }

    function addPrice(uint8 direction, uint price) external {//外部调用保证没有重复
        uint priceArrayLength = limitOrderPriceArrayLength[direction];
        if (priceArrayLength == 0) {//第一个元素
            limitOrderPriceDataMap[direction][0] = price;
            limitOrderPriceDataMap[direction][price] = 0;
        }
        else {
            (uint preIndex, uint nextIndex) = priceLocation(direction, price);
            limitOrderPriceDataMap[direction][preIndex] = price;
            limitOrderPriceDataMap[direction][price] = nextIndex;
        }

        limitOrderPriceArrayLength[direction]++;
    }

    function delPrice(uint8 direction, uint price) external {//外部调用保证元素存在
        (uint preIndex, uint nextIndex) = priceLocation(direction, price);
        require(price == nextIndex, 'Invalid price');
        limitOrderPriceDataMap[direction][preIndex] = limitOrderPriceDataMap[direction][nextIndex];
        delete limitOrderPriceDataMap[direction][nextIndex];
        limitOrderPriceArrayLength[direction]--;
    }

    function nextPrice(uint8 direction, uint price) external returns (uint next){
        next = limitOrderPriceDataMap[direction][price];
    }
}

contract OrderBook is IOrderBook, OrderQueue, PriceList {
    struct Order {
        uint orderId;
        uint orderOwner;
        uint limitPrice;
        uint amountOffer;
        uint amountRemain;
        uint orderType; //1: limitBuy, 2: limitSell
        uint orderIndex; //用户订单索引
        address to;
    }

    //名称
    string public constant name = 'Uniswap V2 OrderBook';

    //货币对
    address public pair;

    //价格间隔参数-保证价格间隔的设置在一个合理的范围内
    uint priceStep; //priceStep 和 minAmount和修改可以考虑在一定时间内由合约创建者负责修改，一定时间后将维护权自动转交给投票合约及管理员
    //最小数量
    uint minAmount;
    //价格的位数与quoteToken保持一致
    //数量的位数与baseToken保持一致

    //基础货币
    address public baseToken;
    //记价货币
    address public quoteToken;

    //未完成总订单，链上不保存已成交的订单(订单id -> Order)
    mapping(uint => Order) public allOrderMap;

    //用户订单(用户地址 -> 订单id数组)
    mapping(address => uint[]) public userOrdersMap;

    constructor() public {
        pair = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _baseToken, address _quoteToken, uint _priceStep, uint _minAmount) external {
        require(msg.sender == pair, 'UniswapV2 OrderBook: FORBIDDEN'); // sufficient check
        require(baseToken != quoteToken, 'UniswapV2 OrderBook: Token Pair Invalid');
        require(_priceStep >= 1, 'UniswapV2 OrderBook: Price Step Invalid');
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        priceStep = _priceStep;
        minAmount = _minAmount;
        TransferHelper.safeApprove(baseToken, pair, uint(-1));
        TransferHelper.safeApprove(quoteToken, pair, uint(-1));
    }

    // 允许base/quote token向pair合约转账
    function approveAll() external {
        TransferHelper.safeApprove(baseToken, pair, uint(-1));
        TransferHelper.safeApprove(quoteToken, pair, uint(-1));
    }

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2 OrderBook: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    //id生成器
    uint private orderIdGenerator;
    function _generateOrderId() private returns (uint) {
        orderIdGenerator++;
        return orderIdGenerator;
    }

    function getReserves() public view returns (uint112 _reserveBase, uint112 _reserveQuote, uint32 _blockTimestampLast) {
        (uint112 _reserve0, uint112 _reserve1, uint32 blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
        _reserveBase = baseToken == IUniswapV2Pair(pair).token0() ? _reserve0 : _reserve1;
        _reserveQuote = _reserveBase == _reserve0 ? _reserve1 : _reserve0;
        _blockTimestampLast = blockTimestampLast;
    }

    function tradeDirection(address tokenA, address tokenB) external returns (uint8 direction) {
        direction = quoteToken == tokenA ? 1 : 2;
    }

    function priceDecimal(address tokenA, address tokenB) external returns (uint8 decimal) {
        decimal = quoteToken == tokenA ? IERC20(tokenA).decimals() : IERC20(tokenB).decimals();
    }

    //创建order对象
    function _newLimitOrder(address _owner, uint _amountOffer, uint _amountRemain, uint _price, uint _type, address
        _to) private returns (Order memory order) {
        order = new Order();
        order.orderOwner = _owner;
        order.orderId = _generateOrderId();
        order.amountOffer = _amountOffer;
        order.amountRemain = _amountRemain;
        order.limitPrice = _price;
        order.orderType = _type;
        order.to = _to;
        return order;
    }

    //添加order对象
    function _addLimitOrder(address user, uint _amountOffer, uint _amountRemain, uint _price, uint8 _type, address
        _to) private {
        Order order = _newLimitOrder(user, _amountOffer, _amountRemain, _price, _type, _to);
        uint[] userOrders = userOrdersMap[user];
        order.orderIndex = userOrders.length;
        userOrders.push(order.orderId);
        allOrderMap[order.orderId] = order;
        if (length(_type, _price) == 0){
            addPrice(_type, _price);
        }

        push(_type, _price, order.orderId);
    }

    //删除order对象
    function _removeLimitOrder(Order order) private {
        //删除全局订单
        delete allOrderMap[order.orderId];

        //删除用户订单
        uint[] userOrders = userOrdersMap[order.orderOwner];
        require(userOrders.length > order.orderIndex);
        //直接用最后一个元素覆盖当前元素
        if (order.orderIndex !=  userOrders.length - 1) {
            userOrders[orderIndex] = userOrders[userOrders.length - 1];
        }

        //删除用户订单
        userOrders.pop();

        //删除队列订单
        del(order.type, order.price, order.orderId);

        //删除价格
        if (length(order.type, order.price)){
            delPrice(order.type, order.price);
        }
    }

    function marketOrder(uint8 direction) external view returns (uint[] memory prices, uint[] memory amounts){

    }

    function marketRangeOrder(uint8 direction, uint price) external view returns (uint[] memory prices, uint[] memory
        amounts){

    }

    //订单薄，不关注订单具体信息
    function marketBook(uint8 direction) external returns (uint[] memory prices, uint[] memory amounts){

    }

    //使用特定数量的token将价格向上移动到特定值--具体执行放到UniswapV2Pair里面, 在这里需要考虑当前价格到目标价格之间的挂单，amm中的分段只用于计算，实际交易整体完成，不分段
    function _movePriceUp(uint amountOffer, uint _targetPrice) private returns (uint quoteAmountIn) {
        //获取价格范围内的反方向挂单
        (uint[] priceArray, uint[] amountArray) = marketRangeOrder(2, _targetPrice);
        (uint reserveOut, uint reserveIn) = getReserves();
        uint amountLeft = amountOffer;
        uint amountUsed;
        uint amountAmmIn;
        uint amountAmmOut;

        //看看是否需要吃单
        for (uint i=0; i<priceArray.length; i++){
            //先计算pair从当前价格到price[j]消耗amountIn的数量
            (amountUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(direction, reserveIn, reserveOut, priceArray[i], decimal);
            //再计算本次移动价格获得的amountOut
            amountAmmOut += amountUsed > amountLeft ? HybridLibrary.getAmountOut(amountLeft, reserveIn, reserveOut) : HybridLibrary.getAmountOut(amountUsed, reserveIn, reserveOut);
            //再计算amm中实际会消耗的amountIn的数量
            amountAmmIn += amountUsed > amountLeft ? amountLeft : amountUsed;
            //再计算还剩下的amountIn
            amountLeft = amountUsed < amountLeft ? amountLeft - amountUsed : 0;
            if (amountLeft == 0) {
                break;
            }

            //消耗掉一个价格的挂单并返回实际需要的amountIn数量 -- 将amountOut（包含手续费)由orderbook合约先转入入pair合约，便于flash swap使用，返回需要转账的地址和数量
            (uint amountInForTake, uint amountOutWithFee, address[] accounts, uint[] amounts) = HybridLibrary.getAmountAndTakePrice
            (direction, amountLeft, priceArray[i], decimal, amountArray[i]);

            if (amountLeft >= amountInForTake) { //amountIn消耗完了
                break;
            }
        }

        //处理挂单之外的价格范围
        (amountUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(direction, reserveIn, reserveOut, _targetPrice, decimal);
        //再计算本次移动价格获得的amountOut
        amountAmmOut += amountUsed > amountLeft ? HybridLibrary.getAmountOut(amountLeft, reserveIn, reserveOut) : HybridLibrary.getAmountOut(amountUsed, reserveIn, reserveOut);
        //再计算amm中实际会消耗的amountIn的数量
        amountAmmIn += amountUsed > amountLeft ? amountLeft : amountUsed;

        //向pair转账
        require(IERC20(quoteToken).allowance(address(this), pair) > amountAmmIn, 'UniswapV2 OrderBook: transfer amount exceeds spender allowance');
        _safeTransfer(quoteToken, pair, amountAmmIn);

        //将当前价格移动到目标价格并最多消耗amountLeft
        (uint amount0Out, uint amount1Out) = baseToken == IUniswapV2Pair(pair).token0() ? (uint(0), amountOut) : (amountOut, uint(0));
        IUniswapV2Pair(pair).swapOriginal(amount0Out, amount1Out, to, new bytes(0));
    }

    //使用特定数量的token将价格向上移动到特定值--具体执行放到UniswapV2Pair里面, 在这里需要考虑当前价格到目标价格之间的挂单
    function _movePriceDown(uint _targetPrice) private returns (uint baseAmountIn) {

    }

    //创建限价买订单
    function createBuyLimitOrder(address user, uint amountOffer, uint price, address to) public {
        require(amountOffer % amountStep == 0, 'UniswapV2 OrderBook: Amount Invalid');
        require(price % priceStep == 0, 'UniswapV2 OrderBook: Price Invalid');

        //需要先将token转移到order book合约(在router中执行), 以免与pair中的token混合

        //先在流动性池将价格拉到挂单价，同时还需要吃掉价格范围内的反方向挂单
        uint quoteAmountIn = _movePriceUp(price);
        uint amountRemain = amountOffer > quoteAmountIn ? amountOffer - quoteAmountIn : 0;

        if (amountRemain == 0){
            //直接产生订单创建事件和订单成交事件,不保存订单数据
        }
        else {
            //未成交的部分生成限价买单
            Order order = _addLimitOrder(user, amountOffer, amountRemain, price, 0, to);
            //产生订单创建事件

            //加入订单队列
        }
    }

    //创建限价卖订单
    function createSellLimitOrder(address user, uint amountOffer, uint _price, address to) public {
        require(amountOffer % amountStep == 0, 'UniswapV2 OrderBook: Amount Invalid');
        require(price % priceStep == 0, 'UniswapV2 OrderBook: Price Invalid');

        //需要将token转移到order book合约, 以免与pair中的token混合

        //先在流动性池将价格拉到挂单价，同时还需要吃掉价格范围内的反方向挂单
        uint baseAmountIn = _movePriceDown(_price);
        uint amountRemain = amountOffer > baseAmountIn ? amountOffer - baseAmountIn : 0;
        if (amountRemain == 0){
            //直接产生订单创建事件和订单成交事件,不保存订单数据
        }
        else {
            //未成交的部分生成限价买单
            Order order = _addLimitOrder(user, amountOffer, amountRemain, _price, 1, to);
            //产生订单创建事件

            //加入订单队列
        }
    }

    function takeLimitOrder(uint direction, uint amount, uint price) public lock returns
    (address[] memory accounts, uint[] memory amounts, uint amountTake) {
        uint amountLeft = amount;
        uint index;
        while(length(direction, price) > 0 && amountLeft > 0){
            uint orderId = pop(direction, price);
            Order order = allOrderMap[orderId];
            require(orderId == order.orderId && order.orderType == 1 && price == order.limitPrice, 'UniswapV2 OrderBook: Order Invalid');
            accounts[index] = order.to;
            amounts[index] = amountLeft > order.amountRemain ? order.amountRemain : amountLeft;
            order.amountRemain = order.amountRemain - amounts[index];
            //触发订单交易事件

            //如果还有剩余，将剩余部分入队列，交易结束
            if (order.amountRemain != 0){
                push(direction, price, order);
                break;
            }

            //删除订单
            delete allOrderMap[orderId];

            //删除用户订单
            uint[] userOrders = userOrdersMap[order.orderOwner];
            require(userOrders.length > order.orderIndex);
            //直接用最后一个元素覆盖当前元素
            userOrders[orderIndex] = userOrders[userOrders.length - 1];
            userOrders.length--;

            amountLeft = amountLeft - amounts[index++];
        }

        amountTake = amount - amountLeft;
    }

    //take buy limit order
    function takeBuyLimitOrder(uint amount, uint price) public lock returns (address[] memory accounts, uint[]
        memory amounts) {
        uint amountTake;
        (accounts, amounts, amountTake) = takeLimitOrder(1, amount, price);
        //向pair合约转账amountTake
    }

    //take sell limit order
    function takeSellLimitOrder(uint amount, uint price)  public lock returns (address[] memory accounts, uint[] memory amounts){
        uint amountTake;
        (accounts, amounts, amountTake) = takeLimitOrder(2, amount, price);
        //向pair合约转账amountTake
    }
}
