// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import { console2 as console } from "@forge-std/console2.sol";
import { stdJson } from "@forge-std/StdJson.sol";

import { Predeploys } from "@main/libraries/Predeploys.sol";
import { Config } from "@script/deployer/Config.sol";
import { ForgeArtifacts } from "@script/deployer/ForgeArtifacts.sol";



// /// @notice store the new deployment to be saved
// struct DeployerDeployment {
//     string name;
//     address payable addr;
//     bytes bytecode;
//     bytes args;
//     string artifact;
//     string deploymentContext;
//     string chainIdAsString;
// }

/// @notice represent a deployment
struct Deployment {
    string name;
    address payable addr;
}

struct Prank {
    bool active;
    address addr;
}


interface IDeployer {
    /// @notice function that return whether deployments will be broadcasted
    function autoBroadcasting() external returns (bool);

    /// @notice function to activate/deactivate auto-broadcast, enabled by default
    ///  When activated, the deployment will be broadcasted automatically
    ///  Note that if prank is enabled, broadcast will be disabled
    /// @param broadcast whether to acitvate auto-broadcast
    function setAutoBroadcast(bool broadcast) external;

    /// @notice function to activate prank for a given address
    /// @param addr address to prank
    function activatePrank(address addr) external;

    /// @notice function to deactivate prank if any is active
    function deactivatePrank() external;

    /// @notice function that return the prank status
    /// @return active whether prank is active
    /// @return addr the address that will be used to perform the deployment
    function prankStatus() external view returns (bool active, address addr);

    /// @notice function that return all new deployments as an array
    function newDeployments() external view returns (Deployment[] memory);

    /// @notice function that tell you whether a deployment already exists with that name
    /// @param name deployment's name to query
    /// @return exists whether the deployment exists or not
    function has(string memory name) external view returns (bool exists);

    /// @notice function that return the address of a deployment
    /// @param name deployment's name to query
    /// @return addr the deployment's address or the zero address
    function getAddress(string memory name) external view returns (address payable addr);

    /// @notice allow to override an existing deployment by ignoring the current one.
    /// the deployment will only be overriden on disk once the broadast is performed and `forge-deploy` sync is invoked.
    /// @param name deployment's name to override
    function ignoreDeployment(string memory name) external;

    /// @notice function that return the deployment (address, bytecode and args bytes used)
    /// @param name deployment's name to query
    /// @return deployment the deployment (with address zero if not existent)
    function get(string memory name) external view returns (Deployment memory deployment);

    function save(string memory name, address deployed) external;

}

