// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {DSCEngine} from "../src/DSCEngine.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();
        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, ) =
            config.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];
        vm.startBroadcast();
        //第九步：开始部署
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        //第十步0：获取抵押价格
         DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
         //第十一步：转owner权限
         dsc.transferOwnership(address(engine));
        vm.stopBroadcast();
        return (dsc,engine,config);
    }
}
