pragma solidity =0.5.16;

import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;
    address public admin;
    address public getOrderBookFactory;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    event OrderBookFactoryUpdate(address indexed admin, address newOrderBookFactory);

    constructor(address _admin) public {
        admin = _admin;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function getCodeHash() external pure returns (bytes32) {
        return keccak256(type(UniswapV2Pair).creationCode);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == admin, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setAdmin(address _admin) external {
        require(msg.sender == admin, 'UniswapV2: FORBIDDEN');
        admin = _admin;
    }

    function setOrderBookFactory(address _orderBookFactory) external {
        require(msg.sender == admin, 'UniswapV2: FORBIDDEN');
        getOrderBookFactory = _orderBookFactory;

        emit OrderBookFactoryUpdate(msg.sender, _orderBookFactory);
    }
}
