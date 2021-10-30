pragma solidity >=0.5.0;

import "../interfaces/IOrderBook.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IUniswapV2Factory.sol";
import "./SafeMath.sol";

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

    function getTradeDirection(
        address orderBook,
        address tokenA,
        address tokenB)
    internal
    view
    returns(uint8 direction) {
        if (orderBook != address(0)) {
            //如果tokenA是计价token, 则表示买, 反之则表示卖
            direction = IOrderBook(orderBook).tradeDirection(tokenA, tokenB);
        }
    }

    function getPriceDecimal(address orderBook) internal view returns (uint8 decimal) {
        if (orderBook != address(0)) {
            decimal = IOrderBook(orderBook).priceDecimal();
        }
    }

    // fetches market order book for a pair for swap tokenA to takenB
    function getNextBook(
        address orderBook,
        uint8 orderDirection,
        uint curPrice)
    internal
    view
    returns (uint nextPrice, uint amount) {
        if (orderBook != address(0)) {
            (nextPrice, amount) = IOrderBook(orderBook).nextBook(orderDirection, curPrice);
        }
    }

    //将价格移动到price需要消息的tokenA的数量, 以及新的reserveIn, reserveOut
    function getAmountForMovePrice(uint8 direction, uint reserveIn, uint reserveOut, uint price, uint decimal)
    internal pure returns (uint amountIn, uint amountOut, uint reserveInNew, uint reserveOutNew) {
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
            amountOut = amountIn != 0 ? UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut) : 0;
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
            amountOut = amountIn != 0 ? UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut) : 0;
            //再更新reserveInNew = reserveIn + x', reserveOutNew = reserveOut - y'
            (reserveInNew, reserveOutNew) = (reserveIn + amountIn, reserveOut - amountOut);
        }
        else {
            (amountIn, reserveInNew, reserveOutNew) = (0, reserveIn, reserveOut);
        }
    }

    //使用amountA数量的amountInOffer吃掉在价格price, 数量为amountOutOffer的tokenB, 返回实际消耗的tokenA数量和返回的tokenB的数量，amountOffer需要考虑手续费
    //手续费应该包含在amountOutWithFee中
    function getAmountForTakePrice(uint8 direction, uint amountInOffer, uint price, uint decimal, uint amountOutOffer)
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

    function getAmountAndTakePrice(address orderBook, uint8 direction, uint amountInOffer, uint price,
        uint amountOutOffer)
    internal returns (uint amountIn, uint amountOutWithFee, address[] memory accounts, uint[] memory amounts){
        if (orderBook != address(0)) {
            (amountIn, amountOutWithFee, accounts, amounts) =
                IOrderBook(orderBook).getAmountAndTakePrice(direction, amountInOffer, price,
                    amountOutOffer);
        }
    }
}

library UniswapV2Library {
    using SafeMath for uint;

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
            ))));
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'UniswapV2Library: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(address factory, uint amountIn, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);

            address orderBook = HybridLibrary.getOrderBook(factory, path[i], path[i + 1]);
            uint8 tradeDirection = HybridLibrary.getTradeDirection(orderBook, path[i - 1], path[i]); //方向可能等于0
            uint8 orderDirection = tradeDirection == 1 ? tradeDirection << 1 : tradeDirection >> 1; //1->2 /2->1 /0->0

            uint decimal = HybridLibrary.getPriceDecimal(orderBook);
            uint amountLeft = amounts[i];
            uint amountOut = 0;
            (uint price, uint amount) = HybridLibrary.getNextBook(orderBook, orderDirection, 0);
            while (price != 0) {
                uint amountInUsed;
                uint amountOutUsed;
                //先计算pair从当前价格到price[j]消耗amountIn的数量
                (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice
                (tradeDirection, reserveIn, reserveOut, price, decimal);
                //再计算本次移动价格获得的amountOut
                amountOut += amountInUsed > amountLeft ? getAmountOut(amountLeft, reserveIn, reserveOut) : amountOutUsed;
                //再计算还剩下的amountIn
                amountLeft = amountInUsed < amountLeft ? amountLeft - amountInUsed : 0;
                if (amountLeft == 0) {
                    break;
                }

                //计算消耗掉一个价格的挂单需要的amountIn数量
                (uint amountInForTake, uint amountOutWithFee) = HybridLibrary.getAmountForTakePrice(tradeDirection, amountLeft, price, decimal, amount);
                amountOut += amountOutWithFee;
                if (amountLeft >= amountInForTake) {
                    break;
                }

                (price, amount) = HybridLibrary.getNextBook(orderBook, orderDirection, price);
            }

            amounts[i + 1] = amountOut;
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address factory, uint amountOut, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);

            address orderBook = HybridLibrary.getOrderBook(factory, path[i], path[i + 1]);
            uint8 tradeDirection = HybridLibrary.getTradeDirection(orderBook, path[i - 1], path[i]); //方向可能等于0
            uint8 orderDirection = tradeDirection == 1 ? tradeDirection << 1 : tradeDirection >> 1; //1->2 /2->1 /0->0

            uint decimal = HybridLibrary.getPriceDecimal(orderBook);
            //先计算从当前价格到price[i]消耗的数量
            uint amountLeft = amounts[i];
            uint amountIn = 0;
            (uint price, uint amount) = HybridLibrary.getNextBook(orderBook, orderDirection, 0);
            while (price != 0) {
                uint amountInUsed;
                uint amountOutUsed;
                //先计算pair从当前价格到price[j]消耗amountOut的数量
                (amountInUsed, amountOutUsed, reserveIn, reserveOut) = HybridLibrary.getAmountForMovePrice
                (tradeDirection, reserveIn, reserveOut, price, decimal);
                amountIn += amountInUsed > amountLeft ? getAmountIn(amountLeft, reserveIn, reserveOut) : amountOutUsed;
                //再计算还剩下的amountIn
                amountLeft = amountInUsed < amountLeft ? amountLeft - amountInUsed : 0;
                if (amountLeft == 0) {
                    break;
                }

                //计算消耗掉一个价格的挂单需要的amountOut数量
                (uint amountOutForTake, uint amountInWithFee) = HybridLibrary.getAmountForTakePrice(tradeDirection, amountLeft, price, decimal, amount);
                amountIn += amountInWithFee;
                if (amountLeft >= amountOutForTake) {
                    break;
                }

                (price, amount) = HybridLibrary.getNextBook(orderBook, orderDirection, price);
            }

            amounts[i - 1] = amountIn;
        }
    }
}
