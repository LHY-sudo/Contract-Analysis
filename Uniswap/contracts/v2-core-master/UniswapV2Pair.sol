pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    //使用库
    using SafeMath  for uint;
    using UQ112x112 for uint224;
    //最小流动性，Pair部署后，锚定价格
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    //112+112+32=256，三个变量占用一个slot
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    //防止重入攻击
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }
    //获取目前交易对的Token储量
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    //代币转出函数；
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }
    //事件定义
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    //构造函数
    constructor() public {
        factory = msg.sender;
    }

    // 初始化函数，只能被Factory调用，只能被调用一次；
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        //因使用uint112模拟小数，故最大值不能超过uint112；
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        //时间戳
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        //以区块的第一笔交易累计价格
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        //最新Token余额；
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        //出发同步事件；
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    //mint fee 费用发到factory设置的feeto中；
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        //将K值读取到Memory，后续操作节省gas；
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                //rootK可以认为是Pair的总价值，作为总价值，需要满足：
                // 在添加或者移动流动性时，保证总价值(V)，V-1/V-2 = T0-1/T0-2,V-1/V-2 = T1-1/T1-2,
                //目的是为了保证在添加或者移除流动性时，价值平均分配，否则先后去除或添加流动性的用户，获得或支付Token不同；
                // reserve0 * reserve1 = K; 
                //根据上面原则我们知道sqrt(T0*T1)*C = V,C为固定数值，如此我们把C定为1，便得出V可以用sqrt(T0*T1)表示；

                //计算目前Rootk
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                //计算LastK
                uint rootKLast = Math.sqrt(_kLast);
                //计算手续费，手续费为0.3/100 * 1/6
                //首先，不能简单地计算手续费为1/6*(rootk-rootkLast);因为这是价值占比；
                //uniswapV2中手续费是使用LP收取的，所以计算LP占比：
                /*
                *        FeeLp                 1/6*Value
                *     -------------  =  ------------------------  
                *      totalSupply        5/6*Value + rootkLast         其中：Value = rootk -rootkLast
                *
                * 计算后就是下面的公式；
                */
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    //mint LP
    function mint(address to) external lock returns (uint liquidity) {
        //获取Token储备量；
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        //获取添加流动性后余额；
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        //用户添加Token数量；
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        //收取上次添加流动性到本次的交易手续费
        bool feeOn = _mintFee(_reserve0, _reserve1);
        //获取总LP供应量，_mintFee会更新totalSupply所以要首先收取Fee；
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //判断是否为首次添加LP；
        if (_totalSupply == 0) {
            //如果为首次添加LP，则Lp = aqrt(T0*T1)-MINIMUN_LIQUIDITY;
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            //mint最小流动性到address(0);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            //如果不为零，则按照token占比的最小值添加流动性，最大值会被黑;
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        //如果用户获得LP不为0，则mint LP；
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);
        //更新Token储备量，同时检测是否流动性溢出，在_update内实现；
        _update(balance0, balance1, _reserve0, _reserve1);
        //计算最新KLast,以计算下次平台收手续费；
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        //出发添加流动性事件；
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    //销毁LP
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        //获取最新储备量；
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
       //获取Token余额；
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        //获取合约LP余额；
        uint liquidity = balanceOf[address(this)];

        //mint Fee；
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //计算Token所占份额；
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        //确保获得Token大于0；
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        //销毁LP
        _burn(address(this), liquidity);
        //发送Token；
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        //获取剩余Token数目
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        //更新Token储备量；
        _update(balance0, balance1, _reserve0, _reserve1);
        //更新KLast;
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        //触发销毁事件；
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    //交换Token；
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        //out不能全部为零；
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        //获取储备
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        //OUT不能大于储备量；
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        //限制转出地址不为Token合约；
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        //如果包含data则发起调用，闪电贷会使用；
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        //获取最新余额；
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        //判断输入Token数量
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        //k值检测
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
