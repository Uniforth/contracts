pragma solidity ^0.6.0;

import "./interfaces/Address.sol";
import "./interfaces/SafeCast.sol";
import "./interfaces/SafeMath.sol";
import "./interfaces/ERC20UpgradeSafe.sol";
import "./interfaces/OwnableUpgradeSafe.sol";

import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";

import "./interfaces/IUniswapV2Pair.sol";

import "./interfaces/IWETH.sol";

contract SUSF is ERC20UpgradeSafe, OwnableUpgradeSafe {
    
    using SafeCast for int256;
    using SafeMath for uint256;
    using Address for address;
    
    struct Transaction {
        bool enabled;
        address destination;
        bytes data;
    }

    event TransactionFailed(address indexed destination, uint index, bytes data);
	
	// Stable ordering is not guaranteed.

    Transaction[] public transactions;

    uint256 private _epoch;
    event LogRebase(uint256 indexed epoch, uint256 totalSupply);

    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;

    mapping (address => bool) private _isExcluded;
    address[] private _excluded;
	
	uint256 private _totalSupply;
   
    uint256 private constant MAX = ~uint256(0);
    uint256 private _rTotal;
    uint256 private _tFeeTotal;
    
    uint256 private constant DECIMALS = 9;
    uint256 private constant RATE_PRECISION = 10 ** DECIMALS;
    
    uint256 public _tFeePercent;
    
    address public _rebaser;
    
    uint256 public _limitTransferAmount;
    uint256 public _limitMaxBalance;
    uint256 public _limitSellFeePercent;
    
    uint256 public _limitTimestamp;

    uint256 public _presaleTimestamp;
    uint256 public _presaleEth;
    bool public endSale;
    uint256 public _presaleRate;
    
    IUniswapV2Router02 public uniswapRouterV2;
    IUniswapV2Factory public uniswapFactory;
    
    function initialize()
        public
        initializer
    {
        __ERC20_init("Uniforth", "UNIF");
        _setupDecimals(uint8(DECIMALS));
        __Ownable_init();
        
        _totalSupply = 8000000 * 10**9 ;
        _rTotal = (MAX - (MAX % _totalSupply));
        
        _rebaser = _msgSender();
        
        _tFeePercent = 266; //2.6682%

        _rOwned[address(this)] = _rTotal;
        emit Transfer(address(0), address(this), _totalSupply);

        _presaleTimestamp = now  + 3 days;
        endSale = false;
        _presaleEth = 600 ether;
        _presaleRate = 6000;
        
        excludeAccount(_msgSender());
        excludeAccount(address(this));
        
        uniswapRouterV2 = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        uniswapFactory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    }
    
    event print(uint256);

    receive() external payable {
        require(!endSale, "PreSale Ended");
        require(_presaleEth >= msg.value, "Sold out");
        address payable wallet = address(uint160(owner()));
        wallet.transfer(msg.value.div(3));
        _presaleEth = _presaleEth.sub(msg.value);
        uint256 amountBought = msg.value.div(10**9).mul(_presaleRate);
        _transfer(address(this), msg.sender, amountBought );
    }

    function listToken() external onlyOwner() {
        require(!endSale, 'already listed');
        require(_presaleEth == 0 || _presaleTimestamp < now, "Sale has not ended yet");
        endSale = true;
        _transfer(address(this), _msgSender(), 2000000 * 10**9);
        address tokenUniswapPair = uniswapFactory.createPair(
            address(uniswapRouterV2.WETH()),
            address(address(this))
        );
        IUniswapV2Pair pair = IUniswapV2Pair(tokenUniswapPair);
        address WETH = uniswapRouterV2.WETH();
        uint256 ethToSend = address(this).balance;
        IWETH(WETH).deposit{value : ethToSend}();
        require(address(this).balance == 0 , "Transfer Failed");
        uint256 tokenToAdd = 2400000 * 10**9;
        if(_presaleEth != 0) {
            tokenToAdd = ethToSend.div(10**9).mul(_presaleRate);
            uint256 unsoldTokens = balanceOf(address(this)) - tokenToAdd; 
            _transfer(address(this), address(0), unsoldTokens);
        }
        IWETH(WETH).transfer(address(pair),ethToSend);
        _transfer(address(this), address(pair), tokenToAdd);
        pair.mint(address(this));
        IERC20(address(pair)).transfer(msg.sender, IERC20(address(pair)).balanceOf(address(this)));
    }
    
    function setRebaser(address rebaser) external onlyOwner() {
        _rebaser = rebaser;
    }
    
    function setTransferFeePercent(uint256 tFeePercent) external onlyOwner() {

        _tFeePercent = tFeePercent;
    }
    
    function setLimit(uint256 transferAmount, uint256 maxBalance, uint256 sellFeePercent) external onlyOwner() {
        require(_limitTimestamp == 0, "Limit changes not allowed");
        
        _limitTransferAmount = transferAmount;
        _limitMaxBalance = maxBalance;
        _limitSellFeePercent = sellFeePercent;

        _limitTimestamp = now;
    }
    
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }
    
    function rebase(int256 supplyDelta)
        external
        returns (uint256)
    {
        require(_msgSender() == owner() || _msgSender() == _rebaser, "Sender not authorized");
        
        _epoch = _epoch.add(1);
		
        if (supplyDelta == 0) {
            emit LogRebase(_epoch, _totalSupply);
            return _totalSupply;
        }
        
        uint256 uSupplyDelta = (supplyDelta < 0 ? -supplyDelta : supplyDelta).toUint256();
        uint256 rate = uSupplyDelta.mul(RATE_PRECISION).div(_totalSupply);
        uint256 multiplier;
        
        if (supplyDelta < 0) {
            multiplier = RATE_PRECISION.sub(rate);
        } else {
            multiplier = RATE_PRECISION.add(rate);
        }
        
        if (supplyDelta < 0) {
            _totalSupply = _totalSupply.sub(uSupplyDelta);
        } else {
            _totalSupply = _totalSupply.add(uSupplyDelta);
        }
        
        if (_totalSupply > MAX) {
            _totalSupply = MAX;
        }
        
        for (uint256 i = 0; i < _excluded.length; i++) {
            if(_tOwned[_excluded[i]] > 0) {
                _tOwned[_excluded[i]] = _tOwned[_excluded[i]].mul(multiplier).div(RATE_PRECISION);
            }
        }
        
        emit LogRebase(_epoch, _totalSupply);

		for (uint i = 0; i < transactions.length; i++) {
            Transaction storage t = transactions[i];
            if (t.enabled) {
                bool result = externalCall(t.destination, t.data);
                if (!result) {
                    emit TransactionFailed(t.destination, i, t.data);
                    revert("Transaction Failed");
                }
            }
        }

        return _totalSupply;
    }
    
    /**
     * @notice Adds a transaction that gets called for a downstream receiver of rebases
     * @param destination Address of contract destination
     * @param data Transaction data payload
     */
	
    function addTransaction(address destination, bytes memory data)
        external
        onlyOwner
    {
        transactions.push(Transaction({
            enabled: true,
            destination: destination,
            data: data
        }));
    }
	
	/**
     * @param index Index of transaction to remove.
     *              Transaction ordering may have changed since adding.
     */

    function removeTransaction(uint index)
        external
        onlyOwner
    {
        require(index < transactions.length, "index out of bounds");

        if (index < transactions.length - 1) {
            transactions[index] = transactions[transactions.length - 1];
        }

        transactions.pop();
    }
	
	/**
     * @param index Index of transaction. Transaction ordering may have changed since adding.
     * @param enabled True for enabled, false for disabled.
     */

    function setTransactionEnabled(uint index, bool enabled)
        external
        onlyOwner
    {
        require(index < transactions.length, "index must be in range of stored tx list");
        transactions[index].enabled = enabled;
    }
	
	/**
     * @return Number of transactions, both enabled and disabled, in transactions list.
     */

    function transactionsSize()
        external
        view
        returns (uint256)
    {
        return transactions.length;
    }
	
	/**
     * @dev wrapper to call the encoded transactions on downstream consumers.
     * @param destination Address of destination contract.
     * @param data The encoded data payload.
     * @return True on success
     */

    function externalCall(address destination, bytes memory data)
        internal
        returns (bool)
    {
        bool result;
        assembly {  // solhint-disable-line no-inline-assembly
            // "Allocate" memory for output
            // (0x40 is where "free memory" pointer is stored by convention)
            let outputAddress := mload(0x40)

            // First 32 bytes are the padded length of data, so exclude that
            let dataAddress := add(data, 32)

            result := call(
                // 34710 is the value that solidity is currently emitting
                // It includes callGas (700) + callVeryLow (3, to pay for SUB)
                // + callValueTransferGas (9000) + callNewAccountGas
                // (25000, in case the destination address does not exist and needs creating)
                sub(gas(), 34710),


                destination,
                0, // transfer value in wei
                dataAddress,
                mload(data),  // Size of the input, in bytes. Stored in position 0 of the array.
                outputAddress,
                0  // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromRefraction(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual override returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual override returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function isExcluded(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }

    function refract(uint256 tAmount) public {
        address sender = _msgSender();
        require(!_isExcluded[sender], "Excluded addresses cannot call this function");
        (uint256 rAmount,,,,) = _getValues(tAmount, _tFeePercent);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rTotal = _rTotal.sub(rAmount);
        _tFeeTotal = _tFeeTotal.add(tAmount);
    }

    function refractionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
        require(tAmount <= _totalSupply, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,) = _getValues(tAmount, _tFeePercent);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,) = _getValues(tAmount, _tFeePercent);
            return rTransferAmount;
        }
    }

    function tokenFromRefraction(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total refractions");
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }

    function excludeAccount(address account) public onlyOwner() {
        require(!_isExcluded[account], "Account is already excluded");
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromRefraction(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeAccount(address account) public onlyOwner() {
        require(_isExcluded[account], "Account is already excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    function _approve(address owner, address spender, uint256 amount) internal override {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        require(endSale || sender == owner() || sender == address(this), "transfer paused for sale");
        if(sender == address(this) || sender == owner()) {
            _transferBothExcluded(sender, recipient, amount, 0);
        } else if(_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount, _tFeePercent);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
                _transferToExcluded(sender, recipient, amount, _tFeePercent);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferStandard(sender, recipient, amount, _tFeePercent);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount, 0);
        } else {
            _transferStandard(sender, recipient, amount, _tFeePercent);
        }
    }
    

    function _transferStandard(address sender, address recipient, uint256 tAmount, uint256 tFeePercent) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee) = _getValues(tAmount, tFeePercent);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);       
        _refractFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferToExcluded(address sender, address recipient, uint256 tAmount, uint256 tFeePercent) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee) = _getValues(tAmount, tFeePercent);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);           
        _refractFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferFromExcluded(address sender, address recipient, uint256 tAmount, uint256 tFeePercent) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee) = _getValues(tAmount, tFeePercent);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);   
        _refractFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferBothExcluded(address sender, address recipient, uint256 tAmount, uint256 tFeePercent) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee) = _getValues(tAmount, tFeePercent);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);        
        _refractFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _refractFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _getValues(uint256 tAmount, uint256 tFeePercent) private view returns (uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee) = _getTValues(tAmount, tFeePercent);
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, currentRate);
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee);
    }

    function _getTValues(uint256 tAmount, uint256 tFeePercent) private pure returns (uint256, uint256) {
        uint256 tFee = tAmount.mul(tFeePercent).div(10000);
        uint256 tTransferAmount = tAmount.sub(tFee);
        return (tTransferAmount, tFee);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee);
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _totalSupply;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _totalSupply);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_totalSupply)) return (_rTotal, _totalSupply);
        return (rSupply, tSupply);
    }
}