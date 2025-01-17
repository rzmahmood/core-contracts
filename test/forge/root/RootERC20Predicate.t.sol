// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";

import {RootERC20Predicate} from "contracts/root/RootERC20Predicate.sol";
import {ChildERC20} from "contracts/child/ChildERC20.sol";
import {StateSenderHelper} from "./StateSender.t.sol";
import {PredicateHelper} from "./PredicateHelper.t.sol";
import {MockERC20} from "contracts/mocks/MockERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

abstract contract UninitializedSetup is PredicateHelper, Test {
    event TokenMapped(address indexed rootToken, address indexed childToken);
    event Initialized(uint8 version);
    event StateSynced(uint256 indexed id, address indexed sender, address indexed receiver, bytes data);

    RootERC20Predicate rootERC20Predicate;
    MockERC20 erc20;
    address charlie = makeAddr("charlie");
    address childERC20Predicate = address(0x1004);
    address childTokenTemplate = address(0x1003);
    address ZERO_ADDRESS = address(0);

    function setUp() public virtual override {
        super.setUp();

        rootERC20Predicate = new RootERC20Predicate();
        erc20 = new MockERC20();
    }
}

abstract contract InitializedSetup is UninitializedSetup {
    MockERC20 rootNativeToken;

    function setUp() public virtual override {
        super.setUp();
        rootNativeToken = new MockERC20();

        rootERC20Predicate.initialize(
            address(stateSender),
            address(exitHelper),
            childERC20Predicate,
            childTokenTemplate,
            address(rootNativeToken)
        );
    }
}

contract RootERC20Predicate_Uninitialized is UninitializedSetup {
    function test_UnititializedValues() public {
        assertEq(address(rootERC20Predicate.stateSender()), address(0));
        assertEq(rootERC20Predicate.exitHelper(), address(0));
        assertEq(rootERC20Predicate.childERC20Predicate(), address(0));
        assertEq(rootERC20Predicate.childTokenTemplate(), address(0));
        assertEq(rootERC20Predicate.NATIVE_TOKEN(), address(1));
    }

    function test_onL2StateReceive_Reverts() public {
        bytes memory exitData = abi.encode(
            keccak256("WITHDRAW"),
            makeAddr("rootToken"),
            makeAddr("withdrawer"),
            makeAddr("receiver"),
            100
        );
        vm.expectRevert("RootERC20Predicate: ONLY_EXIT_HELPER");
        rootERC20Predicate.onL2StateReceive(1, address(0), exitData);
    }

    function test_deposit_Reverts() public {
        erc20.mint(charlie, 100);
        vm.prank(charlie);
        erc20.approve(address(rootERC20Predicate), 100);
        // reverts `syncState` call on 0 address
        vm.expectRevert();
        rootERC20Predicate.deposit(erc20, 100);
    }

    function test_depositTo_Reverts() public {
        erc20.mint(charlie, 100);
        vm.prank(charlie);
        erc20.approve(address(rootERC20Predicate), 100);
        // reverts `syncState` call on 0 address
        vm.expectRevert();
        rootERC20Predicate.depositTo(erc20, charlie, 100);
    }

    function test_depositNativeTo_Reverts() public {
        vm.deal(charlie, 100);
        vm.prank(charlie);
        // fails due to mapping assertion violation
        vm.expectRevert();
        rootERC20Predicate.depositNativeTo{value: 100}(charlie);
    }

    function test_mapToken_Reverts() public {
        vm.expectRevert();
        // reverts `syncState` call on 0 address
        rootERC20Predicate.mapToken(erc20);
    }

    function test_initializeZeroAddress_Reverts() public {
        bytes memory initErr = "RootERC20Predicate: BAD_INITIALIZATION";
        vm.expectRevert(initErr);
        rootERC20Predicate.initialize(
            ZERO_ADDRESS,
            address(exitHelper),
            childERC20Predicate,
            childTokenTemplate,
            address(erc20)
        );
        vm.expectRevert(initErr);
        rootERC20Predicate.initialize(
            address(stateSender),
            ZERO_ADDRESS,
            childERC20Predicate,
            childTokenTemplate,
            address(erc20)
        );
        vm.expectRevert(initErr);
        rootERC20Predicate.initialize(
            address(stateSender),
            address(exitHelper),
            ZERO_ADDRESS,
            childTokenTemplate,
            address(erc20)
        );
        vm.expectRevert(initErr);
        rootERC20Predicate.initialize(
            address(stateSender),
            address(exitHelper),
            address(childERC20Predicate),
            ZERO_ADDRESS,
            address(erc20)
        );
    }

    function test_initializeNativeTokenRootZero_NoMapping() public skipTest {
        // TODO: Implement once foundry supports negative assertions
        // https://github.com/foundry-rs/foundry/issues/509
    }

    function test_initializeNoZeroNativeToken() public {
        address childTokenForEther = Clones.predictDeterministicAddress(
            childTokenTemplate,
            keccak256(abi.encodePacked(rootERC20Predicate.NATIVE_TOKEN())),
            childERC20Predicate
        );

        vm.expectEmit(true, true, true, true);
        emit TokenMapped(address(erc20), address(0x1010));
        vm.expectEmit(true, true, true, false);
        emit StateSynced(1, address(rootERC20Predicate), childERC20Predicate, "");
        vm.expectEmit(true, true, true, true);
        emit TokenMapped(rootERC20Predicate.NATIVE_TOKEN(), childTokenForEther);
        vm.expectEmit(true, true, true, true);
        emit Initialized(1);

        rootERC20Predicate.initialize(
            address(stateSender),
            address(exitHelper),
            childERC20Predicate,
            childTokenTemplate,
            address(erc20)
        );
    }
}

contract RootERC20Predicate_Initialized is InitializedSetup {
    function testDeposit() public {
        rootNativeToken.mint(charlie, 100);

        vm.startPrank(charlie);
        rootNativeToken.approve(address(rootERC20Predicate), 1);
        rootERC20Predicate.deposit(rootNativeToken, 1);
        vm.stopPrank();

        assertEq(rootNativeToken.balanceOf(address(rootERC20Predicate)), 1);
        assertEq(rootNativeToken.balanceOf(address(charlie)), 99);
    }

    function testDepositNativeToken() public {
        uint256 startBalance = 100;
        vm.deal(charlie, startBalance);

        vm.startPrank(charlie);
        rootERC20Predicate.depositNativeTo{value: 1}(charlie);
        assertEq(charlie.balance, 99);
        assertEq(address(rootERC20Predicate).balance, 1);
        vm.stopPrank();
    }
}
