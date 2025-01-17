// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "../../lib/WithdrawalQueue.sol";
import "../../interfaces/child/validator/IValidatorSet.sol";
import "../../interfaces/IStateSender.sol";
import "../../child/NetworkParams.sol";
import "../System.sol";

contract ValidatorSet is IValidatorSet, ERC20VotesUpgradeable, System {
    using WithdrawalQueueLib for WithdrawalQueue;

    bytes32 private constant STAKE_SIG = keccak256("STAKE");
    bytes32 private constant UNSTAKE_SIG = keccak256("UNSTAKE");
    bytes32 private constant SLASH_SIG = keccak256("SLASH");

    IStateSender private stateSender;
    address private stateReceiver;
    address private rootChainManager;
    NetworkParams private networkParams;

    uint256 public currentEpochId;

    mapping(uint256 => uint256) private _commitBlockNumbers;
    mapping(address => WithdrawalQueue) private withdrawals;
    mapping(uint256 => Epoch) public epochs;
    uint256[] public epochEndBlocks;

    function initialize(
        address newStateSender,
        address newStateReceiver,
        address newRootChainManager,
        address newNetworkParams,
        ValidatorInit[] memory initialValidators
    ) public initializer {
        require(
            newStateSender != address(0) && newStateReceiver != address(0) && newRootChainManager != address(0),
            "INVALID_INPUT"
        );
        __ERC20_init("ValidatorSet", "VSET");
        stateSender = IStateSender(newStateSender);
        stateReceiver = newStateReceiver;
        rootChainManager = newRootChainManager;
        networkParams = NetworkParams(newNetworkParams);
        for (uint256 i = 0; i < initialValidators.length; ) {
            _stake(initialValidators[i].addr, initialValidators[i].stake);
            unchecked {
                ++i;
            }
        }
        epochEndBlocks.push(0);
        currentEpochId = 1;
    }

    /**
     * @inheritdoc IValidatorSet
     */
    function commitEpoch(uint256 id, Epoch calldata epoch) external onlySystemCall {
        uint256 newEpochId = currentEpochId++;
        require(id == newEpochId, "UNEXPECTED_EPOCH_ID");
        require(epoch.endBlock > epoch.startBlock, "NO_BLOCKS_COMMITTED");
        require(
            (epoch.endBlock - epoch.startBlock + 1) % networkParams.epochSize() == 0,
            "EPOCH_MUST_BE_DIVISIBLE_BY_EPOCH_SIZE"
        );
        require(epochs[newEpochId - 1].endBlock + 1 == epoch.startBlock, "INVALID_START_BLOCK");
        epochs[newEpochId] = epoch;
        _commitBlockNumbers[newEpochId] = block.number;
        epochEndBlocks.push(epoch.endBlock);
        emit NewEpoch(id, epoch.startBlock, epoch.endBlock, epoch.epochRoot);
    }

    function onStateReceive(uint256 /*counter*/, address sender, bytes calldata data) external override {
        require(msg.sender == stateReceiver && sender == rootChainManager, "INVALID_SENDER");
        if (bytes32(data[:32]) == STAKE_SIG) {
            (address validator, uint256 amount) = abi.decode(data[32:], (address, uint256));
            _stake(validator, amount);
        }
    }

    /**
     * @inheritdoc IValidatorSet
     */
    function unstake(uint256 amount) external {
        _burn(msg.sender, amount);
        _registerWithdrawal(msg.sender, amount);
    }

    /**
     * @inheritdoc IValidatorSet
     */
    function withdraw() external {
        WithdrawalQueue storage queue = withdrawals[msg.sender];
        (uint256 amount, uint256 newHead) = queue.withdrawable(currentEpochId);
        queue.head = newHead;
        emit Withdrawal(msg.sender, amount);
        stateSender.syncState(rootChainManager, abi.encode(UNSTAKE_SIG, msg.sender, amount));
    }

    /**
     * @inheritdoc IValidatorSet
     */
    // slither-disable-next-line unused-return
    function withdrawable(address account) external view returns (uint256 amount) {
        (amount, ) = withdrawals[account].withdrawable(currentEpochId);
    }

    /**
     * @inheritdoc IValidatorSet
     */
    function pendingWithdrawals(address account) external view returns (uint256) {
        return withdrawals[account].pending(currentEpochId);
    }

    /**
     * @inheritdoc IValidatorSet
     */
    function totalBlocks(uint256 epochId) external view returns (uint256 length) {
        uint256 endBlock = epochs[epochId].endBlock;
        length = endBlock == 0 ? 0 : endBlock - epochs[epochId].startBlock + 1;
    }

    function balanceOfAt(address account, uint256 epochNumber) external view returns (uint256) {
        return super.getPastVotes(account, _commitBlockNumbers[epochNumber]);
    }

    function totalSupplyAt(uint256 epochNumber) external view returns (uint256) {
        return super.getPastTotalSupply(_commitBlockNumbers[epochNumber]);
    }

    function _registerWithdrawal(address account, uint256 amount) internal {
        withdrawals[account].append(amount, currentEpochId + networkParams.withdrawalWaitPeriod());
        emit WithdrawalRegistered(account, amount);
    }

    /// @dev no public facing slashing function implemented yet
    // slither-disable-next-line dead-code
    function _slash(address validator) internal {
        // unstake validator
        _burn(validator, balanceOf(validator));
        // remove pending withdrawals
        // slither-disable-next-line mapping-deletion
        delete withdrawals[validator];
        // slash validator
        stateSender.syncState(rootChainManager, abi.encode(SLASH_SIG, validator));
    }

    function _stake(address validator, uint256 amount) internal {
        assert(balanceOf(validator) + amount <= _maxSupply());
        _mint(validator, amount);
        _delegate(validator, validator);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0), "TRANSFER_FORBIDDEN");
        super._beforeTokenTransfer(from, to, amount);
    }

    function _delegate(address delegator, address delegatee) internal override {
        if (delegator != delegatee) revert("DELEGATION_FORBIDDEN");
        super._delegate(delegator, delegatee);
    }
}
