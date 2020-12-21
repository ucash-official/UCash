pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '../interfaces/IDistributor.sol';
import '../interfaces/IRewardDistributionRecipient.sol';

contract InitialShareDistributor is IDistributor {
    using SafeMath for uint256;

    event Distributed(address pool, uint256 cashAmount);

    bool public once = true;

    IERC20 public share;
    IRewardDistributionRecipient public usdtubcLPPool;
    uint256 public usdtubcInitialBalance;
    IRewardDistributionRecipient public usdtucsLPPool;
    uint256 public usdtucsInitialBalance;

    constructor(
        IERC20 _share,
        IRewardDistributionRecipient _usdtubcLPPool,
        uint256 _usdtubcInitialBalance,
        IRewardDistributionRecipient _usdtucsLPPool,
        uint256 _usdtucsInitialBalance
    ) public {
        share = _share;
        usdtubcLPPool = _usdtubcLPPool;
        usdtubcInitialBalance = _usdtubcInitialBalance;
        usdtucsLPPool = _usdtucsLPPool;
        usdtucsInitialBalance = _usdtucsInitialBalance;
    }

    function distribute() public override {
        require(
            once,
            'InitialShareDistributor: you cannot run this function twice'
        );

        share.transfer(address(usdtubcLPPool), usdtubcInitialBalance);
        usdtubcLPPool.notifyRewardAmount(usdtubcInitialBalance);
        emit Distributed(address(usdtubcLPPool), usdtubcInitialBalance);

        share.transfer(address(usdtucsLPPool), usdtucsInitialBalance);
        usdtucsLPPool.notifyRewardAmount(usdtucsInitialBalance);
        emit Distributed(address(usdtucsLPPool), usdtucsInitialBalance);

        once = false;
    }
}