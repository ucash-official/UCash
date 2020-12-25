pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
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

contract Treasury is ContractGuard, Epoch,AccessControl{
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
    bytes32 public constant EXTENSION = keccak256("EXTENSION");

    // Contractionary Policy Earned
    mapping(address=>uint256) public CPEarned;
    uint256 public totalBurned ;
    uint256 public pendingMintedUBC;

   
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
        cashPriceOne = 10**6;
        cashPriceCeiling = uint256(105).mul(cashPriceOne).div(10**2);
        cashPriceFloor = uint256(95).mul(cashPriceOne).div(10**2);
        _setupRole(DEFAULT_ADMIN_ROLE,msg.sender);
    }


    modifier checkMigration {
        require(!migrated, 'Treasury: migrated');

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

    function ExtensionMint(uint256 amount) public {
         require(hasRole(EXTENSION,msg.sender),"Only EXTENSION");
          IUCashAsset(cash).mint(msg.sender,amount);

    }
    function ExtensionBurn(uint256 amount) public {
        require(hasRole(EXTENSION,msg.sender),"Only EXTENSION");
        IUCashAsset(cash).burnFrom(msg.sender,amount);
    }


    function setParams(uint256 ceiling, uint256 one,uint256 floor) public onlyOperator{
        cashPriceCeiling = ceiling;
        cashPriceOne = one;
        cashPriceFloor = floor;
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
        require(!migrated, 'Treasury: migrated');

        // cash
        Operator(cash).transferOperator(target);
        Operator(cash).transferOwnership(target);

        Operator(boardroom).transferOperator(target);
        Operator(boardroom).transferOwnership(target);
    
        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);

        migrated = true;
        emit Migration(target);
    }

    function melter(uint256 amount) public  onlyOneBlock  checkMigration checkStartTime {
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        require(cashPrice <= cashPriceFloor && cashPrice>0,"melter not open");
        require(amount>0,"can not stake zero");
        IUCashAsset(cash).burnFrom(msg.sender,amount);
        totalBurned = totalBurned.add(amount);

        uint256 pendingAmount = cashPriceOne.mul(1e18).div(cashPrice).mul(amount).div(1e18);
        pendingMintedUBC = pendingMintedUBC.add(pendingAmount);
        CPEarned[msg.sender] = CPEarned[msg.sender].add(pendingAmount);
    }

    function redeem() public onlyOneBlock {
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        require(cashPrice >= cashPriceOne,"price lower than 1");
        require(CPEarned[msg.sender]>0,"earned zero");
        IUCashAsset(cash).mint(msg.sender,CPEarned[msg.sender]);
        pendingMintedUBC = pendingMintedUBC.sub(CPEarned[msg.sender]);
        CPEarned[msg.sender] = 0;
    }

    function getTotalPooledUBC() public view returns(uint256){
        (uint112 poolUBCAmount,,) = IUniswapV2Pair(ubcusdtPool).getReserves();
        return uint256(poolUBCAmount);
    }

   function allocateSeigniorage()
        external
        checkMigration
        onlyOneBlock
        checkStartTime
        checkEpoch
        checkOperator
    {
        _updateCashPrice();
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        if (cashPrice < cashPriceCeiling) {
           return ;
        }
        uint256 poolUBCAmount= getTotalPooledUBC();
        uint256 percentage = cashPrice.sub(cashPriceOne);
        uint256 seigniorage = poolUBCAmount.mul(percentage).div(1e6);
        IUCashAsset(cash).mint(address(this), seigniorage);
        IERC20(cash).safeApprove(boardroom, seigniorage);
        IBoardroom(boardroom).allocateSeigniorage(seigniorage);
        emit BoardroomFunded(now, seigniorage);
    }

    event Migration(address indexed target);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
}


