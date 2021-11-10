pragma solidity =0.5.16;

import './OrderBook.sol';

contract OrderBookFactory is IOrderBookFactory {

    mapping(address => mapping(address => address)) public getOrderBook;
    address[] public allOrderBooks;
    address pairFactory;

    event OrderBookCreated(
        address indexed pair,
        address indexed orderBook,
        uint,
        uint);

    constructor(address _factory) public {
        pairFactory = _factory;
    }

    function allOrderBookLength() external view returns (uint) {
        return allOrderBooks.length;
    }

    //create order book
    function createOrderBook(address baseToken, address quoteToken, uint priceStep, uint minAmount) external {
        require(baseToken != quoteToken, 'OrderBook: IDENTICAL_ADDRESSES');
        (address token0, address token1) = baseToken < quoteToken ? (baseToken, quoteToken) : (quoteToken, baseToken);
        require(token0 != address(0), 'OrderBook: ZERO_ADDRESS');
        require(getOrderBook[token0][token1] == address(0), 'OrderBook: ORDER_BOOK_EXISTS');

        address pair = IUniswapV2Factory(pairFactory).getPair(token0, token1);
        require(pair != address(0), 'OrderBook: TOKEN_PAIR_NOT_EXISTS');
        bytes memory bytecode = type(OrderBook).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        address orderBook;
        assembly {
            orderBook := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IOrderBook(orderBook).initialize(pair, baseToken, quoteToken, priceStep, minAmount);
        getOrderBook[token0][token1] = orderBook;
        getOrderBook[token1][token0] = orderBook;
        allOrderBooks.push(orderBook);
        emit OrderBookCreated(pair, orderBook, priceStep, minAmount);
    }
}
