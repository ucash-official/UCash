pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";
import "./interfaces/IUCashAsset.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./lib/Babylonian.sol";
import "./lib/FixedPoint.sol";
import "./lib/Safe112.sol";
import "./owner/Operator.sol";
import "./utils/Epoch.sol";
import "./utils/ContractGuard.sol";

contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    // ========== FLAGS
    bool public migrated = false;

    // ========== CORE
    address public cash;
    address public share;
    address public boardroom;
    address public seigniorageOracle;
    address public ubcusdtPool;

    // ========== PARAMS
    uint256 public cashPriceOne;
    uint256 public cashPriceCeiling;
    uint256 public cashPriceFloor;

    // Contractionary Policy
    mapping(address=>uint256) CPEarned;

   
    constructor(
        address _cash,
        address _share,
        address _seigniorageOracle,
        address _boardroom,
        uint256 _startTime,
        address _UBCUSDTPool
    ) public Epoch(1 days, _startTime, 0) {
        cash = _cash;
        share = _share;
        seigniorageOracle = _seigniorageOracle;
        boardroom = _boardroom;
        ubcusdtPool = _UBCUSDTPool;
        cashPriceOne = 10**18;
        cashPriceCeiling = uint256(105).mul(cashPriceOne).div(10**2);
        cashPriceFloor = uint256(95).mul(cashPriceOne).div(10**2);
    }


    modifier checkMigration {
        require(!migrated, "Treasury: migrated");

        _;
    }

    modifier checkOperator {
        require(
            IUCashAsset(cash).operator() == address(this) &&
                IUCashAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );
        _;
    }

    function getSeigniorageOraclePrice() public view returns (uint256) {
        return _getCashPrice(seigniorageOracle);
    }

    function _getCashPrice(address oracle) internal view returns (uint256) {
        try IOracle(oracle).consult(cash, 1e18) returns (uint256 price) {
            return price;
        } catch {
            revert("Treasury: failed to consult cash price from the oracle");
        }
    }

    function _updateCashPrice() internal { 
        try IOracle(seigniorageOracle).update()  {} catch {}
    }
    
    function migrate(address target) public onlyOperator checkOperator {
        require(!migrated, "Treasury: migrated");
        // cash
        Operator(cash).transferOperator(target);
        Operator(cash).transferOwnership(target);
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    function melter(uint256 amount) public  onlyOneBlock{
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        require(cashPrice <= cashPriceFloor,"Stakeroom not open");
        require(amount>0,"can not stake zero");
        IUCashAsset(cash).burnFrom(msg.sender,amount);
        CPEarned[msg.sender] = CPEarned[msg.sender].add(cashPriceOne.mul(1e18).div(cashPrice).mul(amount).div(1e18));
    }



    function redeem() public onlyOneBlock {
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        require(cashPrice >= cashPriceOne,"price lower than 1");
        require(CPEarned[msg.sender]>0,"earned zero");
        CPEarned[msg.sender] = 0;
        IUCashAsset(cash).mint(msg.sender,CPEarned[msg.sender]);
    }



   function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkOperator
    {
        _updateCashPrice();
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        if (cashPrice < cashPriceCeiling) {
           return ;
        }
        (uint112 poolUBCAmount,,) = IUniswapV2Pair(ubcusdtPool).getReserves();
        uint256 percentage = cashPrice.sub(cashPriceOne);
        uint256 seigniorage = uint256(poolUBCAmount).mul(percentage).div(1e18);
        IUCashAsset(cash).mint(address(this), seigniorage);
        IERC20(cash).safeApprove(boardroom, seigniorage);
        IBoardroom(boardroom).allocateSeigniorage(seigniorage);
        emit BoardroomFunded(now, seigniorage);
    }


    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);







}


