// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../interfaces/root/IRootERC20Predicate.sol";
import "../interfaces/IStateSender.sol";

// solhint-disable reason-string
contract RootERC20Predicate is Initializable, IRootERC20Predicate {
    using SafeERC20 for IERC20Metadata;

    IStateSender public stateSender;
    address public exitHelper;
    address public childERC20Predicate;
    address public childTokenTemplate;
    bytes32 public constant DEPOSIT_SIG = keccak256("DEPOSIT");
    bytes32 public constant WITHDRAW_SIG = keccak256("WITHDRAW");
    bytes32 public constant MAP_TOKEN_SIG = keccak256("MAP_TOKEN");

    // assign arbitrary unaccessable address of 1 to native token
    address public constant NATIVE_TOKEN = address(1);
    mapping(address => address) public rootTokenToChildToken;

    /**
     * @notice Initilization function for RootERC20Predicate
     * @param newStateSender Address of StateSender to send deposit information to
     * @param newExitHelper Address of ExitHelper to receive withdrawal information from
     * @param newChildERC20Predicate Address of child ERC20 predicate to communicate with
     * @dev Can only be called once.
     */
    function initialize(
        address newStateSender,
        address newExitHelper,
        address newChildERC20Predicate,
        address newChildTokenTemplate,
        address nativeTokenRootAddress
    ) external initializer {
        require(
            newStateSender != address(0) &&
                newExitHelper != address(0) &&
                newChildERC20Predicate != address(0) &&
                newChildTokenTemplate != address(0),
            "RootERC20Predicate: BAD_INITIALIZATION"
        );
        stateSender = IStateSender(newStateSender);
        exitHelper = newExitHelper;
        childERC20Predicate = newChildERC20Predicate;
        childTokenTemplate = newChildTokenTemplate;
        if (nativeTokenRootAddress != address(0)) {
            rootTokenToChildToken[nativeTokenRootAddress] = 0x0000000000000000000000000000000000001010;
            emit TokenMapped(nativeTokenRootAddress, 0x0000000000000000000000000000000000001010);
        }
        _mapNative();
    }

    /**
     * @inheritdoc IL2StateReceiver
     * @notice Function to be used for token withdrawals
     * @dev Can be extended to include other signatures for more functionality
     */
    function onL2StateReceive(uint256 /* id */, address sender, bytes calldata data) external {
        require(msg.sender == exitHelper, "RootERC20Predicate: ONLY_EXIT_HELPER");
        require(sender == childERC20Predicate, "RootERC20Predicate: ONLY_CHILD_PREDICATE");

        if (bytes32(data[:32]) == WITHDRAW_SIG) {
            _withdraw(data[32:]);
        } else {
            revert("RootERC20Predicate: INVALID_SIGNATURE");
        }
    }

    /**
     * @inheritdoc IRootERC20Predicate
     */
    function deposit(IERC20Metadata rootToken, uint256 amount) external {
        _depositERC20(rootToken, msg.sender, amount);
    }

    /**
     * @inheritdoc IRootERC20Predicate
     */
    function depositTo(IERC20Metadata rootToken, address receiver, uint256 amount) external {
        _depositERC20(rootToken, receiver, amount);
    }

    /**
     * @inheritdoc IRootERC20Predicate
     */
    function depositNativeTo(address receiver) external payable {
        require(msg.value > 0, "RootERC20Predicate: INVALID_AMOUNT");
        _deposit(IERC20Metadata(NATIVE_TOKEN), receiver, msg.value);
    }

    /**
     * @inheritdoc IRootERC20Predicate
     */
    function mapToken(IERC20Metadata rootToken) public returns (address) {
        require(address(rootToken) != address(0), "RootERC20Predicate: INVALID_TOKEN");
        return _map(address(rootToken), rootToken.name(), rootToken.symbol(), rootToken.decimals());
    }

    function _mapNative() private {
        _map(NATIVE_TOKEN, "Ether", "ETH", 18);
    }

    function _map(
        address rootToken,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals
    ) internal returns (address) {
        require(rootTokenToChildToken[rootToken] == address(0), "RootERC20Predicate: ALREADY_MAPPED");

        address childPredicate = childERC20Predicate;

        address childToken = Clones.predictDeterministicAddress(
            childTokenTemplate,
            keccak256(abi.encodePacked(rootToken)),
            childPredicate
        );

        rootTokenToChildToken[address(rootToken)] = childToken;
        stateSender.syncState(
            childPredicate,
            abi.encode(MAP_TOKEN_SIG, rootToken, tokenName, tokenSymbol, tokenDecimals)
        );
        // slither-disable-next-line reentrancy-events
        emit TokenMapped(rootToken, childToken);

        return childToken;
    }

    function _depositERC20(IERC20Metadata rootToken, address receiver, uint256 amount) private {
        uint256 expectedBalance = rootToken.balanceOf(address(this)) + amount;
        _deposit(rootToken, receiver, amount);
        // invariant check to ensure that the root token balance has increased by the amount deposited
        require((rootToken.balanceOf(address(this)) == expectedBalance), "RootERC20Predicate: UNEXPECTED_BALANCE");
    }

    function _deposit(IERC20Metadata rootToken, address receiver, uint256 amount) private {
        address childToken = rootTokenToChildToken[address(rootToken)];

        // The native token does not need to be mapped since it should have been mapped on initialization
        // The native token also cannot be transferred since it was received in the payable function call
        if (address(rootToken) != NATIVE_TOKEN) {
            if (childToken == address(0)) {
                childToken = mapToken(rootToken);
            }
            // ERC20 must be transferred explicitly
            rootToken.safeTransferFrom(msg.sender, address(this), amount);
        }
        assert(childToken != address(0));
        stateSender.syncState(childERC20Predicate, abi.encode(DEPOSIT_SIG, rootToken, msg.sender, receiver, amount));
        // slither-disable-next-line reentrancy-events
        emit ERC20Deposit(address(rootToken), childToken, msg.sender, receiver, amount);
    }

    function _withdraw(bytes calldata data) private {
        (address rootToken, address withdrawer, address receiver, uint256 amount) = abi.decode(
            data,
            (address, address, address, uint256)
        );
        address childToken = rootTokenToChildToken[rootToken];
        assert(childToken != address(0)); // invariant because child predicate should have already mapped tokens

        if (rootToken == NATIVE_TOKEN) {
            (bool success, ) = receiver.call{value: amount}("");
            require(success, "RootERC20Predicate: ETH_TRANSFER_FAILED");
        } else {
            IERC20Metadata(rootToken).safeTransfer(receiver, amount);
        }
        // slither-disable-next-line reentrancy-events
        emit ERC20Withdraw(address(rootToken), childToken, withdrawer, receiver, amount);
    }

    // slither-disable-next-line unused-state,naming-convention
    uint256[50] private __gap;
}
