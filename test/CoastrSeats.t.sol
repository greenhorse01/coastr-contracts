// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoastrSeats} from "../src/CoastrSeats.sol";

contract CoastrSeatsTest is Test {
    CoastrSeats market;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address other = makeAddr("other");
    address treasury = makeAddr("treasury");
    uint64 start;
    uint128 constant PRICE = 0.01 ether;

    function setUp() public {
        vm.warp(1_800_000_000);
        market = new CoastrSeats(treasury, 500); // 5% fee
        start = uint64(block.timestamp + 2 hours);
        vm.deal(buyer, 1 ether);
        vm.deal(other, 1 ether);
    }

    function _listAndBuy() internal returns (uint256 id) {
        vm.prank(seller);
        id = market.list(start, PRICE);
        vm.prank(buyer);
        market.buy{value: PRICE}(id);
    }

    function test_listAndBuyMintsSeatAndEscrows() public {
        uint256 id = _listAndBuy();
        assertEq(market.ownerOf(id), buyer);
        assertEq(address(market).balance, PRICE);
        (,,,, bool sold,,) = market.seats(id);
        assertTrue(sold);
    }

    function test_buyRejectsWrongPriceAndOwnSeat() public {
        vm.prank(seller);
        uint256 id = market.list(start, PRICE);
        vm.prank(buyer);
        vm.expectRevert(CoastrSeats.WrongPrice.selector);
        market.buy{value: PRICE - 1}(id);
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert(CoastrSeats.OwnSeat.selector);
        market.buy{value: PRICE}(id);
    }

    function test_cannotBuyTwice() public {
        uint256 id = _listAndBuy();
        vm.prank(other);
        vm.expectRevert(CoastrSeats.AlreadySold.selector);
        market.buy{value: PRICE}(id);
    }

    function test_resaleAllowedBeforeStartOnly() public {
        uint256 id = _listAndBuy();
        vm.prank(buyer);
        market.transferFrom(buyer, other, id);
        assertEq(market.ownerOf(id), other);
        vm.warp(start);
        vm.prank(other);
        vm.expectRevert(CoastrSeats.TransferLocked.selector);
        market.transferFrom(other, buyer, id);
    }

    function test_redeemOnlyDuringTheHour() public {
        uint256 id = _listAndBuy();
        vm.prank(buyer);
        vm.expectRevert(CoastrSeats.BadTime.selector);
        market.redeem(id);
        vm.warp(start + 10 minutes);
        vm.prank(buyer);
        market.redeem(id);
        assertEq(market.redeemedBy(id), buyer);
        vm.expectRevert();
        market.ownerOf(id);
    }

    function test_claimAfterTheHourPaysSellerMinusFee() public {
        uint256 id = _listAndBuy();
        vm.prank(seller);
        vm.expectRevert(CoastrSeats.BadTime.selector);
        market.claim(id);
        vm.warp(start + 1 hours);
        vm.prank(seller);
        market.claim(id);
        assertEq(seller.balance, PRICE * 95 / 100);
        assertEq(treasury.balance, PRICE * 5 / 100);
        vm.prank(seller);
        vm.expectRevert(CoastrSeats.AlreadySettled.selector);
        market.claim(id);
    }

    function test_operatorRefundsHolderWhenSellerNoShows() public {
        uint256 id = _listAndBuy();
        uint256 before = buyer.balance;
        market.refund(id);
        assertEq(buyer.balance, before + PRICE);
        vm.warp(start + 1 hours);
        vm.prank(seller);
        vm.expectRevert(CoastrSeats.AlreadySettled.selector);
        market.claim(id);
    }

    function test_refundAfterRedeemGoesToRedeemer() public {
        uint256 id = _listAndBuy();
        vm.warp(start + 5 minutes);
        vm.prank(buyer);
        market.redeem(id);
        uint256 before = buyer.balance;
        market.refund(id);
        assertEq(buyer.balance, before + PRICE);
    }

    function test_onlyOwnerRefundsAndFeeIsCapped() public {
        uint256 id = _listAndBuy();
        vm.prank(other);
        vm.expectRevert();
        market.refund(id);
        vm.expectRevert(CoastrSeats.FeeTooHigh.selector);
        market.setFee(treasury, 1001);
    }

    function test_listManyAndCancelUnsold() public {
        uint64[] memory starts = new uint64[](3);
        for (uint256 i = 0; i < 3; i++) starts[i] = start + uint64(i * 1 hours);
        vm.prank(seller);
        uint256 first = market.listMany(starts, PRICE);
        assertEq(market.nextId(), first + 3);
        vm.prank(seller);
        market.cancel(first + 1);
        vm.prank(buyer);
        vm.expectRevert(CoastrSeats.NoSuchSeat.selector);
        market.buy{value: PRICE}(first + 1);
    }

    function test_cannotListPastHours() public {
        vm.prank(seller);
        vm.expectRevert(CoastrSeats.BadTime.selector);
        market.list(uint64(block.timestamp - 2 hours), PRICE);
    }

    function test_rentNowBuysAndRedeemsInOneStep() public {
        vm.prank(seller);
        uint256 id = market.list(start, PRICE);
        vm.prank(buyer);
        vm.expectRevert(CoastrSeats.BadTime.selector);
        market.rentNow{value: PRICE}(id);
        vm.warp(start + 1 minutes);
        vm.prank(buyer);
        market.rentNow{value: PRICE}(id);
        assertEq(market.redeemedBy(id), buyer);
        assertEq(address(market).balance, PRICE);
        vm.prank(other);
        vm.expectRevert(CoastrSeats.AlreadySold.selector);
        market.rentNow{value: PRICE}(id);
        uint256 before = buyer.balance;
        market.refund(id);
        assertEq(buyer.balance, before + PRICE);
    }

    function test_claimManyCollectsEveryFinishedHour() public {
        uint64[] memory starts = new uint64[](2);
        starts[0] = start; starts[1] = start + 1 hours;
        vm.prank(seller);
        uint256 first = market.listMany(starts, PRICE);
        vm.startPrank(buyer);
        market.buy{value: PRICE}(first);
        market.buy{value: PRICE}(first + 1);
        vm.stopPrank();
        vm.warp(start + 2 hours);
        uint256[] memory ids = new uint256[](2);
        ids[0] = first; ids[1] = first + 1;
        vm.prank(seller);
        market.claimMany(ids);
        assertEq(seller.balance, 2 * PRICE * 95 / 100);
        assertEq(address(market).balance, 0);
    }
}
