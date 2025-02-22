// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "../src/contracts/interfaces/IETHPOSDeposit.sol";
import "../src/contracts/interfaces/IBeaconChainOracle.sol";

import "../src/contracts/core/StrategyManager.sol";
import "../src/contracts/core/Slasher.sol";
import "../src/contracts/core/DelegationManager.sol";

import "../src/contracts/strategies/StrategyBase.sol";

import "../src/contracts/pods/EigenPod.sol";
import "../src/contracts/pods/EigenPodManager.sol";
import "../src/contracts/pods/DelayedWithdrawalRouter.sol";

import "../src/contracts/permissions/PauserRegistry.sol";
import "../src/contracts/middleware/BLSPublicKeyCompendium.sol";

import "../src/contracts/libraries/BytesLib.sol";

import "../src/test/mocks/EmptyContract.sol";
import "../src/test/mocks/ETHDepositMock.sol";

import "forge-std/Script.sol";
import "forge-std/Test.sol";

// # To load the variables in the .env file
// source .env

// # To deploy and verify our contract
// forge script script/M1_Deploy.s.sol:Deployer_M1 --rpc-url $RPC_URL  --private-key $PRIVATE_KEY --broadcast -vvvv
contract Deployer_M1 is Script, Test {
    Vm cheats = Vm(HEVM_ADDRESS);

    // struct used to encode token info in config file
    struct StrategyTokenAndName {
        address tokenAddress;
        string tokenName;
        string tokenSymbol;
    }

    string public deployConfigPath = string(bytes("script/M1_deploy.config.json"));

    // EigenLayer Contracts
    ProxyAdmin public eigenLayerProxyAdmin;
    PauserRegistry public eigenLayerPauserReg;
    Slasher public slasher;
    Slasher public slasherImplementation;
    DelegationManager public delegation;
    DelegationManager public delegationImplementation;
    StrategyManager public strategyManager;
    StrategyManager public strategyManagerImplementation;
    EigenPodManager public eigenPodManager;
    EigenPodManager public eigenPodManagerImplementation;
    DelayedWithdrawalRouter public delayedWithdrawalRouter;
    DelayedWithdrawalRouter public delayedWithdrawalRouterImplementation;
    UpgradeableBeacon public eigenPodBeacon;
    EigenPod public eigenPodImplementation;
    StrategyBase public baseStrategyImplementation;

    EmptyContract public emptyContract;

    address communityMultisig;
    address teamMultisig;

    // the ETH2 deposit contract -- if not on mainnet, we deploy a mock as stand-in
    IETHPOSDeposit public ethPOSDeposit;

    // strategies deployed
    StrategyBase[] public deployedStrategyArray;

    // IMMUTABLES TO SET
    uint256 REQUIRED_BALANCE_WEI;

    // OTHER DEPLOYMENT PARAMETERS
    uint256 STRATEGY_MANAGER_INIT_PAUSED_STATUS;
    uint256 SLASHER_INIT_PAUSED_STATUS;
    uint256 DELEGATION_INIT_PAUSED_STATUS;
    uint256 EIGENPOD_MANAGER_INIT_PAUSED_STATUS;
    uint256 DELAYED_WITHDRAWAL_ROUTER_INIT_PAUSED_STATUS;

    // one week in blocks -- 50400
    uint32 STRATEGY_MANAGER_INIT_WITHDRAWAL_DELAY_BLOCKS;
    uint32 DELAYED_WITHDRAWAL_ROUTER_INIT_WITHDRAWAL_DELAY_BLOCKS;

    function run() external {
        // read and log the chainID
        uint256 chainId = block.chainid;
        emit log_named_uint("You are deploying on ChainID", chainId);

        // READ JSON CONFIG DATA
        string memory config_data = vm.readFile(deployConfigPath);
        // bytes memory parsedData = vm.parseJson(config_data);

        STRATEGY_MANAGER_INIT_PAUSED_STATUS = stdJson.readUint(config_data, ".strategyManager.init_paused_status");
        SLASHER_INIT_PAUSED_STATUS = stdJson.readUint(config_data, ".slasher.init_paused_status");
        DELEGATION_INIT_PAUSED_STATUS = stdJson.readUint(config_data, ".delegation.init_paused_status");
        EIGENPOD_MANAGER_INIT_PAUSED_STATUS = stdJson.readUint(config_data, ".eigenPodManager.init_paused_status");
        DELAYED_WITHDRAWAL_ROUTER_INIT_PAUSED_STATUS = stdJson.readUint(config_data, ".delayedWithdrawalRouter.init_paused_status");

        STRATEGY_MANAGER_INIT_WITHDRAWAL_DELAY_BLOCKS = uint32(stdJson.readUint(config_data, ".strategyManager.init_withdrawal_delay_blocks"));
        DELAYED_WITHDRAWAL_ROUTER_INIT_WITHDRAWAL_DELAY_BLOCKS = uint32(stdJson.readUint(config_data, ".strategyManager.init_withdrawal_delay_blocks"));

        REQUIRED_BALANCE_WEI = stdJson.readUint(config_data, ".eigenPod.REQUIRED_BALANCE_WEI");

        // tokens to deploy strategies for
        StrategyTokenAndName[] memory strategyTokensAndNames;

        communityMultisig = stdJson.readAddress(config_data, ".multisig_addresses.communityMultisig");
        teamMultisig = stdJson.readAddress(config_data, ".multisig_addresses.teamMultisig");
        // load token list
        bytes memory strategyTokensAndNamesRaw = stdJson.parseRaw(config_data, ".strategies");
        strategyTokensAndNames = abi.decode(strategyTokensAndNamesRaw, (StrategyTokenAndName[]));

        require(communityMultisig != address(0), "communityMultisig address not configured correctly!");
        require(teamMultisig != address(0), "teamMultisig address not configured correctly!");

        // START RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.startBroadcast();

        // deploy proxy admin for ability to upgrade proxy contracts
        eigenLayerProxyAdmin = new ProxyAdmin();

        //deploy pauser registry
        eigenLayerPauserReg = new PauserRegistry(teamMultisig, communityMultisig);

        /**
         * First, deploy upgradeable proxy contracts that **will point** to the implementations. Since the implementation contracts are
         * not yet deployed, we give these proxies an empty contract as the initial implementation, to act as if they have no code.
         */
        emptyContract = new EmptyContract();
        delegation = DelegationManager(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(eigenLayerProxyAdmin), ""))
        );
        strategyManager = StrategyManager(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(eigenLayerProxyAdmin), ""))
        );
        slasher = Slasher(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(eigenLayerProxyAdmin), ""))
        );
        eigenPodManager = EigenPodManager(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(eigenLayerProxyAdmin), ""))
        );
        delayedWithdrawalRouter = DelayedWithdrawalRouter(
            address(new TransparentUpgradeableProxy(address(emptyContract), address(eigenLayerProxyAdmin), ""))
        );

        // if on mainnet, use the ETH2 deposit contract address
        if (chainId == 1) {
            ethPOSDeposit = IETHPOSDeposit(0x00000000219ab540356cBB839Cbe05303d7705Fa);
        // if not on mainnet, deploy a mock
        } else {
            ethPOSDeposit = IETHPOSDeposit(stdJson.readAddress(config_data, ".ethPOSDepositAddress"));
        }
        eigenPodImplementation = new EigenPod(
            ethPOSDeposit,
            delayedWithdrawalRouter,
            eigenPodManager,
            REQUIRED_BALANCE_WEI
        );

        eigenPodBeacon = new UpgradeableBeacon(address(eigenPodImplementation));

        // Second, deploy the *implementation* contracts, using the *proxy contracts* as inputs
        delegationImplementation = new DelegationManager(strategyManager, slasher);
        strategyManagerImplementation = new StrategyManager(delegation, eigenPodManager, slasher);
        slasherImplementation = new Slasher(strategyManager, delegation);
        eigenPodManagerImplementation = new EigenPodManager(ethPOSDeposit, eigenPodBeacon, strategyManager, slasher);
        delayedWithdrawalRouterImplementation = new DelayedWithdrawalRouter(eigenPodManager);

        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        eigenLayerProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(payable(address(delegation))),
            address(delegationImplementation),
            abi.encodeWithSelector(
                DelegationManager.initialize.selector,
                communityMultisig,
                eigenLayerPauserReg,
                DELEGATION_INIT_PAUSED_STATUS
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(payable(address(strategyManager))),
            address(strategyManagerImplementation),
            abi.encodeWithSelector(
                StrategyManager.initialize.selector,
                communityMultisig,
                teamMultisig,
                eigenLayerPauserReg,
                STRATEGY_MANAGER_INIT_PAUSED_STATUS,
                STRATEGY_MANAGER_INIT_WITHDRAWAL_DELAY_BLOCKS
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(payable(address(slasher))),
            address(slasherImplementation),
            abi.encodeWithSelector(
                Slasher.initialize.selector,
                communityMultisig,
                eigenLayerPauserReg,
                SLASHER_INIT_PAUSED_STATUS
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(payable(address(eigenPodManager))),
            address(eigenPodManagerImplementation),
            abi.encodeWithSelector(
                EigenPodManager.initialize.selector,
                IBeaconChainOracle(address(0)),
                communityMultisig,
                eigenLayerPauserReg,
                EIGENPOD_MANAGER_INIT_PAUSED_STATUS
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            TransparentUpgradeableProxy(payable(address(delayedWithdrawalRouter))),
            address(delayedWithdrawalRouterImplementation),
            abi.encodeWithSelector(DelayedWithdrawalRouter.initialize.selector,
            communityMultisig,
            eigenLayerPauserReg,
            DELAYED_WITHDRAWAL_ROUTER_INIT_PAUSED_STATUS,
            DELAYED_WITHDRAWAL_ROUTER_INIT_WITHDRAWAL_DELAY_BLOCKS)
        );

        // deploy simple ERC20 (**NOT** WETH-like!), used in a test strategy
        for (uint256 i = 0; i < strategyTokensAndNames.length; ++i) {
            if (strategyTokensAndNames[i].tokenAddress == address(0)) {
                strategyTokensAndNames[i].tokenAddress = address(
                    new ERC20PresetFixedSupply(
                    strategyTokensAndNames[i].tokenName,
                    strategyTokensAndNames[i].tokenSymbol,
                    // initial supply
                    10e50,
                    // owner
                    msg.sender
                    )
                );
            }
        }

        // deploy StrategyBase contract implementation
        baseStrategyImplementation = new StrategyBase(strategyManager);
        // create upgradeable proxies that each point to the implementation and initialize them
        for (uint256 i = 0; i < strategyTokensAndNames.length; ++i) {
            deployedStrategyArray.push(
                StrategyBase(address(
                    new TransparentUpgradeableProxy(
                        address(baseStrategyImplementation),
                        address(eigenLayerProxyAdmin),
                        abi.encodeWithSelector(StrategyBase.initialize.selector, IERC20(strategyTokensAndNames[i].tokenAddress), eigenLayerPauserReg)
                    )
                ))
            );
        }

        eigenLayerProxyAdmin.transferOwnership(communityMultisig);
        eigenPodBeacon.transferOwnership(communityMultisig);

        // STOP RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.stopBroadcast();


        // CHECK CORRECTNESS OF DEPLOYMENT
        _verifyContractsPointAtOneAnother(
            delegationImplementation,
            strategyManagerImplementation,
            slasherImplementation,
            eigenPodManagerImplementation,
            delayedWithdrawalRouterImplementation
        );
        _verifyContractsPointAtOneAnother(
            delegation,
            strategyManager,
            slasher,
            eigenPodManager,
            delayedWithdrawalRouter
        );
        _verifyImplementationsSetCorrectly();
        _verifyInitialOwners();
        _checkPauserInitializations();
        _verifyInitializationParams();


        // WRITE JSON DATA
        string memory parent_object = "parent object";

        string memory deployed_strategies = "strategies";
        for (uint256 i = 0; i < strategyTokensAndNames.length; ++i) {
            vm.serializeAddress(deployed_strategies, strategyTokensAndNames[i].tokenSymbol, address(deployedStrategyArray[i]));
        }
        string memory deployed_strategies_output = vm.serializeAddress(
            deployed_strategies, strategyTokensAndNames[strategyTokensAndNames.length - 1].tokenSymbol,
            address(deployedStrategyArray[strategyTokensAndNames.length - 1])
        );

        string memory deployed_addresses = "addresses";
        vm.serializeAddress(deployed_addresses, "eigenLayerProxyAdmin", address(eigenLayerProxyAdmin));
        vm.serializeAddress(deployed_addresses, "eigenLayerPauserReg", address(eigenLayerPauserReg));
        vm.serializeAddress(deployed_addresses, "slasher", address(slasher));
        vm.serializeAddress(deployed_addresses, "slasherImplementation", address(slasherImplementation));
        vm.serializeAddress(deployed_addresses, "delegation", address(delegation));
        vm.serializeAddress(deployed_addresses, "delegationImplementation", address(delegationImplementation));
        vm.serializeAddress(deployed_addresses, "strategyManager", address(strategyManager));
        vm.serializeAddress(deployed_addresses, "strategyManagerImplementation", address(strategyManagerImplementation));
        vm.serializeAddress(deployed_addresses, "eigenPodManager", address(eigenPodManager));
        vm.serializeAddress(deployed_addresses, "eigenPodManagerImplementation", address(eigenPodManagerImplementation));
        vm.serializeAddress(deployed_addresses, "delayedWithdrawalRouter", address(delayedWithdrawalRouter));
        vm.serializeAddress(deployed_addresses, "delayedWithdrawalRouterImplementation", address(delayedWithdrawalRouterImplementation));
        vm.serializeAddress(deployed_addresses, "eigenPodBeacon", address(eigenPodBeacon));
        vm.serializeAddress(deployed_addresses, "eigenPodImplementation", address(eigenPodImplementation));
        vm.serializeAddress(deployed_addresses, "baseStrategyImplementation", address(baseStrategyImplementation));
        vm.serializeAddress(deployed_addresses, "emptyContract", address(emptyContract));
        string memory deployed_addresses_output = vm.serializeString(deployed_addresses, "strategies", deployed_strategies_output);

        string memory parameters = "parameters";
        vm.serializeAddress(parameters, "communityMultisig", communityMultisig);
        string memory parameters_output = vm.serializeAddress(parameters, "teamMultisig", teamMultisig);

        string memory chain_info = "chainInfo";
        vm.serializeUint(chain_info, "deploymentBlock", block.number);
        string memory chain_info_output = vm.serializeUint(chain_info, "chainId", chainId);

        // serialize all the data
        vm.serializeString(parent_object, deployed_addresses, deployed_addresses_output);
        vm.serializeString(parent_object, chain_info, chain_info_output);
        string memory finalJson = vm.serializeString(parent_object, parameters, parameters_output);
        vm.writeJson(finalJson, "script/output/M1_deployment_data.json");
    }

    function _verifyContractsPointAtOneAnother(
        DelegationManager delegationContract,  
        StrategyManager strategyManagerContract, 
        Slasher slasherContract,  
        EigenPodManager eigenPodManagerContract,
        DelayedWithdrawalRouter delayedWithdrawalRouterContract
    ) internal view {
        require(delegationContract.slasher() == slasher, "delegation: slasher address not set correctly");
        require(delegationContract.strategyManager() == strategyManager, "delegation: strategyManager address not set correctly");

        require(strategyManagerContract.slasher() == slasher, "strategyManager: slasher address not set correctly");
        require(strategyManagerContract.delegation() == delegation, "strategyManager: delegation address not set correctly");
        require(strategyManagerContract.eigenPodManager() == eigenPodManager, "strategyManager: eigenPodManager address not set correctly");

        require(slasherContract.strategyManager() == strategyManager, "slasher: strategyManager not set correctly");
        require(slasherContract.delegation() == delegation, "slasher: delegation not set correctly");

        require(eigenPodManagerContract.ethPOS() == ethPOSDeposit, " eigenPodManager: ethPOSDeposit contract address not set correctly");
        require(eigenPodManagerContract.eigenPodBeacon() == eigenPodBeacon, "eigenPodManager: eigenPodBeacon contract address not set correctly");
        require(eigenPodManagerContract.strategyManager() == strategyManager, "eigenPodManager: strategyManager contract address not set correctly");
        require(eigenPodManagerContract.slasher() == slasher, "eigenPodManager: slasher contract address not set correctly");

        require(delayedWithdrawalRouterContract.eigenPodManager() == eigenPodManager,
            "delayedWithdrawalRouterContract: eigenPodManager address not set correctly");
    }

    function _verifyImplementationsSetCorrectly() internal view {
        require(eigenLayerProxyAdmin.getProxyImplementation(
            TransparentUpgradeableProxy(payable(address(delegation)))) == address(delegationImplementation),
            "delegation: implementation set incorrectly");
        require(eigenLayerProxyAdmin.getProxyImplementation(
            TransparentUpgradeableProxy(payable(address(strategyManager)))) == address(strategyManagerImplementation),
            "strategyManager: implementation set incorrectly");
        require(eigenLayerProxyAdmin.getProxyImplementation(
            TransparentUpgradeableProxy(payable(address(slasher)))) == address(slasherImplementation),
            "slasher: implementation set incorrectly");
        require(eigenLayerProxyAdmin.getProxyImplementation(
            TransparentUpgradeableProxy(payable(address(eigenPodManager)))) == address(eigenPodManagerImplementation),
            "eigenPodManager: implementation set incorrectly");
        require(eigenLayerProxyAdmin.getProxyImplementation(
            TransparentUpgradeableProxy(payable(address(delayedWithdrawalRouter)))) == address(delayedWithdrawalRouterImplementation),
            "delayedWithdrawalRouter: implementation set incorrectly");

        for (uint256 i = 0; i < deployedStrategyArray.length; ++i) {
            require(eigenLayerProxyAdmin.getProxyImplementation(
                TransparentUpgradeableProxy(payable(address(deployedStrategyArray[i])))) == address(baseStrategyImplementation),
                "strategy: implementation set incorrectly");
        }

        require(eigenPodBeacon.implementation() == address(eigenPodImplementation),
            "eigenPodBeacon: implementation set incorrectly");
    }

    function _verifyInitialOwners() internal view {
        require(strategyManager.owner() == communityMultisig, "strategyManager: owner not set correctly");
        require(delegation.owner() == communityMultisig, "delegation: owner not set correctly");
        require(slasher.owner() == communityMultisig, "slasher: owner not set correctly");
        require(eigenPodManager.owner() == communityMultisig, "delegation: owner not set correctly");

        require(eigenLayerProxyAdmin.owner() == communityMultisig, "eigenLayerProxyAdmin: owner not set correctly");
        require(eigenPodBeacon.owner() == communityMultisig, "eigenPodBeacon: owner not set correctly");
        require(delayedWithdrawalRouter.owner() == communityMultisig, "delayedWithdrawalRouter: owner not set correctly");        
    }

    function _checkPauserInitializations() internal view {
        require(delegation.pauserRegistry() == eigenLayerPauserReg, "delegation: pauser registry not set correctly");
        require(strategyManager.pauserRegistry() == eigenLayerPauserReg, "strategyManager: pauser registry not set correctly");
        require(slasher.pauserRegistry() == eigenLayerPauserReg, "slasher: pauser registry not set correctly");
        require(eigenPodManager.pauserRegistry() == eigenLayerPauserReg, "eigenPodManager: pauser registry not set correctly");        
        require(delayedWithdrawalRouter.pauserRegistry() == eigenLayerPauserReg, "delayedWithdrawalRouter: pauser registry not set correctly");        

        require(eigenLayerPauserReg.pauser() == teamMultisig, "pauserRegistry: pauser not set correctly");
        require(eigenLayerPauserReg.unpauser() == communityMultisig, "pauserRegistry: unpauser not set correctly");

        for (uint256 i = 0; i < deployedStrategyArray.length; ++i) {
            require(deployedStrategyArray[i].pauserRegistry() == eigenLayerPauserReg, "StrategyBase: pauser registry not set correctly");
            require(deployedStrategyArray[i].paused() == 0, "StrategyBase: init paused status set incorrectly");
        }

        // // pause *nothing*
        // uint256 STRATEGY_MANAGER_INIT_PAUSED_STATUS = 0;
        // // pause *everything*
        // uint256 SLASHER_INIT_PAUSED_STATUS = type(uint256).max; 
        // // pause *everything*
        // uint256 DELEGATION_INIT_PAUSED_STATUS = type(uint256).max;  
        // // pause *all of the proof-related functionality* (everything that can be paused other than creation of EigenPods)
        // uint256 EIGENPOD_MANAGER_INIT_PAUSED_STATUS = (2**1) + (2**2) + (2**3) + (2**4); /* = 30 */ 
        // // pause *nothing*
        // uint256 DELAYED_WITHDRAWAL_ROUTER_INIT_PAUSED_STATUS = 0;
        require(strategyManager.paused() == 0, "strategyManager: init paused status set incorrectly");
        require(slasher.paused() == type(uint256).max, "slasher: init paused status set incorrectly");
        require(delegation.paused() == type(uint256).max, "delegation: init paused status set incorrectly");
        require(eigenPodManager.paused() == 30, "eigenPodManager: init paused status set incorrectly");
        require(delayedWithdrawalRouter.paused() == 0, "delayedWithdrawalRouter: init paused status set incorrectly");
    }

    function _verifyInitializationParams() internal view {
        // // one week in blocks -- 50400
        // uint32 STRATEGY_MANAGER_INIT_WITHDRAWAL_DELAY_BLOCKS = 7 days / 12 seconds;
        // uint32 DELAYED_WITHDRAWAL_ROUTER_INIT_WITHDRAWAL_DELAY_BLOCKS = 7 days / 12 seconds;
        // require(strategyManager.withdrawalDelayBlocks() == 7 days / 12 seconds,
        //     "strategyManager: withdrawalDelayBlocks initialized incorrectly");
        // require(delayedWithdrawalRouter.withdrawalDelayBlocks() == 7 days / 12 seconds,
        //     "delayedWithdrawalRouter: withdrawalDelayBlocks initialized incorrectly");
        // uint256 REQUIRED_BALANCE_WEI = 31 ether;
        require(eigenPodImplementation.REQUIRED_BALANCE_WEI() == 31 ether,
            "eigenPod: REQUIRED_BALANCE_WEI initialized incorrectly");

        require(strategyManager.strategyWhitelister() == teamMultisig,
            "strategyManager: strategyWhitelister address not set correctly");

        require(eigenPodManager.beaconChainOracle() == IBeaconChainOracle(address(0)),
            "eigenPodManager: eigenPodBeacon contract address not set correctly");

        require(delayedWithdrawalRouter.eigenPodManager() == eigenPodManager,
            "delayedWithdrawalRouter: eigenPodManager set incorrectly");

        require(baseStrategyImplementation.strategyManager() == strategyManager,
            "baseStrategyImplementation: strategyManager set incorrectly");

        require(eigenPodImplementation.ethPOS() == ethPOSDeposit,
            "eigenPodImplementation: ethPOSDeposit contract address not set correctly");
        require(eigenPodImplementation.eigenPodManager() == eigenPodManager,
            " eigenPodImplementation: eigenPodManager contract address not set correctly");
        require(eigenPodImplementation.delayedWithdrawalRouter() == delayedWithdrawalRouter,
            " eigenPodImplementation: delayedWithdrawalRouter contract address not set correctly");
    }
}



    

