// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {BoltValidators} from "../src/contracts/BoltValidators.sol";
import {BoltManager} from "../src/contracts/BoltManager.sol";
import {BoltParameters} from "../src/contracts/BoltParameters.sol";
import {BoltConfig} from "../src/lib/Config.sol";
import {BoltEigenLayerMiddleware} from "../src/contracts/BoltEigenLayerMiddleware.sol";
import {IBoltValidators} from "../src/interfaces/IBoltValidators.sol";
import {IBoltManager} from "../src/interfaces/IBoltManager.sol";
import {IBoltMiddleware} from "../src/interfaces/IBoltMiddleware.sol";
import {Utils} from "./Utils.sol";

import {AVSDirectoryStorage} from "@eigenlayer/src/contracts/core/AVSDirectoryStorage.sol";
import {DelegationManagerStorage} from "@eigenlayer/src/contracts/core/DelegationManagerStorage.sol";
import {IDelegationManager} from "@eigenlayer/src/contracts/interfaces/IDelegationManager.sol";
import {ISignatureUtils} from "@eigenlayer/src/contracts/interfaces/ISignatureUtils.sol";
import {IAVSDirectory} from "@eigenlayer/src/contracts/interfaces/IAVSDirectory.sol";
import {IStrategy} from "@eigenlayer/src/contracts/interfaces/IStrategy.sol";
import {EigenLayerDeployer} from "../test/fixtures/EigenLayerDeployer.f.sol";

import {BLS12381} from "../src/lib/bls/BLS12381.sol";

