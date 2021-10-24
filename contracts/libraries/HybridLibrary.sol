pragma solidity >=0.5.0;

import "../interfaces/IOrderBook.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IUniswapV2Factory.sol";
import "./SafeMath.sol";

import "./UniswapV2Library.sol";

library HybridLibrary {
    using SafeMath for uint;

    //根据价格计算使用amountIn换出的amountOut的数量
    function getAmountOutWithPrice(uint amountIn, uint price, uint decimal) internal pure returns (uint amountOut){
        amountOut = amountIn.mul(price) / 10 ** decimal;
    }

    //根据价格计算换出的amountOut需要使用amountIn的数量
    function getAmountInWithPrice(uint amountOut, uint price, uint decimal) internal pure returns (uint amountIn){
        amountIn = amountOut.mul(10 ** decimal) / price;
    }

    // fetches market order book for a pair for swap tokenA to takenB
    function getOrderBook(address factory, address tokenA, address tokenB) internal view returns (address orderBook) {
        address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        if (pair != address(0)) {
            orderBook = IUniswapV2Pair(pair).orderBook();
        }
    }

    function getTradeDirection(address orderBook, address tokenA, address tokenB) internal view returns(uint direction) {
        if (orderBook != address(0)) {
            //如果tokenA是计价token, 则表示买, 反之则表示卖
            direction = IOrderBook(orderBook).tradeDirection(tokenA, tokenB);
        }
    }

    function getPriceDecimal(address orderBook, address tokenA, address tokenB) internal view returns (uint decimal) {
        if (orderBook != address(0)) {
            decimal = IOrderBook(orderBook).priceDecimal(tokenA, tokenB);
        }
    }

    // fetches market order book for a pair for swap tokenA to takenB
    function getMarketOrder(address orderBook, uint orderDirection) internal view returns (uint[] memory prices, uint[] memory amounts) {
        if (orderBook != address(0)) {
            (prices, amounts) = IOrderBook(orderBook).marketOrder(orderDirection);
        }
    }

    //将价格移动到price需要消息的tokenA的数量, 以及新的reserveIn, reserveOut
    function getAmountForMovePrice(uint direction, uint reserveIn, uint reserveOut, uint price, uint decimal)
    internal pure returns (uint amountIn, uint reserveInNew, uint reserveOutNew) {
        (uint baseReserve, uint quoteReserve) = (reserveIn, reserveOut);
        if (direction == 1) {//buy (quoteToken == tokenA)  用tokenA换tokenB
            (baseReserve, quoteReserve) = (reserveOut, reserveIn);
            //根据p = y + (1-0.3%) * y' / (1-0.3%) * x 推出 997 * y' = (997 * x * p - 1000 * y), 如果等于0表示不需要移动价格
            //先计算997 * x * p
            uint b1 = getAmountOutWithPrice(baseReserve.mul(997), price, decimal);
            //再计算1000 * y
            uint q1 = quoteReserve.mul(1000);
            //再计算y' = (997 * x * p - 1000 * y) / 997
            amountIn = b1 > q1 ? (b1 - q1) / 997 : 0;
            //再计算x'
            uint amountOut = amountIn != 0 ? UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut) : 0;
            //再更新reserveInNew = reserveIn - x', reserveOutNew = reserveOut + y'
            (reserveInNew, reserveOutNew) = (reserveIn + amountIn, reserveOut - amountOut);
        }
        else if (direction == 2) {//sell(quoteToken == tokenB) 用tokenA换tokenB
            //根据p = x + (1-0.3%) * x' / (1-0.3%) * y 推出 997 * x' = (997 * y * p - 1000 * x), 如果等于0表示不需要移动价格
            //先计算 y * p * 997
            uint q1 = getAmountOutWithPrice(quoteReserve.mul(997), price, decimal);
            //再计算 x * 1000
            uint b1 = baseReserve.mul(1000);
            //再计算x' = (997 * y * p - 1000 * x) / 997
            amountIn = q1 > b1 ? (q1 - b1) / 997 : 0;
            //再计算y' = (1-0.3%) x' / p
            uint amountOut = amountIn != 0 ? UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut) : 0;
            //再更新reserveInNew = reserveIn + x', reserveOutNew = reserveOut - y'
            (reserveInNew, reserveOutNew) = (reserveIn + amountIn, reserveOut - amountOut);
        }
        else {
            (amountIn, reserveInNew, reserveOutNew) = (0, reserveIn, reserveOut);
        }
    }

    //使用amountA数量的amountInOffer吃掉在价格price, 数量为amountOutOffer的tokenB, 返回实际消耗的tokenA数量和返回的tokenB的数量，amountOffer需要考虑手续费
    //手续费应该包含在amountOutWithFee中
    function getAmountForTakePrice(uint direction, uint amountInOffer, uint price, uint decimal, uint amountOutOffer)
    internal pure returns (uint amountIn, uint amountOutWithFee) {
        if (direction == 1) { //buy (quoteToken == tokenA)  用tokenA（usdc)换tokenB(btc)
            uint amountOut = getAmountOutWithPrice(amountInOffer, price, decimal);
            if (amountOut.mul(1000) <= amountOutOffer.mul(997)) { //只吃掉一部分: amountOut > amountOffer * (1-0.3%)
                (amountIn, amountOutWithFee) = (amountInOffer, amountOut);
            }
            else {
                amountOutWithFee = amountOutOffer.mul(997) / 1000;
                amountIn = getAmountInWithPrice(amountOutWithFee, price, decimal);
            }
        }
        else if (direction == 2) { //sell (quoteToken == tokenB) 用tokenA(btc)换tokenB(usdc)
            uint amountOut = getAmountOutWithPrice(amountInOffer, price, decimal);
            if (amountOut.mul(1000) <= amountOutOffer.mul(997)) { //只吃掉一部分: amountOut > amountOffer * (1-0.3%)
                (amountIn, amountOutWithFee) = (amountInOffer, amountOut);
            }
            else {
                amountOutWithFee = amountOutOffer.mul(997) / 1000;
                amountIn = getAmountInWithPrice(amountOutWithFee, price, decimal);
            }
        }
    }

    //提供amountIn数量的挂单，成交后会得到多少amountOut，包含手续费
    function getAmountForOfferPrice(uint amountIn, uint price, uint decimal)
    internal pure returns (uint amountOutWithFee) {
        uint amountInExcludeFee = amountIn.mul(997) / 1000;
        amountOutWithFee = getAmountOutWithPrice(amountInExcludeFee, price, decimal);
    }

    //需要考虑初始价格到目标价格之间还有其它挂单的情况，需要考虑最小数量
    function getAmountOutForBuy(address factory, uint amountOffer, uint price, address baseToken, address quoteToken) external view
    returns (uint[] memory amounts) {
        require(baseToken != quoteToken, 'HybridRouter: Invalid_Path');
        address orderBook = getOrderBook(factory, baseToken, quoteToken);
        require(orderBook != address(0), 'HybridRouter: Invalid_OrderBook');
        require(baseToken == IOrderBook(orderBook).baseToken(), 'HybridRouter: MisOrder_Path');

        //获取价格范围内的反方向挂单
        (uint[] memory priceArray, uint[] memory amountArray) = IOrderBook(orderBook).marketRangeOrder(2, price);
        (uint reserveIn, uint reserveOut) = UniswapV2Library.getReserves(factory, baseToken, quoteToken);
        uint decimal = getPriceDecimal(orderBook, quoteToken, baseToken);
        uint amountLeft = amountOffer;

        //看看是否需要吃单
        for (uint i=0; i<priceArray.length; i++){
            uint amountUsed;
            //先计算pair从当前价格到price[j]消耗amountIn的数量
            (amountUsed, reserveIn, reserveOut) = getAmountForMovePrice(1, reserveIn, reserveOut, priceArray[i], decimal);
            //再计算amm中实际会消耗的amountIn的数量
            amounts[0] += amountUsed > amountLeft ? amountLeft : amountUsed;
            //再计算本次移动价格获得的amountOut
            amounts[1] += amountUsed > amountLeft ? UniswapV2Library.getAmountOut(amountLeft, reserveIn, reserveOut) : UniswapV2Library.getAmountOut
            (amountUsed, reserveIn, reserveOut);
            //再计算还剩下的amountIn
            amountLeft = amountUsed < amountLeft ? amountLeft - amountUsed : 0;
            if (amountLeft == 0) {
                break;
            }

            (uint amountInForTake,) = getAmountForTakePrice(1, amountLeft, priceArray[i], decimal, amountArray[i]);
            if (amountLeft >= amountInForTake) { //amountIn消耗完了
                break;
            }
        }

        {
            uint amountUsed;
            //处理挂单之外的价格范围
            (amountUsed, reserveIn, reserveOut) = getAmountForMovePrice(1, reserveIn, reserveOut, price, decimal);
            //再计算amm中实际会消耗的amountIn的数量
            amounts[0] += amountUsed > amountLeft ? amountLeft : amountUsed;
            //再计算本次移动价格获得的amountOut
            amounts[1] += amountUsed > amountLeft ? UniswapV2Library.getAmountOut(amountLeft, reserveIn, reserveOut) : UniswapV2Library.getAmountOut
            (amountUsed, reserveIn, reserveOut);
            amounts[2] = amountUsed < amountOffer ? getAmountOutWithPrice(amountOffer-amountUsed, price, decimal) : 0;
        }
    }

    //需要考虑初始价格到目标价格之间还有其它挂单的情况，需要考虑最小数量
    function getAmountOutForSell(address factory, uint amountOffer, uint price, address baseToken, address quoteToken) external view
    returns (uint amountAmmOut, uint amountOrderOut) {
        require(baseToken != quoteToken, 'HybridRouter: Invalid_Path');
        address orderBook = getOrderBook(factory, baseToken, quoteToken);
        require(orderBook != address(0), 'HybridRouter: Invalid_OrderBook');
        require(baseToken == IOrderBook(orderBook).baseToken(), 'HybridRouter: MisOrder_Path');

        (uint reserveIn, uint reserveOut) = UniswapV2Library.getReserves(factory, baseToken, quoteToken);
        uint decimal = getPriceDecimal(orderBook, baseToken, quoteToken);
        uint amountUsed;
        //uint amountUsed = getAmountForMovePrice(2, reserveIn, reserveOut, price, decimal);
        amountAmmOut = amountUsed > amountOffer ? UniswapV2Library.getAmountOut(amountOffer, reserveIn, reserveOut) : UniswapV2Library.getAmountOut(amountUsed, reserveIn, reserveOut);
        amountOrderOut = amountUsed < amountOffer ? getAmountForOfferPrice(amountOffer-amountUsed, price, decimal) : 0;
    }
}
