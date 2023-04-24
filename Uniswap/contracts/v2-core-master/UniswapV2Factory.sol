pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    //交易费接收地址
    address public feeTo;
    //交易费管理员
    address public feeToSetter;

    //交易对pair
    mapping(address => mapping(address => address)) public getPair;
    //Pair地址数组
    address[] public allPairs;
    
    //Pair创建事件
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    //构造函数
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }
    //Pair地址数量
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    //创建Pair
    /*
    *
    * @param:TokenA、TokenB为交易对地址
    *
    **/
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        //二者不能为同一个地址
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        //对Token地址进行排序，排序时会转化为固定字节数组，以第一个不同的数据进行比较。防止相同交易对以不同排序创建两个pair,从而导致价格不稳定。
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        //确保Token不为零地址。
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        //确保交易对Pair未被创建。
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        //Pair字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        //根据交易对地址生成salt；
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        //内联汇编：Create2
        assembly {
            //create2(value,offset,bytecode,salt);
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        //pair初始化
        IUniswapV2Pair(pair).initialize(token0, token1);

        //交易对pair
        getPair[token0][token1] = pair;
        //交易对pair
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        
        allPairs.push(pair);
        //触发事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    //设置交易费转入地址
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    //更换交易费用管理员
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