/// @notice contract that keep track of the deployment and save them as return value in the forge's broadcast
contract GlobalDeployer is IDeployer {
    // --------------------------------------------------------------------------------------------
    // Constants
    // --------------------------------------------------------------------------------------------
    Vm constant vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));

    error DeploymentDoesNotExist(string);
    /// @notice Error for when trying to save an invalid deployment
    error InvalidDeployment(string);
    /// @notice The set of deployments that have been done during execution.

    // --------------------------------------------------------------------------------------------
    // Storage
    // --------------------------------------------------------------------------------------------

    // Deployments
    mapping(string => Deployment) internal _namedDeployments;
    Deployment[] internal _newDeployments;

    // Context
    // string internal deploymentContext;
    // string internal chainIdAsString;

    bool internal _autoBroadcast = true;

    Prank internal _prank;

    string internal deploymentOutfile;

    /// @notice init a deployer with the current context
    /// the context is by default the current chainId
    /// but if the DEPLOYMENT_CONTEXT env variable is set, the context take that value
    /// The context allow you to organise deployments in a set as well as make specific configurations
    function init() external {

        console.log('init');
        _autoBroadcast = true; // needed as we etch the deployed code and so the initialization in the declaration above is not taken in consideration

        // if (bytes(chainIdAsString).length > 0) {
        //     return;
        // }

        // // TODO? allow to pass context in constructor
        // uint256 currentChainID;
        // assembly {
        //     currentChainID := chainid()
        // }
        // chainIdAsString = vm.toString(currentChainID);

        // deploymentContext = _getDeploymentContext();

        // // we read the deployment folder for a .chainId file
        // // if the chainId here do not match the current one
        // // we are using the same context name on different chain, this is an error
        // string memory root = vm.projectRoot();
        // // TODO? configure deployments folder via deploy.toml / deploy.json
        // string memory path = string.concat(root, "/deployments/", deploymentContext, "/.chainId");
        // try vm.readFile(path) returns (string memory chainId) {
        //     if (keccak256(bytes(chainId)) != keccak256(bytes(chainIdAsString))) {
        //         revert(
        //             string.concat(
        //                 "Current chainID: ",
        //                 chainIdAsString,
        //                 " But Context '",
        //                 deploymentContext,
        //                 "' Already Exists With a Different Chain ID (",
        //                 chainId,
        //                 ")"
        //             )
        //         );
        //     }
        // } catch {}

        deploymentOutfile = Config.deploymentOutfile();
        console.log("Writing artifact to %s", deploymentOutfile);
        ForgeArtifacts.ensurePath(deploymentOutfile);
    }

    // --------------------------------------------------------------------------------------------
    // Public Interface
    // --------------------------------------------------------------------------------------------

    function autoBroadcasting() external view returns (bool) {
        return _autoBroadcast;
    }

    function setAutoBroadcast(bool broadcast) external {
        _autoBroadcast = broadcast;
    }

    function activatePrank(address addr) external {
        _prank.active = true;
        _prank.addr = addr;
    }

    function deactivatePrank() external {
        _prank.active = false;
        _prank.addr = address(0);
    }

    function prankStatus() external view returns (bool active, address addr) {
        active = _prank.active;
        addr = _prank.addr;
    }

    /// @notice Returns all of the deployments done in the current context.
    function newDeployments() external view returns (Deployment[] memory) {
        return _newDeployments;
    }

    /// @notice Returns whether or not a particular deployment exists.
    /// @param _name The name of the deployment.
    /// @return Whether the deployment exists or not.
    function has(string memory _name) public view returns (bool) {
        Deployment memory existing = _namedDeployments[_name];
        return bytes(existing.name).length > 0;
    }


    function getAddress(string memory _name) public view returns (address payable) {
        Deployment memory existing = _namedDeployments[_name];
        if (existing.addr != address(0)) {
            if (bytes(existing.name).length == 0) {
                return payable(address(0));
            }
            return existing.addr;
        }

        bytes32 digest = keccak256(bytes(_name));
        if (digest == keccak256(bytes("L2CrossDomainMessenger"))) {
            return payable(Predeploys.L2_CROSS_DOMAIN_MESSENGER);
        } else if (digest == keccak256(bytes("L2ToL1MessagePasser"))) {
            return payable(Predeploys.L2_TO_L1_MESSAGE_PASSER);
        } else if (digest == keccak256(bytes("L2StandardBridge"))) {
            return payable(Predeploys.L2_STANDARD_BRIDGE);
        } else if (digest == keccak256(bytes("L2ERC721Bridge"))) {
            return payable(Predeploys.L2_ERC721_BRIDGE);
        } else if (digest == keccak256(bytes("SequencerFeeWallet"))) {
            return payable(Predeploys.SEQUENCER_FEE_WALLET);
        } else if (digest == keccak256(bytes("OptimismMintableERC20Factory"))) {
            return payable(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY);
        } else if (digest == keccak256(bytes("OptimismMintableERC721Factory"))) {
            return payable(Predeploys.OPTIMISM_MINTABLE_ERC721_FACTORY);
        } else if (digest == keccak256(bytes("L1Block"))) {
            return payable(Predeploys.L1_BLOCK_ATTRIBUTES);
        } else if (digest == keccak256(bytes("GasPriceOracle"))) {
            return payable(Predeploys.GAS_PRICE_ORACLE);
        } else if (digest == keccak256(bytes("L1MessageSender"))) {
            return payable(Predeploys.L1_MESSAGE_SENDER);
        } else if (digest == keccak256(bytes("DeployerWhitelist"))) {
            return payable(Predeploys.DEPLOYER_WHITELIST);
        } else if (digest == keccak256(bytes("WETH9"))) {
            return payable(Predeploys.WETH9);
        } else if (digest == keccak256(bytes("LegacyERC20ETH"))) {
            return payable(Predeploys.LEGACY_ERC20_ETH);
        } else if (digest == keccak256(bytes("L1BlockNumber"))) {
            return payable(Predeploys.L1_BLOCK_NUMBER);
        } else if (digest == keccak256(bytes("LegacyMessagePasser"))) {
            return payable(Predeploys.LEGACY_MESSAGE_PASSER);
        } else if (digest == keccak256(bytes("ProxyAdmin"))) {
            return payable(Predeploys.PROXY_ADMIN);
        } else if (digest == keccak256(bytes("BaseFeeVault"))) {
            return payable(Predeploys.BASE_FEE_VAULT);
        } else if (digest == keccak256(bytes("L1FeeVault"))) {
            return payable(Predeploys.L1_FEE_VAULT);
        } else if (digest == keccak256(bytes("GovernanceToken"))) {
            return payable(Predeploys.GOVERNANCE_TOKEN);
        } else if (digest == keccak256(bytes("SchemaRegistry"))) {
            return payable(Predeploys.SCHEMA_REGISTRY);
        } else if (digest == keccak256(bytes("EAS"))) {
            return payable(Predeploys.EAS);
        }
        return payable(address(0));
    }

    /// @notice Returns the address of a deployment and reverts if the deployment
    ///         does not exist.
    /// @return The address of the deployment.
    function mustGetAddress(string memory _name) public view returns (address payable) {
        address addr = getAddress(_name);
        if (addr == address(0)) {
            revert DeploymentDoesNotExist(_name);
        }
        return payable(addr);
    }


    /// @notice allow to override an existing deployment by ignoring the current one.
    /// the deployment will only be overriden on disk once the broadast is performed and `forge-deploy` sync is invoked.
    /// @param name deployment's name to override
    function ignoreDeployment(string memory name) public {
        _namedDeployments[name].name = "";
        _namedDeployments[name].addr = payable(address(1)); // TO ensure it is picked up as being ignored
    }

    /// @notice Returns a deployment that is suitable to be used to interact with contracts.
    /// @param _name The name of the deployment.
    /// @return The deployment.
    function get(string memory _name) public view returns (Deployment memory) {
        return _namedDeployments[_name];
    }

    /// @notice Appends a deployment to disk as a JSON deploy artifact.
    /// @param _name The name of the deployment.
    /// @param _deployed The address of the deployment.
    function save(string memory _name, address _deployed) public {
        if (bytes(_name).length == 0) {
            revert InvalidDeployment("EmptyName");
        }
        if (bytes(_namedDeployments[_name].name).length > 0) {
            revert InvalidDeployment("AlreadyExists");
        }

        console.log("Saving %s: %s", _name, _deployed);
        Deployment memory deployment = Deployment({ name: _name, addr: payable(_deployed) });
        _namedDeployments[_name] = deployment;
        _newDeployments.push(deployment);
        _appendDeployment(_name, _deployed);
    }


    // --------------------------------------------------------------------------------------------
    // Internal
    // --------------------------------------------------------------------------------------------

    // function _getDeploymentContext() private view returns (string memory context) {
    //     // no deploymentContext provided we fallback on chainID
    //     uint256 currentChainID;
    //     assembly {
    //         currentChainID := chainid()
    //     }
    //     context = vm.envOr("DEPLOYMENT_CONTEXT", string(""));
    //     if (bytes(context).length == 0) {
    //         // on local dev network we fallback on the special void context
    //         // this allow `forge test` without any env setup to work as normal, without trying to read deployments
    //         if (currentChainID == 1337 || currentChainID == 31337) {
    //             context = "void";
    //         } else {
    //             context = vm.toString(currentChainID);
    //         }
    //     }
    // }


    /// @notice Adds a deployment to the temp deployments file
    function _appendDeployment(string memory _name, address _deployed) internal {
        vm.writeJson({ json: stdJson.serialize("", _name, _deployed), path: deploymentOutfile });
    }

}

function getDeployer() returns (IDeployer) {
    address addr = address(uint160(uint256(keccak256(abi.encode("optimism.deploy")))));
    if (addr.code.length > 0) {
        return IDeployer(addr);
    }
    Vm vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));
    bytes memory code = vm.getDeployedCode("Deployer.sol:GlobalDeployer");
    vm.etch(addr, code);
    vm.allowCheatcodes(addr);
    GlobalDeployer deployer = GlobalDeployer(addr);
    deployer.init();
    return deployer;
}