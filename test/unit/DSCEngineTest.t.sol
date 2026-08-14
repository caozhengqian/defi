// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;
import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin public dsc;
    DSCEngine public dsce;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;
    address public USER = makeAddr("user");
     uint256 public constant amountCollateral = 10 ether;
         uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER,STARTING_ERC20_BALANCE);
    }

    //////////////////
    // Price Tests //
    //////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // anvil（sepolia上不是，要计算真实价格）上正确结果是： 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18;
        console.log('weth=',weth);
        uint256 usdValue = dsce.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////
    function testRevertsIfTransferFromFails() public {
        vm.startPrank(USER);
         ERC20Mock(weth).approve(address(dsce), amountCollateral);
         // 使用selector,测试存入0的报错
         vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
         dsce.depositCollateral(weth,0);
         vm.stopPrank();
    }
}
