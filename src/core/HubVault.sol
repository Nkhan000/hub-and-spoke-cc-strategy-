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

/**
 * @title HubVault
 * @author Nazir Khan
 * @notice Receives ERC20 token from liquidity providers and spoke vaults on from different chain use the funds in the different strategies to yield profits
 */

contract HubVault is ERC4626, Ownable, ReentrancyGuard, Pausable, CCIPReceiver {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ERRORS
    error HubVault__AmountMustBeMoreThanZero();
    error HubVault__FundsAllocationFailed();
    error HubVault__StrategyNotAllowed(address strategy);
    error HubVault__WithdrawalFailed(address strategy);

    error HubVault__SpokeNotAllowed(address spoke);
    error HubVault__OnlySpokesReceiveShares();
    error HubVault__OnlySpokesWithdrawAssets();

    error HubVault__CanNotDirectlyWithdrawCrossChain();

    error HubVault__AssetsMisMatched(uint256 minted, uint256 expected);
    error HubVault__ChainSelectorNotAllowed(address spoke);
    error HubVault__RecieverMustBeTheSender(
        address receiver,
        address msgSender
    );
    error HubVault__InsufficientFundsToWithdraw();

    error HubVault__NotMsgSenderOrSpoke(address spoke);
    error HubVault__NotMsgSenderOrOwner(address spoke);
    error HubVault__NotEnoughSpokeBalances();
    error HubVault__NotEnoughProfitAccrued();

    error HubVault__InvalidChainSelector(uint256 destChainSelector);
    error HubVault__InvalidOpcode();
    error HubVault__InvalidTokenCCIP();
    error HubVault__TokensMisMatchCCIP();

    uint256 constant PERFORMANCE_FEE = 300;

    uint256 immutable i_MIN_PROFIT;
    uint256 private totalAllocations; // total amount allocated to strategies
    uint256 private totalFeesCollected; // amount collected from profits generated for the owner

    uint256 private totalSpokeDeposits; // total balance of spoke vaults deposited

    uint256 private totalProfitAfterFee; // total profits collected from strategies after deducting protocol fee
    uint256 private totalRealizedLosses; // total loss from profits

    address public immutable i_linkToken; //

    address public immutable i_tokenPool; // address of token pool on this chain
    address public immutable i_router; // address to router client from ccip

    // maps all allocations to the strategy
    mapping(address => uint256) internal strategyAllocations;
    //
    mapping(address => bool) internal isAllowedStrategy;
    // spoke vaults deposits mapping
    mapping(address => uint256) internal spokesDeposit;
    //
    mapping(address => bool) internal isAllowedSpoke;
    //
    mapping(address => uint64) internal spokeChainSelectors;
    //
    mapping(address => uint256) internal spokesProfit;

    // arrays
    EnumerableSet.AddressSet private allStrategies;
    EnumerableSet.AddressSet private allSpokeVaults;

    /// EVENTS
    event StrategyAdded(address _strategy);
    event SpokeAdded(address _spoke);
    event StrategyRemoved(address _strategy);
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
    )
        ERC4626(_asset)
        CCIPReceiver(_router)
        ERC20("Cross Token", "CT")
        Ownable(msg.sender)
    {
        require(_tokenPool != address(0), "Invalid token pool address");

        i_MIN_PROFIT = 20 * 10 ** decimals();
        i_tokenPool = _tokenPool;
        i_linkToken = _linkToken;
    }

    /////////////// modifiers
    modifier allowedStrategy(address strategy) {
        require(
            isAllowedStrategy[strategy],
            HubVault__StrategyNotAllowed(strategy)
        );
        _;
    }

    modifier notZeroAmount(uint256 amount) {
        require(amount > 0, HubVault__AmountMustBeMoreThanZero());
        _;
    }

    modifier allowedSpoke(address spoke) {
        require(isAllowedSpoke[spoke], HubVault__SpokeNotAllowed(spoke));
        _;
    }

    modifier allowedSpokeAndSender(address spoke) {
        require(
            isAllowedSpoke[spoke] && msg.sender == spoke,
            HubVault__NotMsgSenderOrSpoke(spoke)
        );
        _;
    }

    // add strategies like Uniswap or AAVE
    function addStrategy(address _strategy) external onlyOwner nonReentrant {
        require(!isAllowedStrategy[_strategy], "Strategy already listed");
        require(allStrategies.add(_strategy), "Failed to add strategy");

        isAllowedStrategy[_strategy] = true;
        emit StrategyAdded(_strategy);
    }

    function removeStrategy(
        address _strategy
    ) external onlyOwner nonReentrant whenPaused {
        require(isAllowedStrategy[_strategy], "Strategy already removed");
        require(allStrategies.remove(_strategy), "Failed to remove strategy");
        require(strategyAllocations[_strategy] == 0, "withdraw funds first");
        delete isAllowedStrategy[_strategy];

        emit StrategyRemoved(_strategy);
    }

    function addSpoke(
        address _spoke,
        uint64 chainSelector
    ) external onlyOwner nonReentrant {
        require(!isAllowedSpoke[_spoke], "Spoke already listed");
        require(allSpokeVaults.add(_spoke), "Failed to add spoke");
        require(chainSelector == 0, "Chain selector can not be zero");

        spokeChainSelectors[_spoke] = chainSelector;
        isAllowedSpoke[_spoke] = true;
        // emit event
        emit SpokeAdded(_spoke);
    }

    function removeSpoke(
        address _spoke
    ) external onlyOwner nonReentrant whenPaused {
        require(isAllowedSpoke[_spoke], "Spoke already removed");
        require(allSpokeVaults.remove(_spoke), "Failed to remove spoke");

        delete isAllowedSpoke[_spoke];
        delete spokeChainSelectors[_spoke];

        // Optionally: Transfer remaining balance to owner or spoke
        uint256 amount = spokesDeposit[_spoke];
        if (amount > 0) {
            spokesDeposit[_spoke] = 0;
            totalSpokeDeposits -= amount;
            IERC20(asset()).safeTransfer(_spoke, amount);
        }
        emit SpokeRemoved(_spoke);
    }

    //////////////////////////////////
    /////// STRATEGY MANAGEMENT /////
    ////////////////////////////////

    function allocateFundsToStrategy(
        address strategy,
        uint256 amount
    ) external onlyOwner whenNotPaused nonReentrant allowedStrategy(strategy) {
        // CHECKS
        require(
            amount <= IERC20(asset()).balanceOf(address(this)),
            "Insufficient funds in the vault"
        );

        // EFFECTS
        unchecked {
            strategyAllocations[strategy] += amount;
            totalAllocations += amount;
        }

        // INTERACTION
        IERC20(asset()).approve(strategy, amount);
        bool success = IStrategy(strategy).deposit(amount); // strategy pulls asset
        require(success, HubVault__FundsAllocationFailed());

        emit StrategyFundsAllocated(strategy, amount);
    }

    // it assumes that strategy contract has allowed to transfer funds to this contract
    function withdrawFromStrategy(
        address strategy,
        uint256 amount
    ) public onlyOwner nonReentrant whenNotPaused allowedStrategy(strategy) {
        _harvest(strategy); // settles all profits and losses made
        require(
            strategyAllocations[strategy] >= amount,
            "Not enough allocated"
        );
        uint256 totalAllocated = strategyAllocations[strategy];
        require(totalAllocated > 0, "Strategy has no funds");

        // Sync allocations with actual strategy state
        // In case of emergency withdraw
        if (amount == type(uint256).max) {
            strategyAllocations[strategy] = 0;
            totalAllocations -= totalAllocated;
            bool success = IStrategy(strategy).withdrawAll();
            require(success, HubVault__WithdrawalFailed(strategy));
        } else {
            // EFFECTS
            strategyAllocations[strategy] -= amount;
            totalAllocations -= amount;

            // TODO
            bool success = IStrategy(strategy).withdraw(amount);
            require(success, HubVault__WithdrawalFailed(strategy));
        }

        emit StrategyFundsWithdrawn(strategy, amount);
    }

    // This functions should collect the acrued profit from the strategy to this vault
    function _harvest(
        address strategy
    ) internal onlyOwner nonReentrant whenNotPaused allowedStrategy(strategy) {
        uint256 initialVaultBalance = IERC20(asset()).balanceOf(address(this));

        // reports profit or loss
        (uint256 profit, uint256 loss) = IStrategy(strategy)
            .reportProfitAndLoss();

        require(
            profit == 0 || loss == 0,
            "Profit and loss cannot both be non-zero"
        ); // Enforces mutual exclusivity

        if (profit > 0) {
            require(profit >= i_MIN_PROFIT, "NOT ENOUGH PROFIT");

            IStrategy(strategy).collectAllProfits();
            // verify profit was transfered
            uint256 received = IERC20(asset()).balanceOf(address(this)) -
                initialVaultBalance;
            require(received >= profit, "Profit not received");

            // Calculate and record fee
            uint256 fee = (profit * PERFORMANCE_FEE) / 10000;
            require(fee <= profit, "Invalid performance fee");

            totalFeesCollected += fee;

            totalProfitAfterFee += profit - fee;
            _distributeProfitAmongSpokes();

            emit ProfitsCollected(strategy, profit, fee);
        } else if (loss > 0) {
            //
            require(
                strategyAllocations[strategy] >= loss,
                "Losses exceeds allocations"
            );
            strategyAllocations[strategy] -= loss;
            totalAllocations -= loss;
            totalRealizedLosses += loss;

            emit LossRealized(strategy, loss);
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
            spokesProfit[spoke] += profitToPay;
            // decrease the profit to from the total profit
            totalProfit -= profitToPay;

            deposit(profitToPay, spoke);
        }

        uint256 remaining = totalProfit - totalDistributed;
        if (remaining > 0) {
            totalFeesCollected += remaining;
            totalProfit = 0;
        }
    }

    ///////////// LOCAL FUNCTIONS FOR SPOKES FOR  /////////////////////
    ///////////// PROFIT AND DEPOSIT WITHDRAWALS /////////////////////

    ///////////////////////////////////////////////////////
    /////////////////// OWNER CLAIMS /////////////////////
    /////////////////////////////////////////////////////

    // transfer collected fees to the owner
    function claimFees(
        address to
    ) external onlyOwner whenNotPaused nonReentrant {
        require(to != address(0), "Invalid address");
        uint256 amount = totalFeesCollected;
        require(amount > 0, "Not Enough Amount to Collect");

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
        address receiver // sender of the tokens cross chain passed as a receiver
    )
        public
        override
        nonReentrant
        whenNotPaused
        notZeroAmount(assets)
        returns (uint256)
    {
        uint256 shares;
        // if msg.sender is this contract than it is a cross chain operation
        if (msg.sender == address(this)) {
            shares = super.deposit(assets, address(this));
        } else {
            // else it is a native operation
            if (receiver != msg.sender)
                revert HubVault__OnlySpokesReceiveShares();
            shares = super.deposit(assets, receiver);
        }
        _afterDeposit(assets, receiver);

        emit DepositSuccessfull(receiver, assets);

        return shares;
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256) {
        uint256 expectedAssets = previewMint(shares);
        uint256 assetsMinted;
        if (msg.sender == address(this)) {
            // if (!isAllowedSpoke[receiver])
            //     revert HubVault__SpokeNotAllowed(receiver);
            assetsMinted = super.mint(shares, address(this));
        } else {
            //
            if (!isAllowedSpoke[msg.sender])
                revert HubVault__SpokeNotAllowed(msg.sender);
            if (receiver == msg.sender)
                revert HubVault__OnlySpokesReceiveShares();
            assetsMinted = super.mint(shares, msg.sender);
        }
        if (assetsMinted < expectedAssets)
            revert HubVault__AssetsMisMatched(assetsMinted, expectedAssets);
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
        allowedSpoke(owner)
        returns (uint256)
    {
        // here msg.sender should be the called of this function tokens are being sent cross chain
        // also receiver should also be the address(this) as can not do .safeTransfer to a cross chain contract
        if (spokesDeposit[owner] < assets)
            revert HubVault__InsufficientFundsToWithdraw();
        // cross chain transfer
        if (msg.sender == address(this)) {
            // burn shares from this contract based on amount of deposit made
            // sends the token back to this contract from this contract
            uint256 shares = super.withdraw(
                assets,
                address(this), // receiver of the asset is this contract
                address(this) // owner of the shares is this contract
            );

            spokesDeposit[owner] -= assets; // updates the balance of spoke
            totalSpokeDeposits -= assets; // updates the total deposits of all spokes
            _sendCrossChain(owner, assets); // sends the tokens cross chain
            emit AssetsWithdrawnSharesBurnt(assets, shares);
            return shares;
            // called from a native spoke vault
        } else {
            unchecked {
                spokesDeposit[owner] -= assets;
                totalSpokeDeposits -= assets;
            }
            uint256 shares = super.withdraw(assets, receiver, owner);
            emit AssetsWithdrawnSharesBurnt(assets, shares);
            return shares;
        }
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
        allowedSpokeAndSender(owner)
        notZeroAmount(shares)
        returns (uint256)
    {
        // uint256 assets = previewRedeem(shares);
        if (msg.sender == address(this)) {
            // TODO
        } else {
            uint256 assets = super.redeem(shares, receiver, owner);
            // _beforeWithdraw();
            require(
                spokesDeposit[owner] >= assets,
                "Insufficient funds to withdraw"
            );

            spokesDeposit[owner] -= assets;
            totalSpokeDeposits -= assets;

            emit AssetsWithdrawnSharesBurnt(assets, shares);
            return assets;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HOOKS LOGIC                     
    //////////////////////////////////////////////////////////////*/

    function _sendCrossChain(
        address _spoke,
        uint256 _amountToPay
    ) internal returns (bool, bytes32) {
        uint64 destChainSelector = spokeChainSelectors[_spoke];
        if (destChainSelector == 0)
            revert HubVault__InvalidChainSelector(destChainSelector);

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
            feeToken: i_linkToken
        });

        uint256 fee = IRouterClient(i_router).getFee(
            destChainSelector,
            message
        );

        IERC20(i_linkToken).approve(i_router, fee);
        IERC20(asset()).approve(i_tokenPool, _amountToPay);

        bytes32 messageId = IRouterClient(i_router).ccipSend(
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
        unchecked {
            spokesDeposit[receiver] += assets;
            totalSpokeDeposits += assets;
        }
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
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
