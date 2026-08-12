// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    ///////////////////
    // State Variables
    ///////////////////
    /// @dev Mapping of token address to price feed address
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    /// @dev Amount of collateral deposited by user
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amount) private s_DSCMinted;
    /// @dev If we know exactly how many tokens we have, we could make this immutable!
    address[] private s_collateralTokens;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    ///////////////////
    // Events
    ///////////////////
    //使用indexed关键字索引，日志中更容易搜索和过滤。
    //对于地址类型的参数，使用indexed可根据特定的地址来查找相关的事件日志。
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
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
    function depositCollateralAndMintDsc() external {}

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    // 第六步：存入抵押品，使用IERC20的transferFrom()方法将用户的抵押品转入合约
    // nonReentrant防止重放攻击
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
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

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external {}

    ///////////////////
    // Public Functions
    ///////////////////
    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you have enough collateral
     */
    // 第八步：创造DSC币
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // 检验抵押物
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        if (minted != true) {
            revert DSCEngine__MintFailed();
        }
    }

    //第七步3：计算所有token的USD价格
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token,get the amount they have deposited,and map it to
        //the price, to get the USD value
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    //第七步4：通过聚合器获取抵押物的USD价格
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
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
        totalDescMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
        // loop through each collateral token, get the amount they have deposited, and convert it to USD value
        // add all the USD values together
        // return the total value in USD
    }
}
