pragma solidity =0.5.16;

import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IOrderBook.sol";
import './libraries/TransferHelper.sol';
import "./libraries/UniswapV2Library.sol";
import "./OrderQueue.sol";
import "./PriceList.sol";

contract OrderBook is OrderQueue, PriceList {
    using SafeMath for uint;

    struct Order {
        address orderOwner;
        address to;
        uint orderId;
        uint price;
        uint amountOffer;
        uint amountRemain;
        uint orderType; //1: limitBuy, 2: limitSell
        uint orderIndex; //用户订单索引，一个用户最多255
    }

    bytes4 private constant SELECTOR_TRANSFER = bytes4(keccak256(bytes('transfer(address,uint256)')));
    bytes4 private constant SELECTOR_APPROVE = bytes4(keccak256(bytes('approve(address,uint256)')));
    uint private constant LIMIT_BUY = 1;
    uint private constant LIMIT_SELL = 2;

    //名称
    string public constant name = 'Uniswap V2 OrderBook';

    //order book factory
    address public factory;

    //货币对
    address public pair;

    //价格间隔参数-保证价格间隔的设置在一个合理的范围内
    uint public priceStep; //priceStep 和 minAmount和修改可以考虑在一定时间内由合约创建者负责修改，一定时间后将维护权自动转交给投票合约及管理员
    //最小数量
    uint public minAmount;
    //价格小数点位数
    uint public priceDecimal;

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
        address indexed owner,
        address indexed to,
        uint price,
        uint amountOffer,
        uint amountRemain,
        uint);

    event OrderClosed(
        address indexed sender,
        address indexed owner,
        address indexed to,
        uint price,
        uint amountOffer,
        uint amountUsed,
        uint);

    event OrderCanceled(
        address indexed sender,
        address indexed owner,
        address indexed to,
        uint price,
        uint amountOffer,
        uint amountRemain,
        uint);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(
        address _pair,
        address _baseToken,
        address _quoteToken,
        uint _priceStep,
        uint _minAmount)
    external {
        require(msg.sender == factory, 'UniswapV2 OrderBook: FORBIDDEN'); // sufficient check
        require(_priceStep >= 1, 'UniswapV2 OrderBook: Price Step Invalid');
        require(_minAmount >= 1, 'UniswapV2 OrderBook: Min Amount Invalid');
        (address token0, address token1) = (IUniswapV2Pair(_pair).token0(), IUniswapV2Pair(_pair).token1());
        require(
            (token0 == _baseToken && token1 == _quoteToken) &&
            (token1 == _baseToken && token0 == _quoteToken),
            'UniswapV2 OrderBook: Token Pair Invalid');

        pair = _pair;
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        priceStep = _priceStep;
        priceDecimal = IERC20(_quoteToken).decimals();
        minAmount = _minAmount;
        //允许pair合约使用base/quote余额，swap时需要
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

    uint private unlocked = 1;
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

    function tradeDirection(address tokenIn)
    external
    view
    returns (uint direction) {
        direction = quoteToken == tokenIn ? 1 : 2;
    }

    function _updateBalance()
        private
    {
        baseBalance = IERC20(baseToken).balanceOf(address(this));
        quoteBalance = IERC20(quoteToken).balanceOf(address(this));
    }

    //添加order对象
    function _addLimitOrder(
        address user,
        address _to,
        uint _amountOffer,
        uint _amountRemain,
        uint _price,
        uint _type)
    private
    returns (uint orderId) {
        uint[] memory _userOrders = userOrders[user];
        require(_userOrders.length < 0xff, 'UniswapV2 OrderBook: Order Number is exceeded');
        uint orderIndex = _userOrders.length;

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

    // list
    function list(
        uint direction,
        uint price)
    internal
    view
    returns (uint[] memory allData) {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        if (front < rear){
            allData = new uint[](rear - front);
            for (uint i=front; i<rear; i++) {
                allData[i-front] = marketOrders[limitOrderQueueMap[direction][price][i]].amountRemain;
            }
        }
    }

    // listAgg
    function listAgg(
        uint direction,
        uint price)
    internal
    view
    returns (uint dataAgg) {
        uint front = limitOrderQueueFront[direction][price];
        uint rear = limitOrderQueueRear[direction][price];
        for (uint i=front; i<rear; i++){
            dataAgg += marketOrders[limitOrderQueueMap[direction][price][i]].amountRemain;
        }
    }

    //订单薄，不关注订单具体信息，只用于查询
    function marketBook(
        uint direction,
        uint32 maxSize)
    external
    view
    returns (uint[] memory prices, uint[] memory amounts) {
        uint priceLength = priceLength(direction);
        priceLength =  priceLength > maxSize ? maxSize : priceLength;
        prices = new uint[](priceLength);
        amounts = new uint[](priceLength);
        uint curPrice = nextPrice(direction, 0);
        uint32 index = 0;
        while(curPrice != 0 && index < priceLength){
            prices[index] = curPrice;
            amounts[index] = listAgg(direction, curPrice);
            curPrice = nextPrice(direction, curPrice);
            index++;
        }
    }

    //获取某个价格内的订单薄
    function rangeBook(uint direction, uint price)
    external
    view
    returns (uint[] memory prices, uint[] memory amounts){
        uint priceLength = priceLength(direction);
        prices = new uint[](priceLength);
        amounts = new uint[](priceLength);
        uint curPrice = nextPrice(direction, 0);
        uint32 index = 0;
        while(curPrice != 0 && curPrice <= price){
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
        order = new uint[](8);
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
        uint direction,
        uint cur)
    internal
    view
    returns (uint next, uint[] memory amounts) {
        next = nextPrice(direction, cur);
        amounts = list(direction, next);
    }

    //用于遍历所有订单薄
    function nextBook(
        uint direction,
        uint cur)
    external
    view
    returns (uint next, uint amount) {
        next = nextPrice(direction, cur);
        amount = listAgg(direction, next);
    }

    function _getAmountAndTakePrice(
        uint direction,
        uint amountInOffer,
        uint price,
        uint decimal,
        uint orderAmount)
    internal
    returns (uint amountIn, uint amountOutWithFee, address[] memory accounts, uint[] memory amounts) {
        if (direction == 1) { //buy (quoteToken == tokenIn)  用tokenIn（usdc)换tokenOut(btc)
            //amountOut = amountInOffer / price
            uint amountOut = HybridLibrary.getAmountInWithPrice(amountInOffer, price, decimal);
            if (amountOut.mul(1000) <= orderAmount.mul(997)) { //只吃掉一部分: amountOut > amountOffer * (1-0.3%)
                (amountIn, amountOutWithFee) = (amountInOffer, amountOut);
            }
            else {
                uint amountOutWithoutFee = orderAmount.mul(997) / 1000;//吃掉所有
                //amountIn = amountOutWithoutFee * price
                (amountIn, amountOutWithFee) = (HybridLibrary.getAmountOutWithPrice(amountOutWithoutFee, price, decimal),
                    orderAmount);
            }
            (accounts, amounts, ) = takeLimitOrder(2, amountOutWithFee, price);
        }
        else if (direction == 2) { //sell (quoteToken == tokenOut) 用tokenIn(btc)换tokenOut(usdc)
            //amountOut = amountInOffer * price
            uint amountOut = HybridLibrary.getAmountInWithPrice(amountInOffer, price, decimal);
            if (amountOut.mul(1000) <= orderAmount.mul(997)) { //只吃掉一部分: amountOut > amountOffer * (1-0.3%)
                (amountIn, amountOutWithFee) = (amountInOffer, amountOut);
            }
            else {
                uint amountOutWithoutFee = orderAmount.mul(997) / 1000;
                //amountIn = amountOutWithoutFee / price
                (amountIn, amountOutWithFee) = (HybridLibrary.getAmountOutWithPrice(amountOutWithoutFee, price,
                    decimal), orderAmount);
            }
            (accounts, amounts, ) = takeLimitOrder(1, amountIn, price);
        }
    }

    function getAmountAndTakePrice(
        uint direction,
        uint amountInOffer,
        uint price,
        uint decimal,
        uint orderAmount)
    external
    returns (uint amountIn, uint amountOutWithFee, address[] memory accounts, uint[] memory amounts) {
        //先吃单再付款，需要保证只有pair可以调用
        require(msg.sender == pair, 'invalid sender');
        (amountIn, amountOutWithFee, accounts, amounts) =
        _getAmountAndTakePrice(direction, amountInOffer, price, decimal, orderAmount); //当token为weth时，外部调用的时候直接将weth转出
    }

    //使用特定数量的token将价格向上移动到特定值--具体执行放到UniswapV2Pair里面, 在这里需要考虑当前价格到目标价格之间的挂单，amm中的分段只用于计算，实际交易一次性完成，不分段
    function _movePriceUp(
        uint amountOffer,
        uint targetPrice,
        address to)
    private
    returns (uint amountLeft) {
        (uint reserveOut, uint reserveIn,) = getReserves();
        amountLeft = amountOffer;
        uint amountInUsed;
        uint amountOut;
        uint amountAmmIn;
        uint amountAmmOut;

        uint price = nextPrice(LIMIT_SELL, 0);
        uint amount = price != 0 ? listAgg(LIMIT_SELL, price) : 0;
        while(price != 0 && price <= targetPrice) {
            //先计算pair从当前价格到price消耗amountIn的数量
            uint amountOutUsed;
            (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(
                LIMIT_BUY,
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
            _getAmountAndTakePrice(LIMIT_SELL, amountLeft, price, priceDecimal, amount);
            amountOut += amountOutWithFee;
            //给对应数量的tokenIn发送给对应的账号
            for(uint i=0; i<accounts.length; i++) {//当token为weth时，需要将weth转为eth转给用户
                _safeTransfer(quoteToken, accounts[i], amounts[i]);
            }

            amountLeft = amountInForTake < amountLeft ? amountLeft - amountInForTake : 0;
            if (amountLeft == 0) { //amountIn消耗完了
                break;
            }

            price = nextPrice(LIMIT_SELL, price);
            amount = price != 0 ? listAgg(LIMIT_SELL, price) : 0;
        }

        // 一次性将吃单获得的数量转给用户
        if (amountOut > 0){
            _safeTransfer(baseToken, to, amountOut);
        }

        if (price < targetPrice && amountLeft > 0){//处理挂单之外的价格范围
            uint amountOutUsed;
            (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice
            (LIMIT_BUY, reserveIn, reserveOut, targetPrice, priceDecimal);
            //再计算amm中实际会消耗的amountIn的数量
            amountAmmIn += amountInUsed > amountLeft ? amountLeft : amountInUsed;
            //再计算本次移动价格获得的amountOut
            amountAmmOut += amountInUsed > amountLeft ? UniswapV2Library.getAmountOut(amountLeft, reserveIn, reserveOut)
            : amountOutUsed;
            amountLeft = amountInUsed < amountLeft ? amountLeft - amountInUsed : 0;
        }

        if (amountAmmIn > 0) {//向pair转账
            require(IERC20(quoteToken).allowance(address(this), pair) > amountAmmIn, 'UniswapV2 OrderBook: transfer amount exceeds spender allowance');
            _safeTransfer(quoteToken, pair, amountAmmIn);

            {//将当前价格移动到目标价格并最多消耗amountLeft
                (uint amount0Out, uint amount1Out) = baseToken == IUniswapV2Pair(pair).token0() ? (uint(0), amountAmmOut) : (amountAmmOut, uint(0));
                IUniswapV2Pair(pair).swapOriginal(amount0Out, amount1Out, to, new bytes(0));
            }
        }
    }

    //使用特定数量的token将价格向上移动到特定值--具体执行放到UniswapV2Pair里面, 在这里需要考虑当前价格到目标价格之间的挂单
    function _movePriceDown(
        uint amountOffer,
        uint targetPrice,
        address to)
    private
    returns (uint amountLeft) {
        (uint reserveIn, uint reserveOut,) = getReserves();
        amountLeft = amountOffer;
        uint amountInUsed;
        uint amountOut;
        uint amountAmmIn;
        uint amountAmmOut;

        uint price = nextPrice(LIMIT_BUY, 0);
        uint amount = price != 0 ? listAgg(LIMIT_BUY, price) : 0;
        while(price <= targetPrice) {
            //先计算pair从当前价格到price消耗amountIn的数量
            uint amountOutUsed;
            (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(
                LIMIT_SELL,
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
            _getAmountAndTakePrice(LIMIT_BUY, amountLeft, price, priceDecimal, amount);
            amountOut += amountOutWithFee;
            //给对应数量的tokenIn发送给对应的账号
            for(uint i=0; i<accounts.length; i++) {
                _safeTransfer(baseToken, accounts[i], amounts[i]);
            }

            amountLeft = amountInForTake < amountLeft ? amountLeft - amountInForTake : 0;
            if (amountLeft == 0) { //amountIn消耗完了
                break;
            }

            price = nextPrice(LIMIT_BUY, price);
            amount = price != 0 ? listAgg(LIMIT_BUY, price) : 0;
        }

        if (amountOut > 0){
            _safeTransfer(quoteToken, to, amountOut);
        }

        if (price < targetPrice && amountLeft > 0){//处理挂单之外的价格范围
            uint amountOutUsed;
            (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice(LIMIT_SELL,
                reserveIn, reserveOut, targetPrice, priceDecimal);
            //再计算amm中实际会消耗的amountIn的数量
            amountAmmIn += amountInUsed > amountLeft ? amountLeft : amountInUsed;
            //再计算本次移动价格获得的amountOut
            amountAmmOut += amountInUsed > amountLeft ? UniswapV2Library.getAmountOut(amountLeft, reserveIn, reserveOut)
            : amountOutUsed;
            amountLeft = amountInUsed < amountLeft ? amountLeft - amountInUsed : 0;
        }

        if (amountAmmIn > 0){//向pair转账
            require(IERC20(baseToken).allowance(address(this), pair) > amountAmmIn,
                'UniswapV2 OrderBook: transfer amount exceeds spender allowance');
            _safeTransfer(baseToken, pair, amountAmmIn);

            {//将当前价格移动到目标价格并最多消耗amountLeft
                (uint amount0Out, uint amount1Out) = quoteToken == IUniswapV2Pair(pair).token0() ? (uint(0), amountAmmOut) :
            (amountAmmOut, uint(0));
                IUniswapV2Pair(pair).swapOriginal(amount0Out, amount1Out, to, new bytes(0));
            }
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
        require(amountOffer >= balance - quoteBalance);
        //更新quote余额
        quoteBalance = balance;

        //先在流动性池将价格拉到挂单价，同时还需要吃掉价格范围内的反方向挂单
        uint amountRemain = _movePriceUp(amountOffer, price, to);
        if (amountRemain != 0) {
            //未成交的部分生成限价买单
            orderId = _addLimitOrder(user, to, amountOffer, amountRemain, price, 1);
            //产生订单创建事件
            emit OrderCreated(user, user, to, price, amountOffer, amountRemain, 1);
        }
        //如果完全成交则在成交过程中直接产生订单创建事件和订单成交事件,链上不保存订单历史数据

        //更新余额
        if (amountRemain != amountOffer){
            _updateBalance();
        }
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
        uint balance = IERC20(baseToken).balanceOf(address(this));
        require(amountOffer >= balance - baseBalance);
        //更新quote余额
        baseBalance = balance;

        //先在流动性池将价格拉到挂单价，同时还需要吃掉价格范围内的反方向挂单
        uint amountRemain = _movePriceDown(amountOffer, price, to);
        if (amountRemain != 0) {
            //未成交的部分生成限价买单
            orderId = _addLimitOrder(user, to, amountOffer, amountRemain, price, 2);
            //产生订单创建事件
            emit OrderCreated(user, user, to, price, amountOffer, amountRemain, 2);
        }

        //更新余额
        if (amountRemain != amountOffer){
            _updateBalance();
        }
    }

    function cancelLimitOrder(uint orderId) external lock {
        Order memory o = marketOrders[orderId];
        _removeLimitOrder(o);

        address token = o.orderType == 1 ? quoteToken : baseToken;
        address WETH = IOrderBookFactory(factory).WETH();
        //退款
        if (WETH == token) {
            IWETH(WETH).withdraw(o.amountRemain);
            TransferHelper.safeTransferETH(o.to, o.amountRemain);
        }
        else {
            _safeTransfer(token, o.to, o.amountRemain);
        }

        //更新token余额
        uint balance = IERC20(token).balanceOf(address(this));
        if (o.orderType == 1) quoteBalance = balance;
        else baseBalance = balance;

        emit OrderCanceled(msg.sender, o.orderOwner, o.to, o.price, o.amountOffer, o.amountRemain, o.orderType);
    }

    //由pair的swap接口调用
    function takeLimitOrder(
        uint direction,
        uint amount,
        uint price)
    internal
    returns (address[] memory accounts, uint[] memory amounts, uint amountUsed) {
        uint amountLeft = amount;
        uint index;
        uint length = length(direction, price);
        accounts = new address[](length);
        amounts = new uint[](length);
        while(index < length && amountLeft > 0){
            uint orderId = pop(direction, price);
            Order memory order = marketOrders[orderId];
            require(orderId == order.orderId && order.orderType == 1 && price == order.price,
                'UniswapV2 OrderBook: Order Invalid');
            accounts[index] = order.to;
            amounts[index] = amountLeft > order.amountRemain ? order.amountRemain : amountLeft;
            order.amountRemain = order.amountRemain - amounts[index];
            //触发订单交易事件
            emit OrderClosed(msg.sender, order.orderOwner, order.to, order.price, order.amountOffer, order
                .amountRemain, order.orderType);

            //如果还有剩余，将剩余部分入队列，交易结束
            if (order.amountRemain != 0) {
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
            //删除最后元素
            userOrders[order.orderOwner].pop();

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
        //向pair合约转账amountUsed的baseToken
        _safeTransfer(baseToken, pair, amountUsed);
    }

    //take sell limit order
    function takeSellLimitOrder(
        uint amount,
        uint price)
    public
    lock
    returns (address[] memory accounts, uint[] memory amounts, uint amountUsed){
        (accounts, amounts, amountUsed) = takeLimitOrder(2, amount, price);
        //向pair合约转账amountUsed
        _safeTransfer(quoteToken, pair, amountUsed);
    }

    //更新价格间隔
    function priceStepUpdate(uint newPriceStep) external lock {
        priceStep = newPriceStep;
    }

    //更新最小数量
    function minAmountUpdate(uint newMinAmount) external lock {
        minAmount = newMinAmount;
    }
}
