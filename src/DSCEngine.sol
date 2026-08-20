// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all similar < the $ backed value of all the DSC.
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS(DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    //健康检查OK
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();//健康没有改善
    ///////////////////
    // State Variables
    ///////////////////
    /// @dev Mapping of token address to price feed address
    // ETH=》ETH的USD价格地址；BTC=>BTC的USD价格地址；
    // [ETH=>价格地址]
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //奖金的10%（总数*10）/100 = 总数*10%
    /// @dev Amount of collateral deposited by user
    // [A用户=>[ETH=>100]
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    // 铸造币数量[A用户=>100 DSC币]
    mapping(address user => uint256 amount) private s_DSCMinted;
    /// @dev If we know exactly how many tokens we have, we could make this immutable!
    // 抵押物token，[ETH,BTC]
    address[] private s_collateralTokens;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    ///////////////////
    // Events
    ///////////////////
    //使用indexed关键字索引，日志中更容易搜索和过滤。
    //对于地址类型的参数，使用indexed可根据特定的地址来查找相关的事件日志。
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    ///////////////////
    // Modifiers
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////
    //第五步：初始化
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        // These feeds will be the USD pairs
        // For example ETH / USD or MKR / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////
    // External Functions
    ///////////////////
    // 存入抵押物和铸造币合在一起
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    // 第六步：存入抵押品，使用IERC20的transferFrom()方法将用户的抵押品转入合约
    // nonReentrant防止重放攻击
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    * 1. health factor must be over 1 after collatearl pulled
    * CEI:Check,Effects,Interactions
    * 第十二步0：提取抵押物+燃烧币
    * tokenCollateralAddress：The collateral address to redeem
    * amountCollateral: The amount of collateral to redeem
    * amountDscToBurn: The amount of DSC to burn
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        public
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor;
    }

    //第十二步2：赎回抵押物，并检查抵押物是否健康
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //第十二步1：燃烧币,并检查抵押物是否健康
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // If we do start nearing undercollateralization,we need someone to liquidate positions
    // $100 ETH backing $50 DSC
    // $ 20 ETH back $50 DSC ,DSC isn't worth $1!!!

    // If someone is almost undercollateralized, we will pay you to liquidate them!
    // $75 backing $50 DSC
    // Liquidator take $75 backing and burns off the $50 DSC
    /*
    * @param collateral: The erc20 collateral address to liquidate from the user
    * @param user: The user who has broken the health factor. Their _healthFactor should be below below MIN_HEALTH_FACTOR
    * @param debtToCover(需偿还债务):The amount of DSC you want to burn to improve the users health factor(你希望消耗多少DSC恢复健康)
    *   @notice You can partially liquidate a user.
    *   @notice You will get a liquidation bonus for taking the users funds
    *   @
    */
    // 第十三步0：清算系统
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //check health
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // burn DSC
        // take their collateral
        // If covering 100 DSC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //给结算者10%利息
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // 我们应实施一项功能，以便在协议无法履行时进行清算
        // And sweep extra amounts into a treasury并将额外的款项存入国库
        //0.05ETH * 0.1 = 0.005ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // 得到总额（0.05 + 0.005 = 0.055ETH）
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        // 进行redeem赎回
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        // 燃烧DSC，偿还债务的人
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external {}

    ///////////////////
    // Public Functions
    ///////////////////
    // 第十三步1：清算系统 的USD转为多少ETH
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH(token)
        // $/ETH=>ETH?
        // $2000 /ETH ==> $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // $10e18 * 1e18 /($2000e8 * 1e10)
        uint256 priceUint256 = uint256(price);
        return ((usdAmountInWei * PRECISION) / (priceUint256 * ADDITIONAL_FEED_PRECISION));
    }

    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you have enough collateral
     */
    // 第八步：创造DSC币
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint; //s_DSCMinted:[A用户=>100 DSC币]

        bool minted = i_dsc.mint(msg.sender, amountDscToMint); //创造DSC代币
        if (minted != true) {
            revert DSCEngine__MintFailed();
        }
        // 检验抵押物
        (msg.sender);
    }

    //第七步3：计算所有token的USD价格
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token,get the amount they have deposited,and map it to
        //the price, to get the USD value
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index]; //[ETH,BTC]
            uint256 amount = s_collateralDeposited[user][token]; //[A用户=>[ETH=>100]
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    //第七步4：通过聚合器获取抵押物的USD价格
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        //s_priceFeeds:[ETH=>价格地址]
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // casting to uint256 is safe because supported Chainlink price feeds are expected to return positive prices
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 priceUint256 = uint256(price);

        return ((priceUint256 * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    //////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////
    /*
    * 1. Check health factor(do you have enough collateral?)
    * 2. Revert if they don't;
    * 第七步0：检验抵押物的USD
    */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*
    * Returns how close to liquidation a user is.
    * if a user goes below 1, then they can get liquidated
    * 第七步1：检验抵押物的USD
    */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDescMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDescMinted;
    }

    //第七步2:获取所有token的USD价值
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDescMinted, uint256 collateralValueInUsd)
    {
        totalDescMinted = s_DSCMinted[user]; //s_DSCMinted[A用户=>100 DSC币]
        collateralValueInUsd = getAccountCollateralValue(user);
        // loop through each collateral token, get the amount they have deposited, and convert it to USD value
        // add all the USD values together
        // return the total value in USD
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        //s_collateralDeposited:抵押物[A用户=>[ETH=>100]
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorAfter()
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn; //[A用户=>100 DSC币]
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }
}
