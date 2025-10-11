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
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
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
    AccessControl,
    Pausable,
    ReentrancyGuard,
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

    // ERROR
    error SpokeVault__AmountMustBeMoreThanZero();
    error SpokeVault__ZeroAddress();
    error SpokeVault__AmountLessThanMinDeposit(uint256 asset);

    // EVENTS
    event DepositSuccessfull(address lp, uint256 amount);
    event DepositsTransferedToVault(uint256 amount);

    event WithdrawSuccessfull(address lp, uint256 amount);

    event LiquidityProviderAdded(address _provider);
    event LiquidityProviderRemoved(address _provider);

    event FundsReceived(uint256 amount);
    event ProfitsClaim(address provider, uint256 profitsToPay);
    event CCIPMessageSent(
        bytes32 messageId,
        address hub,
        uint64 chainSelector,
        uint256 assets,
        uint8 opcode
    );

    mapping(address => bool) private allowedProviders;
    mapping(address => uint256) private providerBalances;
    mapping(address => LiquidityProviderInfo) private providerInfo;

    enum Operations {
        DEPOSIT,
        WITHDRAW
    }

    // ============================================
    // ROLES
    // ============================================

    bytes32 public constant PROVIDER_ROLE = keccak256("LIQUIDITY_PROVIDER");

    // STATE VARIABLES
    uint256 private immutable MIN_DEPOSIT;
    address private immutable LINK_TOKEN;
    address private immutable TOKEN_POOL;
    address private immutable ROUTER;
    uint256 constant MIN_PROFIT = 1e6;
    HubInfo private hubVault;

    uint256 private totalProfitFromHub;
    uint256 private totalDeposits; // total deposited amount made by liquidity providers
    // uint256 private totalAmountSentToVault; // total amount of assets sent to the vault

    EnumerableSet.AddressSet private allProviders;

    struct LiquidityProviderInfo {
        address provider;
        uint256 deposit;
        uint256 unclaimedProfit;
        uint256 lastDeposit;
        uint256 lastWithdrawal;
        bool isActive;
    }

    struct HubInfo {
        address hub;
        uint64 chainSelector;
        uint256 totalAllocation;
        uint256 totalProfitEarned;
        uint256 lastAllocated;
        uint256 lastWithdrawal;
    }

    modifier notZeroAmount(uint256 amount) {
        if (amount == 0) revert SpokeVault__AmountMustBeMoreThanZero();
        _;
    }

    modifier notZeroAddress(address receiver) {
        if (receiver == address(0)) revert SpokeVault__ZeroAddress();
        _;
    }

    modifier isAllowedProvider(address provider) {
        if (!allowedProviders[provider]) revert("Provider not allowed");
        _;
    }

    constructor(
        IERC20 asset,
        uint256 minToken,
        address _router,
        address _link,
        address _tokenPool
    ) CCIPReceiver(_router) ERC4626(asset) ERC20("Spoke Cross Token", "sCT") {
        MIN_DEPOSIT = minToken * 10 ** decimals();
        LINK_TOKEN = _link;
        TOKEN_POOL = _tokenPool;
        ROUTER = _router;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setHub(
        address _hub,
        uint64 _chainSelector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hubVault = HubInfo({
            hub: _hub,
            chainSelector: _chainSelector,
            totalAllocation: 0,
            totalProfitEarned: 0,
            lastAllocated: block.timestamp,
            lastWithdrawal: block.timestamp
        });
        // emit
    }

    function addLpProvider(
        address _provider
    ) internal notZeroAddress(_provider) {
        if (allowedProviders[_provider]) revert("Provider already exitsts");
        if (!allProviders.add(_provider))
            revert("Fail to add Liquidity Provider");

        allowedProviders[_provider] = true;
        providerInfo[_provider] = LiquidityProviderInfo({
            provider: _provider,
            deposit: 0,
            unclaimedProfit: 0,
            lastDeposit: block.timestamp,
            lastWithdrawal: block.timestamp,
            isActive: true
        });

        emit LiquidityProviderAdded(_provider);
    }
    function removeLpProvider(
        address _provider
    ) internal notZeroAddress(_provider) {
        LiquidityProviderInfo storage s = providerInfo[_provider];
        if (s.unclaimedProfit > 0 || s.deposit > 0)
            revert("Claim Remaining amount");

        delete allowedProviders[_provider];
        delete providerInfo[_provider];

        emit LiquidityProviderRemoved(_provider);

        // emit event
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
        if (!allowedProviders[lp]) addLpProvider(lp);

        if (assets < MIN_DEPOSIT)
            revert SpokeVault__AmountLessThanMinDeposit(assets);

        // uint256 expectedMint = previewDeposit(assets);
        // if (expectedMint < shares) revert("Shares minted mismatched");

        uint256 shares = super.deposit(assets, receiver);
        LiquidityProviderInfo storage s = providerInfo[lp];
        totalDeposits += assets;
        s.deposit += assets;
        s.lastDeposit = block.timestamp;

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
        address lp = msg.sender;
        uint256 assets = previewMint(shares);
        if (assets < MIN_DEPOSIT)
            revert SpokeVault__AmountLessThanMinDeposit(assets);

        uint256 depositedAssets = super.mint(shares, receiver);
        LiquidityProviderInfo storage s = providerInfo[lp];
        s.deposit += depositedAssets;
        totalDeposits += depositedAssets;
        s.lastDeposit = block.timestamp;

        // emit
        return depositedAssets;
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
        isAllowedProvider(owner)
        returns (uint256)
    {
        if (assets > IERC20(asset()).balanceOf(address(this))) {
            // for now we shall revert with error message of try again later but soon we'll implemente queue withdrawals
            revert("Spokes funds are busy try again later");
        }
        LiquidityProviderInfo storage s = providerInfo[owner];

        if (s.unclaimedProfit > 0) {
            s.deposit += s.unclaimedProfit;
            s.unclaimedProfit = 0;
        }
        uint256 maxAmountToPay = s.deposit; // total deposit + profits made
        if (assets > maxAmountToPay)
            revert("SpokeVault__NotEnoughAssetsToWithdraw");

        if (assets >= maxAmountToPay) {
            removeLpProvider(owner);
            totalDeposits -= maxAmountToPay;
        } else {
            s.deposit -= assets;
            totalDeposits -= assets;
        }
        uint256 sharesBurned = super.withdraw(assets, receiver, owner);

        // emit event
        return sharesBurned;
    }

    // lps withdraw underlying assets agains number of shares and burn the shares
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override
        notZeroAddress(receiver)
        isAllowedProvider(owner)
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        //
        uint256 assetsToSend = previewRedeem(shares);

        if (assetsToSend > IERC20(asset()).balanceOf(address(this))) {
            // for now we shall revert with error message of try again later but soon we'll implemente queue withdrawals
            revert("Spokes funds are busy try again later");
        }

        LiquidityProviderInfo storage s = providerInfo[owner];
        // settle profits before withdrawal
        if (s.unclaimedProfit > 0) {
            s.deposit += s.unclaimedProfit;
            s.unclaimedProfit = 0;
        }

        if (assetsToSend == s.deposit) {
            removeLpProvider(owner);
        } else {
            s.deposit -= assetsToSend;
        }
        totalDeposits -= assetsToSend;
        uint256 assetsSent = super.redeem(shares, receiver, owner);

        // emit
        return assetsSent;
    }

    function whenProfitsReceived() external nonReentrant {}

    // CROSS-CHAIN -> HUB VAULT
    // calls deposit function on the vault and receives vault shares for assets sent
    // @notice to send funds on chain
    function sendFundsToHub(
        uint256 _amount
    )
        external
        notZeroAmount(_amount)
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (totalDeposits <= MIN_DEPOSIT || _amount > totalDeposits)
            revert("Not Enough deposit or amount exceeds total deposits");

        unchecked {
            totalDeposits -= _amount;
            hubVault.totalAllocation += _amount;
        }
        hubVault.lastAllocated = block.timestamp;
        if (hubVault.chainSelector == block.chainid) {
            IERC20(asset()).approve(hubVault.hub, 0);
            IERC20(asset()).approve(hubVault.hub, _amount);
            IHubVault(hubVault.hub).deposit(_amount, address(this));
        } else {
            _sentToHub(uint8(Operations.DEPOSIT), _amount);
        }

        emit DepositsTransferedToVault(_amount);
    }

    ////////////////////////////////////////
    /////////////// INTERNAL //////////////

    // automation call
    function distributeProfite() internal {
        if (totalProfitFromHub == 0) revert("Not Enough Profit Earned yet");

        address[] memory Lps = allProviders.values();
        uint256 totalDistributed;
        for (uint16 i = 0; i < Lps.length; i++) {
            LiquidityProviderInfo storage lp = providerInfo[Lps[i]];
            uint256 amountToPay = getAmountToPay(lp.deposit);
            if (!lp.isActive) continue;

            if (amountToPay == 0 || amountToPay < MIN_PROFIT) continue; // not revert as might revert the entire batch
            lp.unclaimedProfit += amountToPay;
            totalDistributed += amountToPay;
        }
        if (totalDistributed > totalProfitFromHub)
            revert("Profit distribution exceeds available profit");
        totalProfitFromHub -= totalDistributed;

        // emit
    }

    function _sentToHub(uint8 opcode, uint256 assets) internal {
        if (hubVault.hub != address(0)) revert("HUB chain not set");

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);

        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(asset()),
            amount: assets
        });

        bytes memory data = abi.encodePacked(opcode, assets, address(this));

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(hubVault.hub),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200_000})
            ),
            feeToken: LINK_TOKEN
        });

        // Safely approving token pool to spend the asset
        IERC20(asset()).approve(TOKEN_POOL, 0);
        IERC20(asset()).approve(TOKEN_POOL, assets);

        // Compute fee
        uint256 fee = IRouterClient(ROUTER).getFee(
            hubVault.chainSelector,
            message
        );
        if (fee == 0) revert("Invalid CCIP Fee");
        IERC20(LINK_TOKEN).approve(address(ROUTER), 0);
        IERC20(LINK_TOKEN).approve(address(ROUTER), fee);
        bytes32 messageId = IRouterClient(ROUTER).ccipSend(
            hubVault.chainSelector,
            message
        );

        emit CCIPMessageSent(
            messageId,
            hubVault.hub,
            hubVault.chainSelector,
            assets,
            opcode
        );
    }

    // function _ccipReceive() internal override {}
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        // Accept messages only from destinated chain selector
        // if (msg.sender != ROUTER) revert SpokeVault__InvalidRouter();
        if (msg.sender != ROUTER) revert("iNVALID SENDER");

        address decodedSender = abi.decode(message.sender, (address));

        if (
            message.sourceChainSelector != hubVault.chainSelector ||
            decodedSender != hubVault.hub
        ) {
            // revert SpokeVault__InvalidSource();
            revert("invalid sender");
        }

        uint256 profitAmount = abi.decode(message.data, (uint256));

        if (
            message.destTokenAmounts.length != 1 ||
            message.destTokenAmounts[0].token != address(asset()) ||
            message.destTokenAmounts[0].amount != profitAmount
        ) {
            revert("Tokens MisMatch");
        }

        // process profit => mint shares to LPs
        totalProfitFromHub += profitAmount;

        // Emit event
        // emit CCIPMessageReceived(
        //     message.sourceChainSelector,
        //     decodedSender,
        //     opcode,
        //     profitAmount
        // );
    }

    function getAmountToPay(uint256 amountToPay) public view returns (uint256) {
        return (amountToPay * totalProfitFromHub) / totalDeposits;
    }

    // Emergency functions
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
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
