pragma solidity =0.5.16;

import "../interfaces/IERC20.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IOrderBook.sol";
import "../libraries/UniswapV2Library.sol";

contract OrderQueue {
    //每一个价格对应一个订单队列(方向 -> 价格 -> 索引 -> data ================= 订单队列数据<先进先出>)
    mapping(uint8 => mapping(uint => mapping(uint => uint))) private limitOrderQueueMap;
    //每一个价格对应一个订单队列(方向 -> 价格 -> 订单队列头索引)
    mapping(uint8 => mapping(uint => uint)) private limitOrderQueueFront;
    //每一个价格对应一个订单队列(方向 -> 价格 -> 订单队列尾索引)
    mapping(uint8 => mapping(uint => uint)) private limitOrderQueueRear;

    // Queue length，不考虑溢出的情况
    function length(
        uint8 direction,
        uint price)
    internal
    view
    returns (uint limitOrderQueueLength) {
        limitOrderQueueLength = limitOrderQueueRear[direction][price] - limitOrderQueueFront[direction][price];
    }

    // push
    function push(
        uint8 direction,
        uint price,
        uint data)
    internal {
        uint rear = limitOrderQueueRear[direction][price];
        limitOrderQueueMap[direction][price][rear] = data;
        limitOrderQueueRear[direction][price]++;
    }

    // pop
    function pop(
        uint8 direction,
        uint price)
    internal
    returns (uint data) {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        if (front != rear){
            data = limitOrderQueueMap[direction][price][front];
            delete limitOrderQueueMap[direction][price][front];
            limitOrderQueueFront[direction][price]++;
        }
    }

    // del - 调用方保证元素一定存在
    function del(
        uint8 direction,
        uint price,
        uint data)
    internal {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        require(front < rear, 'Invalid queue');

        //将元素从尾往前移，如果只有一个元素不需要进入循环
        uint pre = limitOrderQueueMap[direction][price][front];
        uint cur;
        for (uint i=front+1; i<rear; i++) {
            if (pre == data) {
                break;
            }

            cur = limitOrderQueueMap[direction][price][i];
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
    function list(
        uint8 direction,
        uint price)
    internal
    view
    returns (uint[] memory allData) {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        for (uint i=front; i<rear; i++) {
            allData[i-front] = limitOrderQueueMap[direction][price][i];
        }
    }

    // listAgg
    function listAgg(
        uint8 direction,
        uint price)
    internal
    view
    returns (uint dataAgg) {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        for (uint i=front; i<rear; i++){
            dataAgg += limitOrderQueueMap[direction][price][i];
        }
    }
}

contract PriceList {
    //每一个位置对应一个价格数组(方向 -> 价格 -> 下一个价格) 需要对价格排序 （索引表示价格在map中的顺序）
    mapping(uint8 => mapping(uint => uint)) private limitOrderPriceListMap;
    //每一个位置对应一个价格(方向 -> 长度) （用于遍历所有价格时的边界）
    mapping(uint8 => uint) private limitOrderPriceArrayLength;

    // 链接长度
    function priceLength(
        uint8 direction)
    internal
    returns (uint priceArrayLength) {
        priceArrayLength = limitOrderPriceArrayLength[direction];
    }

    // 查找插入位置-上一个位置 + 当前位置
    function priceLocation(
        uint8 direction,
        uint price)
    internal
    returns (uint preIndex, uint next) {
        preIndex = 0;
        uint data = limitOrderPriceListMap[direction][0];
        next = limitOrderPriceListMap[direction][data];
        if (direction == 1) { //由大到小排列
            while(data > price) {
                preIndex = data;
                data = next;
                next = limitOrderPriceListMap[direction][data];
                if (next == 0){
                    break;
                }
            }
        }
        else if (direction == 2) {//由小到大排列
            while(data < price) {
                preIndex = data;
                data = next;
                next = limitOrderPriceListMap[direction][data];
                if (next == 0){
                    break;
                }
            }
        }
    }

    function addPrice(
        uint8 direction,
        uint price)
    internal {//外部调用保证没有重复
        uint priceArrayLength = limitOrderPriceArrayLength[direction];
        if (priceArrayLength == 0) {//第一个元素
            limitOrderPriceListMap[direction][0] = price;
            limitOrderPriceListMap[direction][price] = 0;
        }
        else {
            (uint preIndex, uint nextIndex) = priceLocation(direction, price);
            limitOrderPriceListMap[direction][preIndex] = price;
            limitOrderPriceListMap[direction][price] = nextIndex;
        }

        limitOrderPriceArrayLength[direction]++;
    }

    function delPrice(
        uint8 direction,
        uint price)
    internal {//外部调用保证元素存在
        (uint preIndex, uint nextIndex) = priceLocation(direction, price);
        require(price == nextIndex, 'Invalid price');
        limitOrderPriceListMap[direction][preIndex] = limitOrderPriceListMap[direction][nextIndex];
        delete limitOrderPriceListMap[direction][nextIndex];
        limitOrderPriceArrayLength[direction]--;
    }

    function nextPrice(
        uint8 direction,
        uint cur) //从0开始获取下一个价格，next为0时结束
    internal
    returns (uint next) {
        next = limitOrderPriceListMap[direction][cur];
    }
}

contract OrderBook is IOrderBook, OrderQueue, PriceList {
    using SafeMath for uint;

    struct Order {
        address orderOwner;
        address to;
        uint orderId;
        uint price;
        uint amountOffer;
        uint amountRemain;
        uint8 orderType; //1: limitBuy, 2: limitSell
        uint8 orderIndex; //用户订单索引，一个用户最多255
    }

    bytes4 private constant SELECTOR_TRANSFER = bytes4(keccak256(bytes('transfer(address,uint256)')));
    bytes4 private constant SELECTOR_APPROVE = bytes4(keccak256(bytes('approve(address,uint256)')));

    //名称
    string public constant name = 'Uniswap V2 OrderBook';

    //货币对
    address public pair;

    //价格间隔参数-保证价格间隔的设置在一个合理的范围内
    uint priceStep; //priceStep 和 minAmount和修改可以考虑在一定时间内由合约创建者负责修改，一定时间后将维护权自动转交给投票合约及管理员
    //最小数量
    uint minAmount;
    //价格小数点位数
    uint8 priceDecimal;

    //基础货币
    address public baseToken;
    //记价货币
    address public quoteToken;

    uint private baseBalance;
    uint private quoteBalance;

    //未完成总订单，链上不保存已成交的订单(订单id -> Order)
    mapping(uint => Order) public marketOrders;

    //用户订单(用户地址 -> 订单id数组)
    mapping(address => uint[]) public userOrders;

    event OrderCreated(
        address indexed sender,
        address indexed to,
        uint price,
        uint amountOffer,
        uint amountRemain,
        uint8);

    event OrderClosed(
        address indexed sender,
        address indexed to,
        uint price,
        uint amountOffer,
        uint amountUsed,
        uint8);

    event OrderCancelled(
        address indexed sender,
        address indexed to,
        uint price,
        uint amountOffer,
        uint amountRemain,
        uint8);

    constructor() public {
        pair = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(
        address _baseToken,
        address _quoteToken,
        uint _priceStep,
        uint _minAmount)
    external {
        require(msg.sender == pair, 'UniswapV2 OrderBook: FORBIDDEN'); // sufficient check
        require(baseToken != quoteToken, 'UniswapV2 OrderBook: Token Pair Invalid');
        require(_priceStep >= 1, 'UniswapV2 OrderBook: Price Step Invalid');
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        priceStep = _priceStep;
        priceDecimal = IERC20(_quoteToken).decimals();
        minAmount = _minAmount;
        // 允许pair合约使用base/quote余额，swap时需要
        _safeApprove(baseToken, pair, uint(-1));
        _safeApprove(quoteToken, pair, uint(-1));
    }

    // 允许pair合约使用base/quote余额，swap时需要
    function approveAll()
    external {
        _safeApprove(baseToken, pair, uint(-1));
        _safeApprove(quoteToken, pair, uint(-1));
    }

    function _safeTransfer(address token, address to, uint value)
    private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR_TRANSFER, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2 OrderBook: TRANSFER_FAILED');
    }

    function _safeApprove(address token, address to, uint value)
    private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR_APPROVE, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2 OrderBook: APPROVE_FAILED');
    }

    uint8 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2 OrderBook: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    //id生成器
    uint private orderIdGenerator;
    function _generateOrderId()
    private
    returns (uint) {
        orderIdGenerator++;
        return orderIdGenerator;
    }

    function getReserves()
    public
    view
    returns (uint112 reserveBase, uint112 reserveQuote, uint32 blockTimestampLast) {
        (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
        reserveBase = baseToken == IUniswapV2Pair(pair).token0() ? _reserve0 : _reserve1;
        reserveQuote = reserveBase == _reserve0 ? _reserve1 : _reserve0;
        blockTimestampLast = _blockTimestampLast;
    }

    function tradeDirection(address tokenIn, address tokenOut)
    external
    view
    returns (uint8 direction) {
        direction = quoteToken == tokenIn ? 1 : 2;
    }

    //添加order对象
    function _addLimitOrder(
        address user,
        address _to,
        uint _amountOffer,
        uint _amountRemain,
        uint _price,
        uint8 _type)
    private
    returns (uint orderId) {
        uint[] memory _userOrders = userOrders[user];
        require(_userOrders.length <= 0xff, 'UniswapV2 OrderBook: Order Number is exceeded');
        uint8 orderIndex = (uint8)(_userOrders.length);

        Order memory order = Order(
            user,
            _to,
            _generateOrderId(),
            _amountOffer,
            _amountRemain,
            _price,
            _type,
            orderIndex);
        userOrders[user].push(order.orderId);

        marketOrders[order.orderId] = order;
        if (length(_type, _price) == 0) {
            addPrice(_type, _price);
        }

        push(_type, _price, order.orderId);

        return order.orderId;
    }

    //删除order对象
    function _removeLimitOrder(Order memory order) private {
        //删除全局订单
        delete marketOrders[order.orderId];

        //删除用户订单
        uint[] memory _userOrders = userOrders[order.orderOwner];
        require(_userOrders.length > order.orderIndex, 'invalid orderIndex');
        //直接用最后一个元素覆盖当前元素
        if (order.orderIndex != _userOrders.length - 1) {
            _userOrders[order.orderIndex] = _userOrders[_userOrders.length - 1];
        }

        //删除用户订单
        userOrders[order.orderOwner].pop();

        //删除队列订单
        del(order.orderType, order.price, order.orderId);

        //删除价格
        if (length(order.orderType, order.price) == 0){
            delPrice(order.orderType, order.price);
        }
    }

    //订单薄，不关注订单具体信息，只用于查询
    function marketBook(
        uint8 direction,
        uint32 maxSize)
    external
    view
    returns (uint[] memory prices, uint[] memory amounts) {
        uint curPrice = nextPrice(direction, 0);
        uint32 index = 0;
        while(curPrice != 0 && index < maxSize){
            prices[index] = curPrice;
            amounts[index] = listAgg(direction, curPrice);
            curPrice = nextPrice(direction, curPrice);
            index++;
        }
    }

    //市场订单
    function marketOrder(
        uint orderId
    )
    external
    view
    returns (uint[] memory order){
        Order memory o = marketOrders[orderId];
        order[0] = (uint)(o.orderOwner);
        order[1] = (uint)(o.to);
        order[2] = o.orderId;
        order[3] = o.price;
        order[4] = o.amountOffer;
        order[5] = o.amountRemain;
        order[6] = o.orderType;
        order[7] = o.orderIndex;
    }

    //用于遍历所有订单
    function nextOrder(
        uint8 direction,
        uint cur)
    external
    view
    returns (uint next, uint[] memory amounts) {
        next = nextPrice(direction, cur);
        amounts = list(direction, next);
    }

    //用于遍历所有订单薄
    function nextBook(
        uint8 direction,
        uint cur)
    external
    view
    returns (uint next, uint amount) {
        next = nextPrice(direction, cur);
        amount = listAgg(direction, next);
    }

    function _getAmountAndTakePrice(
        uint8 direction,
        uint amountInOffer,
        uint price,
        uint decimal,
        uint amountOutOffer)
    internal
    returns (uint amountIn, uint amountOutWithFee, address[] memory accounts, uint[] memory amounts) {
        if (direction == 1) { //buy (quoteToken == tokenA)  用tokenA（usdc)换tokenB(btc)
            uint amountOut = HybridLibrary.getAmountOutWithPrice(amountInOffer, price, decimal);
            if (amountOut.mul(1000) <= amountOutOffer.mul(997)) { //只吃掉一部分: amountOut > amountOffer * (1-0.3%)
                (amountIn, amountOutWithFee) = (amountInOffer, amountOut);
            }
            else {
                amountOutWithFee = amountOutOffer.mul(997) / 1000;
                amountIn = HybridLibrary.getAmountInWithPrice(amountOutWithFee, price, decimal);
            }
            (accounts, amounts, ) = takeLimitOrder(2, amountOutWithFee, price);
        }
        else if (direction == 2) { //sell (quoteToken == tokenB) 用tokenA(btc)换tokenB(usdc)
            uint amountOut = HybridLibrary.getAmountOutWithPrice(amountInOffer, price, decimal);
            if (amountOut.mul(1000) <= amountOutOffer.mul(997)) { //只吃掉一部分: amountOut > amountOffer * (1-0.3%)
                (amountIn, amountOutWithFee) = (amountInOffer, amountOut);
            }
            else {
                amountOutWithFee = amountOutOffer.mul(997) / 1000;
                amountIn = HybridLibrary.getAmountInWithPrice(amountOutWithFee, price, decimal);
            }
            (accounts, amounts, ) = takeLimitOrder(1, amountIn, price);
        }
    }

    function getAmountAndTakePrice(
        uint8 direction,
        uint amountInOffer,
        uint price,
        uint decimal,
        uint amountOutOffer)
    external
    returns (uint amountIn, uint amountOutWithFee, address[] memory accounts, uint[] memory amounts) {
        (amountIn, amountOutWithFee, accounts, amounts) =
        _getAmountAndTakePrice(direction, amountInOffer, price, decimal, amountOutOffer);
    }

    //使用特定数量的token将价格向上移动到特定值--具体执行放到UniswapV2Pair里面, 在这里需要考虑当前价格到目标价格之间的挂单，amm中的分段只用于计算，实际交易整体完成，不分段
    function _movePriceUp(
        uint amountOffer,
        uint _targetPrice,
        address to)
    private
    returns (uint amountLeft) {
        (uint reserveOut, uint reserveIn,) = getReserves();
        amountLeft = amountOffer;
        uint amountInUsed;
        uint amountOutUsed;
        uint amountAmmIn;
        uint amountAmmOut;
        uint8 direction = 2; //获取反方向的挂单

        uint price = nextPrice(direction, 0);
        uint amount = price != 0 ? listAgg(direction, price) : 0;
        while(price != 0 && price <= _targetPrice) {
            //先计算pair从当前价格到price消耗amountIn的数量
            (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(
                direction,
                reserveIn,
                reserveOut,
                price,
                priceDecimal);
            //再计算amm中实际会消耗的amountIn的数量
            amountAmmIn += amountInUsed > amountLeft ? amountLeft : amountInUsed;
            //再计算本次移动价格获得的amountOut
            amountAmmOut += amountInUsed > amountLeft ? UniswapV2Library.getAmountOut(amountLeft, reserveIn, reserveOut)
            : amountOutUsed;
            //再计算还剩下的amountIn
            amountLeft = amountInUsed < amountLeft ? amountLeft - amountInUsed : 0;
            if (amountLeft == 0) {
                break;
            }

            //消耗掉一个价格的挂单并返回实际需要的amountIn数量
            (uint amountInForTake, uint amountOutWithFee, address[] memory accounts, uint[] memory amounts) =
            _getAmountAndTakePrice(direction, amountLeft, price, priceDecimal, amount);
            //给对应数量的tokenIn发送给对应的账号
            for(uint i=0; i<accounts.length; i++) {
                _safeTransfer(quoteToken, accounts[i], amounts[i]);
            }

            amountLeft = amountInForTake < amountLeft ? amountLeft - amountInForTake : 0;
            if (amountLeft == 0) { //amountIn消耗完了
                break;
            }

            price = nextPrice(direction, price);
            amount = price != 0 ? listAgg(direction, price) : 0;
        }

        if (price < _targetPrice && amountLeft > 0){//处理挂单之外的价格范围
            (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(direction,
                reserveIn, reserveOut, _targetPrice, priceDecimal);
            //再计算amm中实际会消耗的amountIn的数量
            amountAmmIn += amountInUsed > amountLeft ? amountLeft : amountInUsed;
            //再计算本次移动价格获得的amountOut
            amountAmmOut += amountInUsed > amountLeft ? UniswapV2Library.getAmountOut(amountLeft, reserveIn, reserveOut)
            : amountOutUsed;
            amountLeft = amountInUsed < amountLeft ? amountLeft - amountInUsed : 0;
        }

        //向pair转账
        require(IERC20(quoteToken).allowance(address(this), pair) > amountAmmIn, 'UniswapV2 OrderBook: transfer amount exceeds spender allowance');
        _safeTransfer(quoteToken, pair, amountAmmIn);

        {//将当前价格移动到目标价格并最多消耗amountLeft
            (uint amount0Out, uint amount1Out) = baseToken == IUniswapV2Pair(pair).token0() ? (uint(0), amountAmmOut) : (amountAmmOut, uint(0));
            IUniswapV2Pair(pair).swapOriginal(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    //使用特定数量的token将价格向上移动到特定值--具体执行放到UniswapV2Pair里面, 在这里需要考虑当前价格到目标价格之间的挂单
    function _movePriceDown(
        uint amountOffer,
        uint _targetPrice,
        address to)
    private
    returns (uint amountLeft) {
        (uint reserveIn, uint reserveOut,) = getReserves();
        amountLeft = amountOffer;
        uint amountInUsed;
        uint amountOutUsed;
        uint amountAmmIn;
        uint amountAmmOut;

        uint8 direction = 1; //获取反方向的挂单
        uint price = nextPrice(direction, 0);
        uint amount = price != 0 ? listAgg(direction, price) : 0;
        while(price <= _targetPrice) {
            //先计算pair从当前价格到price消耗amountIn的数量
            (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(
                direction,
                reserveIn,
                reserveOut,
                price,
                priceDecimal);
            //再计算本次移动价格获得的amountOut
            amountAmmOut += amountInUsed > amountLeft ? UniswapV2Library.getAmountOut(amountLeft, reserveIn, reserveOut)
            : amountOutUsed;
            //再计算amm中实际会消耗的amountIn的数量
            amountAmmIn += amountInUsed > amountLeft ? amountLeft : amountInUsed;
            //再计算还剩下的amountIn
            amountLeft = amountInUsed < amountLeft ? amountLeft - amountInUsed : 0;
            if (amountLeft == 0) {
                break;
            }

            //消耗掉一个价格的挂单并返回实际需要的amountIn数量
            (uint amountInForTake, uint amountOutWithFee, address[] memory accounts, uint[] memory amounts) =
            _getAmountAndTakePrice(direction, amountLeft, price, priceDecimal, amount);
            //给对应数量的tokenIn发送给对应的账号
            for(uint i=0; i<accounts.length; i++) {
                _safeTransfer(baseToken, accounts[i], amounts[i]);
            }

            amountLeft = amountInForTake < amountLeft ? amountLeft - amountInForTake : 0;
            if (amountLeft == 0) { //amountIn消耗完了
                break;
            }

            price = nextPrice(direction, price);
            amount = price != 0 ? listAgg(direction, price) : 0;
        }

        if (price < _targetPrice && amountLeft > 0){//处理挂单之外的价格范围
            (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(direction,
                reserveIn, reserveOut, _targetPrice, priceDecimal);
            //再计算amm中实际会消耗的amountIn的数量
            amountAmmIn += amountInUsed > amountLeft ? amountLeft : amountInUsed;
            //再计算本次移动价格获得的amountOut
            amountAmmOut += amountInUsed > amountLeft ? UniswapV2Library.getAmountOut(amountLeft, reserveIn, reserveOut)
            : amountOutUsed;
            amountLeft = amountInUsed < amountLeft ? amountLeft - amountInUsed : 0;
        }

        //向pair转账
        require(IERC20(baseToken).allowance(address(this), pair) > amountAmmIn,
        'UniswapV2 OrderBook: transfer amount exceeds spender allowance');
        _safeTransfer(baseToken, pair, amountAmmIn);

        {//将当前价格移动到目标价格并最多消耗amountLeft
            (uint amount0Out, uint amount1Out) = quoteToken == IUniswapV2Pair(pair).token0() ? (uint(0), amountAmmOut) :
                (amountAmmOut, uint(0));
            IUniswapV2Pair(pair).swapOriginal(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    //创建限价买订单
    function createBuyLimitOrder(
        address user,
        uint amountOffer,
        uint price,
        address to)
    external
    lock
    returns (uint orderId) {
        require(amountOffer >= minAmount, 'UniswapV2 OrderBook: Amount Invalid');
        require(price > 0 && price % priceStep == 0, 'UniswapV2 OrderBook: Price Invalid');

        //需要先将token转移到order book合约(在router中执行), 以免与pair中的token混合
        uint balance = IERC20(quoteToken).balanceOf(address(this));
        require(amountOffer > balance - quoteBalance);
        //更新quote余额
        quoteBalance = balance;

        //先在流动性池将价格拉到挂单价，同时还需要吃掉价格范围内的反方向挂单
        uint amountRemain = _movePriceUp(amountOffer, price, to);
        if (amountRemain != 0) {
            //未成交的部分生成限价买单
            orderId = _addLimitOrder(user, to, amountOffer, amountRemain, price, 1);
            //产生订单创建事件
            emit OrderCreated(user, to, price, amountOffer, amountRemain, 1);
        }
        //如果完全成交则在成交过程中直接产生订单创建事件和订单成交事件,链上不保存订单历史数据
    }

    //创建限价卖订单
    function createSellLimitOrder(
        address user,
        uint amountOffer,
        uint price,
        address to)
    external
    lock
    returns (uint orderId) {
        require(amountOffer >= minAmount, 'UniswapV2 OrderBook: Amount Invalid');
        require(price > 0 && price % priceStep == 0, 'UniswapV2 OrderBook: Price Invalid');

        //需要将token转移到order book合约, 以免与pair中的token混合

        //先在流动性池将价格拉到挂单价，同时还需要吃掉价格范围内的反方向挂单
        uint amountRemain = _movePriceDown(amountOffer, price, to);
        if (amountRemain != 0){
            //未成交的部分生成限价买单
            orderId = _addLimitOrder(user, to, amountOffer, amountRemain, price, 2);
            //产生订单创建事件
            emit OrderCreated(user, to, price, amountOffer, amountRemain, 2);
        }
    }

    function takeLimitOrder(
        uint8 direction,
        uint amount,
        uint price)
    internal
    returns (address[] memory accounts, uint[] memory amounts, uint amountUsed) {
        uint amountLeft = amount;
        uint index;
        while(length(direction, price) > 0 && amountLeft > 0){
            uint orderId = pop(direction, price);
            Order memory order = marketOrders[orderId];
            require(orderId == order.orderId && order.orderType == 1 && price == order.price,
                'UniswapV2 OrderBook: Order Invalid');
            accounts[index] = order.to;
            amounts[index] = amountLeft > order.amountRemain ? order.amountRemain : amountLeft;
            order.amountRemain = order.amountRemain - amounts[index];
            //触发订单交易事件

            //如果还有剩余，将剩余部分入队列，交易结束
            if (order.amountRemain != 0){
                push(direction, price, order.orderId);
                break;
            }

            //删除订单
            delete marketOrders[orderId];

            //删除用户订单
            uint userOrderSize = userOrders[order.orderOwner].length;
            require(userOrderSize > order.orderIndex);
            //直接用最后一个元素覆盖当前元素
            userOrders[order.orderOwner][order.orderIndex] = userOrders[order.orderOwner][userOrderSize - 1];
            userOrders[order.orderOwner].length--;

            amountLeft = amountLeft - amounts[index++];
        }

        amountUsed = amount - amountLeft;
    }

    //take buy limit order
    function takeBuyLimitOrder(
        uint amount,
        uint price)
    external
    lock
    returns (address[] memory accounts, uint[] memory amounts, uint amountUsed) {
        (accounts, amounts, amountUsed) = takeLimitOrder(1, amount, price);
        //向pair合约转账amountTake
    }

    //take sell limit order
    function takeSellLimitOrder(
        uint amount,
        uint price)
    public
    lock
    returns (address[] memory accounts, uint[] memory amounts, uint amountUsed){
        (accounts, amounts, amountUsed) = takeLimitOrder(2, amount, price);
        //向pair合约转账amountTake
    }

    //更新价格间隔
    function priceStepUpdate(uint newPriceStep) external {
        priceStep = newPriceStep;
    }

    //更新最小数量
    function minAmountUpdate(uint newMinAmount) external {
        minAmount = newMinAmount;
    }
}
