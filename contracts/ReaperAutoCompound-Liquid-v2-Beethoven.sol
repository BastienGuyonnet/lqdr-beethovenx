// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import './ReaperBaseStrategy.sol';
import './interfaces/IBasePool.sol';
import './interfaces/IBaseWeightedPool.sol';
import './interfaces/IMasterChefv2.sol';
import './interfaces/IUniswapV2Router.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @dev Strategy description
 *
 * Expect the amount of staked tokens you have to grow over time while you have assets deposit
 */
contract ReaperAutoCompound_LiquidV2_Beethoven is ReaperBaseStrategy {
    using SafeERC20 for IERC20;

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for fees.
     * {REWARD_TOKEN} - Token generated by staking our funds. => LQDR
     * {bpToken} - Balancer Protocol Token that the strategy maximizes.
     * {bptUnderlyingTokens} - Underlying tokens of the bpToken
     */
    address public constant WFTM = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public constant REWARD_TOKEN = address(0x10b620b2dbAC4Faa7D7FFD71Da486f5D44cd86f9);
    address public bpToken;
    address[] public bptUnderlyingTokens;

    uint256 public totalUnderlyingTokens;

    mapping(uint256 => bool) public isEmitting;
    bool public harvestOn = false;

    /**
     * @dev Third Party Contracts:
     * {MASTER_CHEF} - masterChef for pools. -> LQDR
     * {BEET_VAULT} - Beethoven vault - core contract of balancer protocol
     */
    address public constant MASTER_CHEF = address(0x6e2ad6527901c9664f016466b8DA1357a004db0f);
    address public constant BEET_VAULT = address(0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce);
    address public constant SPOOKY_ROUTER = address(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
    address public constant SPIRIT_ROUTER = address(0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52);
    uint256 public immutable poolId;
    bytes32 public immutable poolID_bytes;

    /**
     * @dev Routes we take to swap tokens using routers.
     * {rewardTokenToWftmRoute} - Route ID to swap from {REWARD_TOKEN} to {WFTM}.
     * {rewardTokenToStakedTokenRoute} - Routes used to go from {WFTM} to {token}.
     */
    bytes32 public route_ID;
    address[] public rewardTokenToWftmRoute = [REWARD_TOKEN, WFTM];
    mapping(address => address[]) public wftmToUnderlyingRoute;
    mapping(address => uint256) public underlyingToWeight;

    string constant CONSTRUCTOR_ERROR = 'constructor error';
    uint256 constant MINIMUM_BPT = 1; //virtually ensures we can always get the desired BPT

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @param _vault Vault address
     * @param _feeRemitters Addresses to send fees to. Size: 2
     * @param _strategists Strategists piloting this strategy
     * @param _bpToken Token staked in the farm
     * @param _poolId Masterchef pool id => Liquid Masterchef
     * @param _ratios weight of each underlying token
     */
    constructor(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address _bpToken,
        uint256 _poolId,
        uint256[] memory _ratios
    ) ReaperBaseStrategy(_vault, _feeRemitters, _strategists) {

        bpToken = _bpToken;
        poolId = _poolId;
        poolID_bytes = IBasePool(_bpToken).getPoolId();
        IERC20[] memory _bpTokens;
        (_bpTokens, , ) = IVault(BEET_VAULT).getPoolTokens(poolID_bytes);

        require(_bpTokens.length == _ratios.length, CONSTRUCTOR_ERROR);

        totalUnderlyingTokens = _bpTokens.length;
        for (uint256 i; i < totalUnderlyingTokens; i++) {
            bptUnderlyingTokens.push(address(_bpTokens[i]));
            if (bptUnderlyingTokens[i] == WFTM) {
                wftmToUnderlyingRoute[WFTM] = [WFTM];
            } else {
                wftmToUnderlyingRoute[bptUnderlyingTokens[i]] = [WFTM,bptUnderlyingTokens[i]];
            }
            underlyingToWeight[bptUnderlyingTokens[i]] = _ratios[i];
        }

        _giveAllowances();
    }

    // CORE FUNCTIONS

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     */
    function deposit() public whenNotPaused {
        uint256 bpTokenBal = IERC20(bpToken).balanceOf(address(this));

        if (bpTokenBal != 0) {
            IMasterChefv2(MASTER_CHEF).deposit(poolId, bpTokenBal, address(this));
        }
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {stakedToken} from the protocol.
     * The available {stakedToken} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(_msgSender() == vault, '!vault');
        uint256 bpTokenBal = IERC20(bpToken).balanceOf(address(this));
        if (bpTokenBal < _amount) {
            IMasterChefv2(MASTER_CHEF).withdraw(poolId, _amount - bpTokenBal, address(this));
            bpTokenBal = IERC20(bpToken).balanceOf(address(this));
        }

        if (bpTokenBal > _amount) {
            bpTokenBal = _amount;
        }

        uint256 withdrawFee = (bpTokenBal * securityFee) / PERCENT_DIVISOR;
        IERC20(bpToken).safeTransfer(vault, bpTokenBal - withdrawFee);
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the protocol.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {REWARD_TOKEN} token for {stakedToken}
     * 4. Adds more liquidity to the pool if on another block than the rewards' claiming.
     * 5. It deposits the new stakedTokens.
     */
    function _harvestCore() internal override whenNotPaused {
        IMasterChefv2(MASTER_CHEF).harvest(poolId, address(this));
        _swapRewardToWftm();
        _chargeFees();
        _addLiquidity();
        deposit();
    }

    /**
     * @dev Returns the approx amount of profit from harvesting plus fee that
     *      would be returned to harvest caller.
     */
    function estimateHarvest() external view virtual override returns (uint256 profit, uint256 callFeeAmount) {
        IMasterChefv2(MASTER_CHEF).pendingLqdr(poolId, address(this));
        uint256 wftmFromProfit = IUniswapV2Router(SPIRIT_ROUTER).getAmountsOut(
            IERC20(REWARD_TOKEN).balanceOf(address(this)),
            rewardTokenToWftmRoute
        )[1];
        profit = (wftmFromProfit * totalFee) / PERCENT_DIVISOR;
        callFeeAmount = (profit * callFee) / PERCENT_DIVISOR;
        profit -= callFeeAmount;
    }

    function _swapRewardToWftm() internal {
        uint256 rewardTokenBal = IERC20(REWARD_TOKEN).balanceOf(address(this));
        IUniswapV2Router(SPIRIT_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            rewardTokenBal,
            0,
            rewardTokenToWftmRoute,
            address(this),
            block.timestamp + 600
        );
    }

    /**
     * @dev Takes out fees from the rewards. Set by constructor
     *      callFeeAmount is set as a percentage of the totalFee,
     *      as is treasuryFeeAmount
     *      strategistFee is based on treasuryFeeAmount
     */
    function _chargeFees() internal {
        uint256 wftmFee = (IERC20(WFTM).balanceOf(address(this)) * totalFee) / PERCENT_DIVISOR;
        if (wftmFee != 0) {
            uint256 callFeeAmount = (wftmFee * callFee) / PERCENT_DIVISOR;
            uint256 treasuryFeeAmount = (wftmFee * treasuryFee) / PERCENT_DIVISOR;
            uint256 strategistFeeAmount = (treasuryFeeAmount * strategistFee) / PERCENT_DIVISOR;
            treasuryFeeAmount -= strategistFeeAmount;

            IERC20(WFTM).safeTransfer(msg.sender, callFeeAmount);
            IERC20(WFTM).safeTransfer(treasury, treasuryFeeAmount);
            IERC20(WFTM).safeIncreaseAllowance(strategistRemitter, strategistFeeAmount);
            IPaymentRouter(strategistRemitter).routePayment(WFTM, strategistFeeAmount);
        }
    }

    /**
     * @dev Request {bpToken} to the {BEET_VAULT} based on underlying tokens balances
     */
    function _addLiquidity() internal {
        bool hasUnderlyingWftm = false;
        uint256 wftmBal = IERC20(WFTM).balanceOf(address(this));

        for (uint256 i; i < totalUnderlyingTokens; i++) {
            address token = bptUnderlyingTokens[i];
            if (token == WFTM) {
                hasUnderlyingWftm = true;
                continue;
            }

            uint256 wftmToSwap = (wftmBal * underlyingToWeight[token]) / PERCENT_DIVISOR;
            uint256 amountOut = IUniswapV2Router(SPOOKY_ROUTER).getAmountsOut(wftmToSwap, wftmToUnderlyingRoute[token])[
                1
            ];
            if (amountOut == 0) {
                continue;
            }

            IUniswapV2Router(SPOOKY_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                wftmToSwap,
                0,
                wftmToUnderlyingRoute[token],
                address(this),
                block.timestamp + 600
            );
        }

        _joinWeightedPool();
    }

    function _joinWeightedPool() internal {
        /** Exact Tokens Join
         *       User sends precise quantities of tokens, and receives an estimated but unknown (computed at run time) quantity of BPT.
         *   Encoding
         *       userData ABI
         *           ['uint256', 'uint256[]', 'uint256']
         *       userData
         *           [EXACT_TOKENS_IN_FOR_BPT_OUT, amountsIn, minimumBPT]
         */
        IBaseWeightedPool.JoinKind joinKind = IBaseWeightedPool.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT;

        IAsset[] memory assets = new IAsset[](totalUnderlyingTokens);
        uint256[] memory maxAmountsIn = new uint256[](totalUnderlyingTokens);
        bytes memory userData;

        for (uint256 i; i < totalUnderlyingTokens; i++) {
            assets[i] = IAsset(bptUnderlyingTokens[i]);
            maxAmountsIn[i] = IERC20(bptUnderlyingTokens[i]).balanceOf(address(this));
        }
        userData = abi.encode(joinKind, maxAmountsIn, MINIMUM_BPT);

        IVault.JoinPoolRequest memory request;
        request.assets = assets;
        request.maxAmountsIn = maxAmountsIn;
        request.userData = userData;
        request.fromInternalBalance = false;

        // Send request to the vault
        IVault(BEET_VAULT).joinPool(poolID_bytes, address(this), address(this), request);
    }

    /**
     * @dev Set new route to swap from wftm to a token
     * Does not check that token is an underlying
     */
    function setWftmToUnderlyingSwapRoute(address _token, address[] memory _route) external {
        _onlyStrategistOrOwner();
        require(_route[0] == WFTM && _route[_route.length - 1 ] == _token);
        wftmToUnderlyingRoute[_token] = _route;
    }

    //todo function to fetch the pool token weights with : pool.getNormalizedWeights();

    /**
     * @dev Function to calculate the total underlying {token} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in protocols.
     */
    function balanceOf() public view override returns (uint256 balance) {
        balance = IERC20(bpToken).balanceOf(address(this)) + balanceOfPool();
    }

    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChefv2(MASTER_CHEF).userInfo(poolId, address(this));
        return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     *      vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, '!vault');

        IMasterChefv2(MASTER_CHEF).withdrawAndHarvest(poolId, balanceOfPool(), address(this));

        uint256 rewardTokenBal = IERC20(REWARD_TOKEN).balanceOf(address(this));    
        uint256 bpTokenBal = IERC20(bpToken).balanceOf(address(this));
        IERC20(REWARD_TOKEN).transfer(vault, rewardTokenBal);
        IERC20(bpToken).transfer(vault, bpTokenBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds, leaving rewards behind
     *      Can only be called by strategist or owner.
     */
    function panic() public {
        _onlyStrategistOrOwner();
        pause();
        IMasterChefv2(MASTER_CHEF).emergencyWithdraw(poolId, address(this));
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
        IERC20(bpToken).safeIncreaseAllowance(
            MASTER_CHEF,
            type(uint256).max - IERC20(bpToken).allowance(address(this), MASTER_CHEF)
        );
        IERC20(REWARD_TOKEN).safeIncreaseAllowance(
            SPIRIT_ROUTER,
            type(uint256).max - IERC20(REWARD_TOKEN).allowance(address(this), SPIRIT_ROUTER)
        );
        IERC20(WFTM).safeIncreaseAllowance(
            SPOOKY_ROUTER,
            type(uint256).max - IERC20(WFTM).allowance(address(this), SPOOKY_ROUTER)
        );
        for (uint256 i; i < totalUnderlyingTokens; i++) {
            
                IERC20(bptUnderlyingTokens[i])
                .safeIncreaseAllowance(
                    BEET_VAULT,
                    type(uint256).max - IERC20(bptUnderlyingTokens[i]).allowance(address(this), BEET_VAULT)
                );
            
        }
    }

    /**
     * @dev Set all allowances to 0
     */
    function _removeAllowances() internal {
        IERC20(bpToken).safeDecreaseAllowance(
            MASTER_CHEF,
            IERC20(bpToken).allowance(address(this), MASTER_CHEF)
        );
        IERC20(REWARD_TOKEN).safeDecreaseAllowance(
            SPIRIT_ROUTER,
            IERC20(REWARD_TOKEN).allowance(address(this), SPIRIT_ROUTER)
        );
        IERC20(WFTM).safeDecreaseAllowance(
            SPOOKY_ROUTER,
            IERC20(WFTM).allowance(address(this),SPOOKY_ROUTER)
        );
        for (uint256 i; i < totalUnderlyingTokens; i++) {
            
                IERC20(bptUnderlyingTokens[i])
                .safeDecreaseAllowance(
                    BEET_VAULT,
                    IERC20(bptUnderlyingTokens[i]).allowance(address(this), BEET_VAULT)
                );
            
        }
    }
}
