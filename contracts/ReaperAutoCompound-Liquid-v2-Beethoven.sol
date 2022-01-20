// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import './ReaperBaseStrategy.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

interface IUniswapV2Router01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/**
 * @dev Strategy description
 *
 * Expect the amount of staked tokens you have to grow over time while you have assets deposit
 */
contract ReaperAutoCompound_LiquidV2_Beethoven is ReaperBaseStrategy {
    using SafeERC20 for IERC20;

        /**
     * @dev Tokens Used:
     * {wftm} - Required for fees.
     * {rewardToken} - Token generated by staking our funds. => LQDR
     * {bpToken} - Balancer Protocol Token that the strategy maximizes.
     * {bptUnderlyingTokens} - Underlying tokens of the bpToken
     */
    IERC20 public constant wftm = IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    IERC20 public constant rewardToken = IERC20(0x10b620b2dbAC4Faa7D7FFD71Da486f5D44cd86f9); 
    address public bpToken; 
    address[] public bptUnderlyingTokens;

    uint256 public totalUnderlyingTokens;

    mapping(uint256 => bool) public isEmitting;
    bool public harvestOn = false;

    /**
     * @dev Third Party Contracts:
     * {MASTER_CHEF} - masterChef for pools. -> LQDR
     * {BEET_VAULT} - Beethoven vault - core contract of balancer protocol //todo is it really necessary ?
     */
    address public constant MASTER_CHEF = address(0x6e2ad6527901c9664f016466b8DA1357a004db0f);
    address public constant BEET_VAULT = address(0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce);

    /**
     * @dev Routes we take to swap tokens using routers.
     * {rewardTokenToWftmRoute} - Route we take to get from {rewardToken} into {wftm}.
     * {rewardTokenToStakedTokenRoute} - Route we take to get from {rewardToken} into {stakedToken}.
     */
    address[] public rewardTokenToWftmRoute = [rewardToken, wftm];
    address[] public previousStakedTokenToWftmRoute = [previousStakedToken, wftm];
    address[] public wftmTokenToStakedToken = [wftm, stakedToken];

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    constructor(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists
    ) ReaperBaseStrategy(_vault, _feeRemitters, _strategists) {
        _giveAllowances();
    }

    // CORE FUNCTIONS

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     */
    function deposit() public whenNotPaused {
        //todo  get balance of strat
        //      deposit in protocol
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {stakedToken} from the protocol.
     * The available {stakedToken} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(_msgSender() == vault, '!vault');
        //todo  get balance in strat
        //      is balance of strat enough ?
        //      if not, withdraw from protocol
        //      if withdrawn too much, reduce to amount
        //      calculate and deduct withdrawFee
        //      send sh*t to vault
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the protocol.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {rewardToken} token for {stakedToken}
     * 4. Adds more liquidity to the pool if on another block than the rewards' claiming.
     * 5. It deposits the new stakedTokens.
     */
    function _harvestCore() internal override whenNotPaused {
        //todo claim rewards + add strategy-specific logic
        _chargeFees();
        _addLiquidity();
        deposit();
    }

    /**
     * @dev Returns the approx amount of profit from harvesting plus fee that
     *      would be returned to harvest caller.
     */
    function estimateHarvest() external view virtual override returns (uint256 profit, uint256 callFeeToUser) {
        //todo  get reward amount
        //      convert to wftm to get profit
        //      calculate callfee
        //      substract callfee from profit
    }

    /**
     * @dev Takes out fees from the rewards. Set by constructor
     *      callFeeToUser is set as a percentage of the fee,
     *      as is treasuryFeeToVault
     *      strategistFee is based on treasuryFeeToVault
     */
    function _chargeFees() internal {
        //todo  update to fit strategy
        //      get balance of reward or wftm
        //      swap to wftm
        //      calculate callFee, treasuryFee, feeToStrategist
        //      transfer this sh*t (use paymentrouter for strategists)
    }

    /**
     * @dev Swaps {rewardToken} for {stakedToken} using SpookySwap.
     */
    function _addLiquidity() internal {
        //todo update to fit strategy
        //      get balance of reward
        //      swap to staked
    }

    function _swap(address _tokenIN, address _tokenOUT, bytes32 _pool, uint256 amount) internal{

        // IVault.SingleSwap memory singleSwap;
        // IVault.SwapKind swapKind = IVault.SwapKind.GIVEN_IN;

        // singleSwap.poolId = _pool;
        // singleSwap.kind = swapKind;
        // singleSwap.assetIn = IAsset(_tokenIN);
        // singleSwap.assetOut = IAsset(_tokenOUT);
        // singleSwap.amount = amount;
        // singleSwap.userData = abi.encode(0);

        // IVault.FundManagement memory funds;
        // funds.sender = address(this);
        // funds.fromInternalBalance = false;
        // funds.recipient = payable(address(this));
        // funds.toInternalBalance = false;

        // IERC20(_tokenIN).safeApprove(BeetVault, 0);
        // IERC20(_tokenIN).safeApprove(BeetVault, amount);

        // IVault(BeetVault).swap(singleSwap, funds, 1, (block.timestamp + 600));

    }

    function addTokenAndScToken(address _token, address _scToken) external {
        _onlyStrategistOrOwner();
        //verify that token matches sctoken's underlying
        //if yes, success=true
    }

    function setTargetLtv(uint256 _targetLtv) external {
        _onlyStrategistOrOwner();
        (, uint256 collateralFactorMantissa, ) = compound.markets(address(stakedToken));
    }

    /**
     * @dev Function to calculate the total underlying {token} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in protocols.
     */
    function balanceOf() public view override returns (uint256 balance) {
        //todo return balance
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     *      vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, '!vault');
        //todo withdraw funds
        uint256 stakedTokenBal = IERC20(stakedToken).balanceOf(address(this));
        IERC20(stakedToken).safeTransfer(vault, stakedTokenBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds, leaving rewards behind
     *      Can only be called by strategist or owner.
     */
    function panic() public {
        _onlyStrategistOrOwner();
        pause();
        // todo withdraw funds asap
    }

    /**
     * @dev Pauses the strat. Can only be called by strategist or owner.
     */
    function pause() public {
        _onlyStrategistOrOwner();
        _pause();
        _removeAllowances();
    }

    /**
     * @dev Unpauses the strat. Can only be called by strategist or owner.
     */
    function unpause() external {
        _onlyStrategistOrOwner();
        _unpause();

        _giveAllowances();

        deposit();
    }

    /**
     * @dev Set allowance for token transfers
     */
    function _giveAllowances() internal {
        //todo approve to max
    }

    /**
     * @dev Set all allowances to 0
     */
    function _removeAllowances() internal {
        //todo remove all allowances
    }
}
