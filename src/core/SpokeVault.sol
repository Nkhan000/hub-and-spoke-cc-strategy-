// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {CCIPReceiver} from "../../lib/ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "../../lib/ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

import {Client} from "../../lib/ccip/contracts/src/v0.8/ccip/libraries/Client.sol";

interface IHubVault {
    function deposit(
        uint256 asset,
        address receiver
    ) external returns (uint256);

    function withdraw(uint256 asset, address receiver, address owner) external;

    // function settle(address spoke) external;
}

contract SpokeVault is
    ERC4626,
    Ownable,
    Pausable,
    ReentrancyGuard,
    CCIPReceiver
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ERROR
    error SpokeVault__AmountMustBeMoreThanZero();
    error SpokeVault__ZeroAddress();
    error SpokeVault__AmountLessThanMinDeposit(uint256 asset);

    // EVENTS
    event DepositSuccessfull(address lp, uint256 amount);
    event DepositsTransferedToVault(uint256 amount);

    event FundsReceived(uint256 amount);
    event LiquidityProviderAddess(address _provider);
    event ProfitsClaim(address provider, uint256 profitsToPay);

    // STATE VARIABLES
    mapping(address => bool) private providers;
    mapping(address => uint256) private providerBalances;

    uint256 immutable i_MIN_DEPOSIT;
    address public immutable i_linkToken;
    address public immutable i_hub;
    address public immutable i_tokenPool;
    address public immutable i_router;
    uint64 private hubChainSelector;
    address private vault;

    uint256 private totalDeposits; // total deposited amount made by liquidity providers
    uint256 private totalAmountSentToVault; // total amount of assets sent to the vault
    uint256 private totalProfitEarned;

    EnumerableSet.AddressSet private allProviders;

    modifier notZeroAmount(uint256 amount) {
        require(amount > 0, SpokeVault__AmountMustBeMoreThanZero());
        _;
    }

    modifier notZeroAddress(address receiver) {
        require(receiver != address(0), SpokeVault__ZeroAddress());
        _;
    }

    modifier isAllowedProvider(address provider) {
        require(providers[provider] == true, "Provider not allowed");
        _;
    }

    constructor(
        IERC20 asset,
        address _vault,
        uint256 minToken,
        address _router,
        address _hub,
        address _link,
        address _tokenPool
    )
        CCIPReceiver(_router)
        ERC4626(asset)
        ERC20("Spoke Cross Token", "sCT")
        Ownable(msg.sender)
    {
        vault = _vault;
        i_MIN_DEPOSIT = minToken * 10 ** decimals();
        i_hub = _hub;
        i_linkToken = _link;
        i_tokenPool = _tokenPool;
        i_router = _router;
    }

    function setHubChainSelector(uint64 _chainSelector) external onlyOwner {
        hubChainSelector = _chainSelector;
    }

    function addLpProvider(
        address _provider
    ) internal notZeroAddress(_provider) {
        require(!providers[_provider], "Provider already exists");
        require(allProviders.add(_provider), "Failed to add LP");
        providers[_provider] = true;

        emit LiquidityProviderAddess(_provider);
    }
    function removeLpProvider(
        address _provider
    ) internal notZeroAddress(_provider) {
        // require(allProviders.add(_provider), "Failed to add LP");
    }

    // lp deposits underlying assets
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override
        whenNotPaused
        nonReentrant
        notZeroAmount(assets)
        notZeroAddress(receiver)
        returns (uint256)
    {
        address lp = msg.sender;
        if (!providers[lp]) {
            addLpProvider(lp);
        }

        require(
            assets >= i_MIN_DEPOSIT,
            SpokeVault__AmountLessThanMinDeposit(assets)
        );

        uint256 shares = super.deposit(assets, receiver);
        unchecked {
            providerBalances[lp] += assets;
            totalDeposits += assets;
        }

        emit DepositSuccessfull(lp, assets);
        return shares;
    }

    // lp deposits underlying assets and receive exact amount of shares
    function mint(
        uint256 shares,
        address receiver
    )
        public
        override
        nonReentrant
        whenNotPaused
        notZeroAmount(shares)
        notZeroAddress(receiver)
        returns (uint256)
    {
        require(
            previewRedeem(shares) >= i_MIN_DEPOSIT,
            SpokeVault__AmountLessThanMinDeposit(previewRedeem(shares))
        );
        address lp = msg.sender;
        if (!providers[lp]) {
            addLpProvider(lp);
        }
        uint256 assets = super.mint(shares, receiver);
        unchecked {
            providerBalances[lp] += assets;
            totalDeposits += assets;
        }

        emit DepositSuccessfull(lp, assets);
        return assets;
    }

    // lps withdraw underlying assets and burn their shares
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        whenNotPaused
        notZeroAddress(receiver)
        returns (uint256)
    {
        //
        require(msg.sender == owner && providers[owner], "Unauthorized");
        require(totalDeposits > 0, "Not enough amount to withdraw");
        require(
            providerBalances[owner] <= assets,
            "Assets exceeds deposited amount"
        );
        // if withdrawing assets than
        // first settle all the profits earned by this provider
        // transfer the required number of assets than
        // if total deposit becomes zero than remove the liquidity provider from the vault.
        // don't withdraw below the minimum deposit amount if required than transfer all the deposits and remove the provider

        uint256 shares = super.withdraw(assets, receiver, owner);

        //
    }

    // lps withdraw underlying assets agains number of shares and burn the shares
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant whenNotPaused returns (uint256) {
        //
    }

    function whenProfitsReceived() external nonReentrant {}

    // function transferProfit(
    //     address provider
    // ) public isAllowedProvider(provider) nonReentrant whenNotPaused {
    //     require(msg.sender == provider, "Unauthorized");
    //     require(totalProfitEarned > 0, "Not enough profit to withdraw");

    //     uint256 profitsToPay = getAmountToPay(provider);
    //     IERC20(asset()).safeTransfer(provider, profitsToPay);

    //     emit ProfitsClaim(provider, profitsToPay);
    // }

    // CROSS-CHAIN -> HUB VAULT
    // calls deposit function on the vault and receives vault shares for assets sent
    function sendDepositedFunds(
        uint256 _amount
    ) external nonReentrant onlyOwner {
        require(totalDeposits > 0, "Not Enough in Deposit");

        require(
            _amount <= totalDeposits,
            "Amount to send exceeds total deposit"
        );
        totalDeposits -= _amount;
        totalAmountSentToVault += _amount;

        IERC20(asset()).approve(vault, _amount);
        IHubVault(vault).deposit(_amount, vault);

        emit DepositsTransferedToVault(_amount);
    }

    function withdrawDepositedFunds(
        uint256 amount
    ) public onlyOwner nonReentrant {
        uint256 initialBalance = IERC20(asset()).balanceOf(address(this));
        IHubVault(vault).withdraw(amount, address(this), address(this));

        require(
            IERC20(asset()).balanceOf(address(this)) >= amount + initialBalance,
            "Did not receive amount"
        );

        emit FundsReceived(amount);
        // call the internal withdraw function receive underlying tokens along with profits accrued and burn shares
    }

    ////////////////////////////////////////
    ////////////////// INTERNAL

    function _sentToHub(uint8 opcode, uint256 assets) internal {
        require(i_hub != address(0), "i_hub chain not set");

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);

        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(asset()),
            amount: assets
        });

        bytes memory data = abi.encodePacked(opcode, assets, address(this));

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(i_hub),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200_000})
            ),
            feeToken: i_linkToken
        });

        // approving token pool to spend the asset
        IERC20(asset()).approve(i_tokenPool, assets);

        // Compute fee
        uint256 fee = IRouterClient(i_router).getFee(hubChainSelector, message);
        IERC20(i_linkToken).approve(address(i_router), fee);
        IRouterClient(i_router).ccipSend(hubChainSelector, message);
    }

    // function _ccipReceive() internal override {}
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal view override {
        // Accept messages only from destinated chain selector
        require(
            message.sourceChainSelector == hubChainSelector &&
                abi.decode(message.sender, (address)) == i_hub,
            "INVALID SENDER"
        );

        uint256 profitAmount = abi.decode(message.data, (uint256));
        require(
            message.destTokenAmounts.length == 1 &&
                message.destTokenAmounts[0].amount == profitAmount,
            "Token mismatch"
        );

        // process profit => mint shares to LPs
    }

    function getAmountToPay(address provider) public view returns (uint256) {
        return (providerBalances[provider] * totalProfitEarned) / totalDeposits;
    }

    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ADMIN FUNCTION
    function setRouter() public {} // updates cross - chain router

    function setBufferSize() public {}

    //////////////////// GETTERS

    function getTotalDeposits() public view returns (uint256) {
        return totalDeposits;
    }
}