contract BoltManagerEigenLayerTest is Test {
    using BLS12381 for BLS12381.G1Point;

    uint48 public constant EPOCH_DURATION = 1 days;

    BoltValidators public validators;
    BoltManager public manager;
    BoltEigenLayerMiddleware public middleware;
    EigenLayerDeployer public eigenLayerDeployer;

    uint128 public constant PRECONF_MAX_GAS_LIMIT = 5_000_000;

    address staker = makeAddr("staker");
    address validator = makeAddr("validator");
    BLS12381.G1Point validatorPubkey = BLS12381.generatorG1();
    address operator;
    uint256 operatorSk;

    address admin = makeAddr("admin");

    function setUp() public {
        // Set-up accounts
        (operator, operatorSk) = makeAddrAndKey("operator");

        // Deploy EigenLayer contracts.
        // This also deploy a `weth` token and `wethStrat` strategy base available as properties of the contract.
        eigenLayerDeployer = new EigenLayerDeployer(staker);
        eigenLayerDeployer.setUp();

        BoltConfig.ParametersConfig memory config = new Utils().readParameters();

        BoltParameters parameters = new BoltParameters();
        parameters.initialize(
            admin,
            config.epochDuration,
            config.slashingWindow,
            config.maxChallengeDuration,
            config.allowUnsafeRegistration,
            config.challengeBond,
            config.blockhashEvmLookback,
            config.justificationDelay,
            config.eth2GenesisTimestamp,
            config.slotTime,
            config.minimumOperatorStake
        );

        // Deploy Bolt contracts
        validators = new BoltValidators();
        validators.initialize(admin, address(parameters));
        manager = new BoltManager();
        manager.initialize(admin, address(parameters), address(validators));
        middleware = new BoltEigenLayerMiddleware();

        middleware.initialize(
            address(admin),
            address(parameters),
            address(manager),
            address(eigenLayerDeployer.avsDirectory()),
            address(eigenLayerDeployer.delegationManager()),
            address(eigenLayerDeployer.strategyManager())
        );

        // Register the middleware in the manager
        vm.startPrank(admin);
        manager.addRestakingProtocol(address(middleware));
        vm.stopPrank();
    }

    function _adminRoutine() internal {
        // PART 0: Admin setup -- Collateral whitelist
        vm.startPrank(admin);
        middleware.addWhitelistedCollateral(address(eigenLayerDeployer.weth()));
        vm.stopPrank();
        assertEq(middleware.getWhitelistedCollaterals().length, 1);
        assertEq(middleware.getWhitelistedCollaterals()[0], address(eigenLayerDeployer.weth()));
    }

    function _eigenLayerOptInRoutine() internal {
        _adminRoutine();

        // PART 1: External EigenLayer opt-in to BOLT AVS

        // 1. As a staker, I deposit some LSTs into a Stategy via the StrategyManager.depositIntoStrategy function.
        // After this, I get back some shares that I can use at a later time for withdrawal

        vm.startPrank(staker);
        eigenLayerDeployer.weth().approve(address(eigenLayerDeployer.strategyManager()), 1 ether);
        uint256 shares = eigenLayerDeployer.strategyManager().depositIntoStrategy(
            eigenLayerDeployer.wethStrat(), eigenLayerDeployer.weth(), 1 ether
        );
        vm.stopPrank();
        assertEq(eigenLayerDeployer.wethStrat().sharesToUnderlyingView(shares), 1 ether);

        // 2. As a Operator, I register myself into EigenLayer using DelegationManager.registerAsOperator.
        // Note that this function doesn’t require specifying anything related to the service I’m going to provide.
        // However, a parameter describes who can delegate to me whether it can be anyone or a subset of stakers.

        IDelegationManager.OperatorDetails memory operatorDetails =
            IDelegationManager.OperatorDetails(address(0), address(0), 0);
        vm.startPrank(operator);
        eigenLayerDeployer.delegationManager().registerAsOperator(operatorDetails, "https://boltprotocol.xyz");
        vm.stopPrank();

        // 3. As a staker, I can start delegating funds to these operators using
        // the DelegationManager.delegateTo function and specifying to who I wish
        // to delegate my funds

        // NOTE: this signature is not used since the operator allows funds delegated from anyone
        ISignatureUtils.SignatureWithExpiry memory signature = ISignatureUtils.SignatureWithExpiry(bytes(""), 0);
        console.logAddress(eigenLayerDeployer.delegationManager().delegatedTo(staker));
        vm.startPrank(staker);
        eigenLayerDeployer.delegationManager().delegateTo(operator, signature, bytes32(0));
        vm.stopPrank();
        assertEq(eigenLayerDeployer.delegationManager().delegatedTo(staker), operator);

        // 4. As an AVS developer I create an entrypoint contract.
        // Upon deploying the contract it is required to make a call to EL’s
        // AVSDirectory.updateAVSMetadataURI which takes just a string which is a URI.
        // Note that his is not stored anywhere, just an log is emitted.
        // Note that msg.sender which is the ServiceManager contract is used to identify the AVS itself

        vm.prank(admin);
        middleware.updateAVSMetadataURI("https://boltprotocol.xyz");

        // 5. As a operator, I can now opt-in into an AVS by interacting with the ServiceManager.
        // Two steps happen:
        // i. I call the AVS’ ServiceManager.registerOperatorToAVS. The payload is a signature whose digest consists of:
        //     a. my operator address
        //     b. the AVS’ ServiceManager contract address
        //     c. a salt
        //     d. an expiry
        // ii. The contract forwards the call to the AVSDirectory.registerOperatorToAVS to
        // that msg.sender is the AVS contract. Upon successful verification of the signature,
        // the operator is considered REGISTERED in a mapping avsOperatorStatus[msg.sender][operator].

        // Calculate the digest hash
        bytes32 operatorRegistrationDigestHash = eigenLayerDeployer.avsDirectory()
            .calculateOperatorAVSRegistrationDigestHash({
            operator: operator,
            avs: address(middleware),
            salt: bytes32(0),
            expiry: UINT256_MAX
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorSk, operatorRegistrationDigestHash);
        bytes memory operatorRawSignature = abi.encodePacked(r, s, v);
        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature =
            ISignatureUtils.SignatureWithSaltAndExpiry(operatorRawSignature, bytes32(0), UINT256_MAX);
        vm.expectEmit(true, true, true, true);
        emit IAVSDirectory.OperatorAVSRegistrationStatusUpdated(
            operator, address(middleware), IAVSDirectory.OperatorAVSRegistrationStatus.REGISTERED
        );

        vm.prank(operator);
        middleware.registerOperator("https://bolt-rpc.io", operatorSignature);

        assertEq(manager.isOperatorEnabled(operator), true);

        // PART 2: Validator and proposer opt into BOLT manager
        //
        // 1. --- Register Validator in BoltValidators ---

        // pubkeys aren't checked, any point will be fine
        validatorPubkey = BLS12381.generatorG1();

        vm.prank(validator);
        validators.registerValidatorUnsafe(validatorPubkey, PRECONF_MAX_GAS_LIMIT, operator);
        assertEq(validators.getValidatorByPubkey(validatorPubkey).exists, true);
        assertEq(validators.getValidatorByPubkey(validatorPubkey).authorizedOperator, operator);

        // 2. --- Operator and strategy registration into BoltManager (middleware) ---

        middleware.registerStrategy(address(eigenLayerDeployer.wethStrat()));
        assertEq(middleware.isStrategyEnabled(address(eigenLayerDeployer.wethStrat())), true);
    }

    function testDeregisterOperatorFromAVS() public {
        _eigenLayerOptInRoutine();
        vm.prank(operator);
        middleware.deregisterOperator();
        vm.expectRevert(IBoltManager.OperatorNotRegistered.selector);
        manager.isOperatorEnabled(operator);
    }

    function testGetOperatorStake() public {
        _eigenLayerOptInRoutine();

        uint256 amount = middleware.getOperatorStake(operator, address(eigenLayerDeployer.weth()));
        uint256 totalStake = manager.getTotalStake(address(eigenLayerDeployer.weth()));
        assertEq(amount, 1 ether);
        assertEq(totalStake, 1 ether);
    }

    function testProposerStatus() public {
        _eigenLayerOptInRoutine();

        bytes32 pubkeyHash = _pubkeyHash(validatorPubkey);

        IBoltValidators.ProposerStatus memory status = manager.getProposerStatus(pubkeyHash);
        assertEq(status.pubkeyHash, pubkeyHash);
        assertEq(status.operator, operator);
        assertEq(status.active, true);
        assertEq(status.collaterals.length, 1);
        assertEq(status.amounts.length, 1);
        assertEq(status.collaterals[0], address(eigenLayerDeployer.weth()));
        assertEq(status.amounts[0], 1 ether);
    }

    function testProposersLookaheadStatus() public {
        // This also opts in the operator which is needed
        _eigenLayerOptInRoutine();
        bytes32[] memory pubkeyHashes = new bytes32[](10);

        // register 10 proposers with random pubkeys
        for (uint256 i = 0; i < 10; i++) {
            BLS12381.G1Point memory pubkey = BLS12381.generatorG1();
            pubkey.x[0] = pubkey.x[0] + i + 2;
            pubkey.y[0] = pubkey.y[0] + i + 2;

            pubkeyHashes[i] = _pubkeyHash(pubkey);
            validators.registerValidatorUnsafe(pubkey, PRECONF_MAX_GAS_LIMIT, operator);
        }

        IBoltValidators.ProposerStatus[] memory statuses = manager.getProposerStatuses(pubkeyHashes);
        assertEq(statuses.length, 10);
    }

    function testNonExistentProposerStatus() public {
        _eigenLayerOptInRoutine();

        bytes32 pubkeyHash = bytes32(uint256(1));

        vm.expectRevert(IBoltValidators.ValidatorDoesNotExist.selector);
        manager.getProposerStatus(pubkeyHash);
    }

    function testWhitelistedCollaterals() public {
        _adminRoutine();
        address[] memory collaterals = middleware.getWhitelistedCollaterals();
        assertEq(collaterals.length, 1);
        assertEq(collaterals[0], address(eigenLayerDeployer.weth()));
    }

    function testNonWhitelistedCollateral() public {
        _adminRoutine();
        vm.startPrank(admin);
        middleware.removeWhitelistedCollateral(address(eigenLayerDeployer.weth()));
        vm.stopPrank();

        address strat = address(eigenLayerDeployer.wethStrat());
        vm.startPrank(admin);
        vm.expectRevert(IBoltMiddleware.CollateralNotWhitelisted.selector);
        middleware.registerStrategy(strat);
        vm.stopPrank();
    }

    /// @notice Compute the hash of a BLS public key
    function _pubkeyHash(
        BLS12381.G1Point memory _pubkey
    ) internal pure returns (bytes32) {
        uint256[2] memory compressedPubKey = _pubkey.compress();
        return keccak256(abi.encodePacked(compressedPubKey));
    }
}
