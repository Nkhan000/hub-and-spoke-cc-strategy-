// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../strategies/IStrategy.sol";
import {Client} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title HubVault
 * @author Nazir Khan
 * @notice Receives ERC20 token from liquidity providers and spoke vaults on from different chain use the funds in the different strategies to yield profits
 */

contract HubVault is
    ERC4626,
    AccessControl,
    ReentrancyGuard,
    Pausable,
    CCIPReceiver
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Required to resolve multiple inheritance of supportsInterface
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, CCIPReceiver) returns (bool) {
        return
            AccessControl.supportsInterface(interfaceId) ||
            CCIPReceiver.supportsInterface(interfaceId);
    }

    // ERRORS
    error HubVault__AmountMustBeMoreThanZero();
    error HubVault__FundsAllocationFailed();
    error HubVault__StrategyNotAllowed(address strategy);
    error HubVault__WithdrawalFailed(address strategy);

    error HubVault__SpokeNotAllowed(address spoke);
    error HubVault__OnlySpokesReceiveShares();
    error HubVault__OnlySpokesWithdrawAssets();
    error HubVault__TooManySpokes();

    error HubVault__CanNotDirectlyWithdrawCrossChain();

    error HubVault__AssetsMisMatched(uint256 minted, uint256 expected);
    error HubVault__ChainSelectorNotAllowed(address spoke);
    error HubVault__RecieverMustBeTheSender(
        address receiver,
        address msgSender
    );
    error HubVault__InsufficientFundsToWithdraw();
    error HubVault__WithdrawFundsFirst();

    error HubVault__NotMsgSenderOrSpoke(address spoke);
    error HubVault__NotMsgSenderOrOwner(address spoke);
    error HubVault__NotEnoughSpokeBalances();
    error HubVault__NotEnoughProfitAccrued();

    error HubVault__InvalidChainSelector();
    error HubVault__InvalidOpcode();
    error HubVault__InvalidTokenCCIP();
    error HubVault__TokensMisMatchCCIP();
    error HubVault__InvalidAddress();

    // ============================================
    // ROLES
    // ============================================

    bytes32 public constant HARVESTER_ROLE = keccak256("HARVESTER");
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER");

    // ============================================
    // CONSTANTS
    // ============================================
    uint256 public constant PERFORMANCE_FEE = 300; // 3%
    uint256 public constant MAX_PERFORMANCE_FEE = 2000; // 20% cap
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_STRATEGIES = 3;
    uint256 public constant MAX_SPOKES = 4;
    uint256 public constant PROFIT_DISTRIBUTION_THRESHOLD = 100e18;
    uint256 public constant MAX_SPOKES_PER_DISTRIBUTION = 50;
    uint256 public constant MINIMUM_DEPOSIT = 1e6; // 1 USDC minimum
    uint256 public constant VIRTUAL_SHARES = 1e3;
    uint256 public constant VIRTUAL_ASSETS = 1;
    uint256 public constant MIN_LINK_THRESHOLD = 10e18; // 10 LINK
    uint256 public constant MAX_RETRIES = 3;
    uint256 public constant RETRY_DELAY = 1 hours;
    uint256 public constant WITHDRAWAL_DELAY = 10 minutes;
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // ============================================
    // IMMUTABLES
    // ============================================
    uint256 public immutable MIN_PROFIT;
    address public immutable LINK_TOKEN;
    address public immutable TOKEN_POOL;
    address public immutable ROUTER;

    // ============================================
    // STATE VARIABLES - Storage Layout Optimized
    // ============================================

    // Slot 1-4: Basic accounting
    uint256 public totalAllocations;
    uint256 public totalFeesCollected;
    uint256 public totalSpokeDeposits;
    uint256 private totalProfitAfterFee; // total profits collected from strategies after deducting protocol fee

    // Slot 5-8: Tracking variables
    uint256 public totalRealizedLosses;
    uint256 public lastHarvestTimestamp;
    uint256 public lastDistributionIndex;
    uint256 public totalWithdrawalRequests;

    // Slot 9-10: Configuration
    uint256 public minHarvestInterval;
    uint256 public maxSlippageBps;

    // Slot 11: Packed booleans
    bool public emergencyMode;
    bool public distributionInProgress;

    // ============================================
    // MAPPINGS
    // ============================================

    // Strategy mappings
    mapping(address => uint256) public strategyAllocations;
    mapping(address => bool) public isAllowedStrategy;
    mapping(address => bool) public strategyPaused;
    mapping(address => StrategyInfo) public strategyInfo;

    // spoke vaults deposits mapping
    mapping(address => uint256) internal spokesDeposit;
    mapping(address => uint64) internal spokeChainSelectors;
    mapping(address => bool) internal isAllowedSpoke;
    mapping(address => SpokeInfo) public spokeInfo;

    // CCIP mappings
    mapping(uint64 => uint256) public chainGasLimits;
    // mapping(bytes32 => FailedMessage) public failedMessages;

    // Withdrawal queue mappings
    mapping(address => uint256[]) public spokeWithdrawalRequests;
    mapping(uint256 => WithdrawalRequest) public withdrawalQueue;

    // Timelock mappings
    // mapping(bytes32 => TimelockOperation) public timelockOps;

    // arrays
    EnumerableSet.AddressSet private allStrategies;
    EnumerableSet.AddressSet private allSpokeVaults;

    // ============================================
    // STRUCTS
    // ============================================

    struct StrategyInfo {
        uint256 allocation;
        uint256 totalProfit;
        uint256 totalLoss;
        uint256 lastHarvest;
        uint256 consecutiveLosses;
        bool isActive;
    }

    struct WithdrawalRequest {
        address spoke;
        uint256 amount;
        uint256 shares;
        uint256 requestTime;
        uint256 priority; // Higher for longer-term depositors
        bool fulfilled;
    }

    struct SpokeInfo {
        uint256 deposits;
        uint256 shares;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
        uint64 chainSelector;
    }

    // ===================================

    /// EVENTS
    event StrategyAdded(address _strategy);
    event SpokeAdded(address _spoke);
    event StrategyRemoved(address _strategy, uint256 timestamp);
    event SpokeRemoved(address _spoke);

    event StrategyFundsAllocated(address strategy, uint256 amount);
    event StrategyFundsWithdrawn(address strategy, uint256 amount);

    event ProfitsCollected(address strategy, uint256 profit, uint256 fee);
    event LossRealized(address strategy, uint256 loss);
    event FeesCollected(address to, uint256 amount);

    event AssetsWithdrawnSharesBurnt(uint256 assets, uint256 shares);
    event DepositSuccessfull(address spoke, uint256 assets);
    event AssetsDepositedSharesMinted(
        address receiver,
        uint256 assetsMinted,
        uint256 shares
    );

    // event ProfitClaimed(address spoke, uint256 amount);
    // event DistributedAllDepositsAndProfits(address spoke, uint256 amountToPay);

    event CCIPMessageSent(
        bytes32 messageId,
        address _spoke,
        uint256 _amountToPay,
        uint64 destChainSelector
    );

    // CONSTRUCTOR
    constructor(
        IERC20 _asset,
        address _router,
        address _linkToken,
        address _tokenPool
    ) ERC4626(_asset) CCIPReceiver(_router) ERC20("Cross Token", "CT") {
        if (
            _tokenPool == address(0) ||
            ROUTER == address(0) ||
            _linkToken == address(0)
        ) revert HubVault__InvalidAddress();

        MIN_PROFIT = 20 * 10 ** decimals();
        TOKEN_POOL = _tokenPool;
        LINK_TOKEN = _linkToken;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(HARVESTER_ROLE, msg.sender);
        _grantRole(ALLOCATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
    }

    /////////////// modifiers
    modifier onlyAllowedStrategy(address strategy) {
        if (!isAllowedStrategy[strategy])
            revert HubVault__StrategyNotAllowed(strategy);
        _;
    }

    modifier onlyAllowedSpoke(address spoke) {
        if (isAllowedSpoke[spoke]) revert HubVault__SpokeNotAllowed(spoke);
        _;
    }

    modifier notZeroAmount(uint256 amount) {
        if (amount == 0) revert HubVault__AmountMustBeMoreThanZero();
        _;
    }

    modifier allowedSpokeAndSender(address spoke) {
        require(
            isAllowedSpoke[spoke] && msg.sender == spoke,
            HubVault__NotMsgSenderOrSpoke(spoke)
        );
        _;
    }

    // ============================================
    // STRATEGY MANAGEMENT
    // ============================================

    // add strategies like Uniswap or AAVE
    function addStrategy(
        address _strategy
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (_strategy == address(0)) revert HubVault__InvalidAddress();
        if (isAllowedStrategy[_strategy])
            revert HubVault__StrategyNotAllowed(_strategy);
        if (!allStrategies.add(_strategy)) revert("Failed to add strategy");

        isAllowedStrategy[_strategy] = true;
        strategyInfo[_strategy] = StrategyInfo({
            allocation: 0,
            totalProfit: 0,
            totalLoss: 0,
            lastHarvest: block.timestamp,
            consecutiveLosses: 0,
            isActive: true
        });
        emit StrategyAdded(_strategy);
    }

    function removeStrategy(
        address _strategy
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenPaused {
        if (!isAllowedStrategy[_strategy])
            revert HubVault__StrategyNotAllowed(_strategy);
        if (strategyAllocations[_strategy] != 0)
            revert HubVault__WithdrawFundsFirst();
        if (!allStrategies.remove(_strategy))
            revert("Failed to remove strategy");

        delete isAllowedStrategy[_strategy];
        strategyInfo[_strategy].isActive = false;

        emit StrategyRemoved(_strategy, block.timestamp);
    }

    // ============================================
    // SPOKE MANAGEMENT
    // ============================================

    function addSpoke(
        address _spoke,
        uint64 chainSelector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (_spoke == address(0)) revert HubVault__InvalidAddress();
        if (isAllowedSpoke[_spoke]) revert HubVault__SpokeNotAllowed(_spoke); // spoke already exists maybe a better error message would do
        if (chainSelector == 0) revert HubVault__InvalidChainSelector();
        if (allSpokeVaults.length() >= MAX_SPOKES)
            revert HubVault__TooManySpokes();
        if (!allSpokeVaults.add(_spoke)) revert("Failed to add spoke");

        isAllowedSpoke[_spoke] = true;
        spokeInfo[_spoke] = SpokeInfo({
            deposits: 0,
            shares: 0,
            unclaimedProfit: 0,
            lastDeposit: block.timestamp,
            lastWithdrawal: block.timestamp,
            chainSelector: chainSelector
        });

        emit SpokeAdded(_spoke);
    }

    function removeSpoke(
        address _spoke
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenPaused {
        if (!isAllowedSpoke[_spoke]) revert HubVault__SpokeNotAllowed(_spoke);
        if (!allSpokeVaults.remove(_spoke)) revert("Failed to remove spoke");

        SpokeInfo memory s = spokeInfo[_spoke];
        uint256 deposits = s.deposits;
        uint256 unclaimedProfit = s.unclaimedProfit;

        uint256 totalBalanceToPay = deposits + unclaimedProfit;

        delete isAllowedSpoke[_spoke]; //
        delete spokeChainSelectors[_spoke]; //
        delete spokeInfo[_spoke]; //

        if (totalBalanceToPay > 0) {
            if (
                s.chainSelector != 0 && s.chainSelector != uint64(block.chainid)
            ) {
                // send cross chain
                withdraw(totalBalanceToPay, address(this), _spoke); // burn the shares that was minted to this contract
                _sendCrossChain(_spoke, totalBalanceToPay);
            } else {
                // native transfer
                super.withdraw(totalBalanceToPay, _spoke, _spoke); // burn the erc4626 vault shares and transfer underlying assets
            }
        }
        totalSpokeDeposits -= deposits;
        emit SpokeRemoved(_spoke);
    }

    //////////////////////////////////
    /////// STRATEGY MANAGEMENT /////
    ////////////////////////////////

    function allocateFundsToStrategy(
        address strategy,
        uint256 amount
    )
        external
        onlyRole(ALLOCATOR_ROLE)
        whenNotPaused
        nonReentrant
        onlyAllowedStrategy(strategy)
        notZeroAmount(amount)
    {
        // CHECKS
        if (amount > IERC20(asset()).balanceOf(address(this)))
            revert("Insufficient funds in the vault");

        // EFFECTS
        strategyInfo[strategy].allocation += amount;
        totalAllocations += amount;

        // INTERACTION
        IERC20(asset()).approve(strategy, amount);
        bool success = IStrategy(strategy).deposit(amount); // strategy pulls asset
        if (!success) revert HubVault__FundsAllocationFailed();

        emit StrategyFundsAllocated(strategy, amount);
    }

    function withdrawFromStrategy(
        address strategy,
        uint256 amount
    )
        public
        onlyRole(ALLOCATOR_ROLE)
        nonReentrant
        whenNotPaused
        onlyAllowedStrategy(strategy)
    {
        _harvest(strategy); // settles all profits and losses made
        StrategyInfo storage s = strategyInfo[strategy];
        bool success;

        // In case of emergency withdraw
        if (amount == type(uint256).max) {
            totalAllocations -= s.allocation;
            s.allocation = 0;
            success = IStrategy(strategy).withdrawAll();
        } else {
            if (amount > s.allocation) revert("Not enough allocated");
            // EFFECTS
            totalAllocations -= amount;
            s.allocation -= amount;
            success = IStrategy(strategy).withdraw(amount);
        }
        if (!success) revert HubVault__WithdrawalFailed(strategy);

        emit StrategyFundsWithdrawn(strategy, amount);
    }

    // ============================================
    // HARVEST & PROFIT MANAGEMENT
    // ============================================
    // This functions should collect the acrued profit from the strategy to this vault
    function _harvest(
        address strategy
    )
        internal
        onlyRole(HARVESTER_ROLE)
        nonReentrant
        whenNotPaused
        onlyAllowedStrategy(strategy)
    {
        if (
            block.timestamp <
            strategyInfo[strategy].lastHarvest + minHarvestInterval
        ) {
            return; // minimum harvesting interval not reached yet
        }
        uint256 initialVaultBalance = IERC20(asset()).balanceOf(address(this));

        // reports profit or loss
        (uint256 profit, uint256 loss) = IStrategy(strategy)
            .reportProfitAndLoss();

        if (profit > 0 || loss > 0)
            revert("Profit and loss cannot both be non-zero"); // Enforces mutual exclusivity
        StrategyInfo storage s = strategyInfo[strategy];

        if (profit > 0) {
            if (profit < MIN_PROFIT) revert("NOT ENOUGH PROFIT");

            IStrategy(strategy).collectAllProfits();
            // verify profit was transfered
            uint256 received = IERC20(asset()).balanceOf(address(this)) -
                initialVaultBalance;
            if (received < profit) revert("Profits Withdrawal Failed");

            // Calculate and record fee
            uint256 fee = (profit * PERFORMANCE_FEE) / BASIS_POINTS;
            if (fee >= profit) revert("Invalid performance fee");

            totalFeesCollected += fee;
            uint256 profitAfterFee = profit - fee;
            totalProfitAfterFee += profitAfterFee;

            s.totalProfit += profit;
            s.lastHarvest = block.timestamp;
            s.consecutiveLosses = 0; // Reset loss counter
            lastHarvestTimestamp = block.timestamp;

            // Auto-distribute if threshold reached
            if (totalProfitAfterFee >= PROFIT_DISTRIBUTION_THRESHOLD) {
                _distributeProfitAmongSpokes();
            }

            emit ProfitsCollected(strategy, profit, fee);
        } else if (loss > 0) {
            uint256 preLossAllocations = s.allocation;

            if (preLossAllocations < loss) {
                revert("AllocationsExceedsBalance");
            }
            //
            s.allocation -= loss;
            totalAllocations -= loss;
            totalRealizedLosses += loss;
            s.totalLoss += loss;
            s.lastHarvest = block.timestamp;
            s.consecutiveLosses++;

            emit LossRealized(strategy, loss);

            // based on lossCounter may discontinue the or pause the strategy for few period of time
        }
    }

    // @notice this function is called internally to distribute profit among spokes. This does not transfer any tokens to spoke address but updates internal mapping which will than later be used for profit distribution
    function _distributeProfitAmongSpokes() internal {
        address[] memory spokes = allSpokeVaults.values();
        uint256 totalDistributed;
        uint256 totalProfit = totalProfitAfterFee;

        for (uint16 i = 0; i < spokes.length; ++i) {
            address spoke = spokes[i];
            uint256 profitToPay = (spokesDeposit[spoke] * totalProfit) /
                totalSpokeDeposits;

            // increase total profit distributed for dust calculation at the end
            totalDistributed += profitToPay;
            // add the profit to the spokes profits mapping for quick
            SpokeInfo storage s = spokeInfo[spoke];
            s.unclaimedProfit += profitToPay;
            // decrease the profit to from the total profit
            totalProfit -= profitToPay;
        }

        uint256 remaining = totalProfit - totalDistributed;
        if (remaining > 0) {
            totalFeesCollected += remaining;
            totalProfitAfterFee = 0;
        }
        // emit
    }

    function claimProfitFor(address spoke) internal {
        SpokeInfo storage s = spokeInfo[spoke];
        uint256 profitToPay = s.unclaimedProfit;

        if (profitToPay == 0) return;

        s.unclaimedProfit = 0;
        totalSpokeDeposits += profitToPay;

        deposit(profitToPay, spoke);

        // emit profitClaimed
    }

    ///////////// LOCAL FUNCTIONS FOR SPOKES FOR  /////////////////////
    ///////////// PROFIT AND DEPOSIT WITHDRAWALS /////////////////////

    ///////////////////////////////////////////////////////
    /////////////////// ADMIN FUNCTIONS //////////////////
    /////////////////////////////////////////////////////

    // transfer collected fees to the owner
    function claimFees(
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert("Invalid address");
        uint256 amount = totalFeesCollected;
        if (amount == 0) revert("Not Enough Amount to Collect");

        totalFeesCollected = 0;
        IERC20(asset()).approve(to, amount);
        IERC20(asset()).safeTransfer(to, amount);

        emit FeesCollected(to, amount);
    }

    /////////////////////////////////////////////////
    // DEPOSIT / REDEEMING / MINTING VAULT TOKENS //
    ///////////////////////////////////////////////

    // if called after tokens received via cross chain transfer -> msg.sender -> address(this)
    // if called by a native spoke -> msg.sender -> address of spoke
    // here for cross chain shares are minted to address of this contract but internal accounting for deposit balance is increased for the cross chain spoke as direct deposit is not possible.
    // In future withdrawals even if erc4626 withdraw may burn shares from the receiver (spoke on other chain), can not transfer underlying asset using .safeTransfer()
    // thats why shares are minted to this contract and later will be sent back to the spoke when withdraw using cross chain operation

    function deposit(
        uint256 assets,
        address receiver // sender of the tokens cross chain or native passed as a receiver (spoke)
    )
        public
        override
        nonReentrant
        whenNotPaused
        notZeroAmount(assets)
        returns (uint256)
    {
        uint256 shares;
        uint256 expectedShares = previewDeposit(assets);
        uint64 chainSelector = spokeInfo[receiver].chainSelector;
        // if chain selector is for different chain than deposit on behalf of that spoke vault and mint shares to this contract
        // if not then spoke is a native spoke and mint shares to them directly.

        if (chainSelector != 0 && chainSelector != uint64(block.chainid)) {
            // it is spoke on different chain
            shares = super.deposit(assets, address(this));
        } else {
            if (receiver != msg.sender)
                revert HubVault__OnlySpokesReceiveShares();
            shares = super.deposit(assets, receiver);
        }
        require(shares >= expectedShares, "Slippage exceeded"); // Protection
        _afterDeposit(assets, receiver);

        emit DepositSuccessfull(receiver, assets);
        return shares;
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256) {
        uint256 assetsMinted;
        uint256 expectedAssets = previewMint(shares);

        uint64 chainSelector = spokeInfo[receiver].chainSelector;
        if (chainSelector != 0 && chainSelector != uint64(block.chainid)) {
            // it is a cross chain spoke
            assetsMinted = super.mint(shares, address(this));
        } else {
            if (!isAllowedSpoke[msg.sender])
                revert HubVault__SpokeNotAllowed(msg.sender);
            if (receiver != msg.sender)
                revert HubVault__OnlySpokesReceiveShares();
            assetsMinted = super.mint(shares, receiver);
        }
        // maybe add some slippage protection here, revert if not minted
        require(assetsMinted >= expectedAssets, "Slippage exceeded");

        _afterDeposit(assetsMinted, receiver);

        emit AssetsDepositedSharesMinted(receiver, assetsMinted, shares);
        return assetsMinted;
    }

    // @notice currently there is no slippage protection to this function but we'll add soon
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        whenNotPaused
        onlyAllowedSpoke(owner)
        notZeroAmount(assets)
        returns (uint256)
    {
        // here msg.sender should be the called of this function tokens are being sent cross chain
        // also receiver should also be the address(this) as can not do .safeTransfer to a cross chain contract

        uint256 sharesBurnt;
        uint256 expectedSharesToBurn = previewWithdraw(assets);
        SpokeInfo storage s = spokeInfo[owner];

        uint64 chainSelector = s.chainSelector;
        bool isCrossChain = chainSelector != 0 &&
            chainSelector != uint64(block.chainid);

        if (isCrossChain) {
            sharesBurnt = super.withdraw(assets, address(this), address(this));
            _sendCrossChain(owner, assets);
        } else {
            sharesBurnt = super.withdraw(assets, receiver, owner);
        }
        require(sharesBurnt >= expectedSharesToBurn, "Slippage Exceeds");

        unchecked {
            s.deposits -= assets;
            totalSpokeDeposits -= assets;
        }
        s.lastWithdrawal = block.timestamp;
        emit AssetsWithdrawnSharesBurnt(assets, sharesBurnt);
        return sharesBurnt;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        whenNotPaused
        onlyAllowedSpoke(owner)
        notZeroAmount(shares)
        returns (uint256)
    {
        uint256 assets;
        uint256 expectedAssets = previewRedeem(shares);
        SpokeInfo storage s = spokeInfo[owner];

        uint64 chainSelector = s.chainSelector;
        bool isCrossChain = chainSelector != 0 &&
            chainSelector != uint64(block.chainid);

        if (isCrossChain) {
            assets = super.redeem(shares, address(this), address(this));
            _sendCrossChain(owner, assets);
        } else {
            assets = super.redeem(shares, receiver, owner);
        }
        require(assets >= expectedAssets, "Slippage Exceeds");

        unchecked {
            s.deposits -= assets;
            totalSpokeDeposits -= assets;
        }
        s.lastWithdrawal = block.timestamp;

        emit AssetsWithdrawnSharesBurnt(assets, shares);
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC                     
    //////////////////////////////////////////////////////////////*/

    function _sendCrossChain(
        address _spoke,
        uint256 _amountToPay
    ) internal returns (bool, bytes32) {
        uint64 destChainSelector = spokeChainSelectors[_spoke];
        if (destChainSelector == 0) revert HubVault__InvalidChainSelector();

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(asset()),
            amount: _amountToPay
        });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_spoke),
            data: abi.encode(_amountToPay),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 1_00_000})
            ),
            feeToken: LINK_TOKEN
        });

        uint256 fee = IRouterClient(ROUTER).getFee(destChainSelector, message);

        IERC20(LINK_TOKEN).approve(ROUTER, fee);
        IERC20(asset()).approve(TOKEN_POOL, _amountToPay);

        bytes32 messageId = IRouterClient(ROUTER).ccipSend(
            destChainSelector,
            message
        );
        emit CCIPMessageSent(
            messageId,
            _spoke,
            _amountToPay,
            destChainSelector
        );

        return (true, messageId);
    }

    // CCIP automatically calls this function when tokens are received (deposited) cross chain
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        address sender = abi.decode(message.sender, (address));
        if (!isAllowedSpoke[sender]) revert HubVault__SpokeNotAllowed(sender);

        if (message.sourceChainSelector != spokeChainSelectors[sender])
            revert HubVault__ChainSelectorNotAllowed(sender);

        if (message.destTokenAmounts[0].token != address(asset()))
            revert HubVault__InvalidTokenCCIP();

        (uint8 opcode, uint256 amount) = abi.decode(
            message.data,
            (uint8, uint256)
        );
        if (
            message.destTokenAmounts.length != 1 ||
            message.destTokenAmounts[0].amount != amount
        ) revert HubVault__TokensMisMatchCCIP();

        // _harvest(strategy);

        if (opcode == uint8(1)) {
            // deposit sent amounts
            deposit(amount, sender);
        } else if (opcode == uint8(2)) {
            // withdraw and send amounts
            withdraw(amount, address(0), sender);
        } else {
            revert HubVault__InvalidOpcode();
        }
        // process deposit => mint shares to spoke vaults
    }

    function _afterDeposit(uint256 assets, address receiver) internal {
        SpokeInfo storage s = spokeInfo[receiver];
        unchecked {
            s.deposits += assets;
        }
        s.lastDeposit = block.timestamp;
    }

    // function _beforeWithdraw() internal {
    //     claimProfits(msg.sender);
    // }

    //////////////////////////////////
    // GETTER FUNCTIONS
    //////////////////////////////////

    function getIsAllowedStrategy(address strategy) public view returns (bool) {
        return isAllowedStrategy[strategy];
    }

    function getFundsAllocatedToStrategy(
        address strategy
    ) public view returns (uint256) {
        return strategyAllocations[strategy];
    }

    function getTotalAllocations() public view returns (uint256) {
        return totalAllocations;
    }

    // revert on native eth transfer
    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }

    // Emergency functions
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
