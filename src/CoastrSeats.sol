// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Coastr seats
/// @notice One seat is one hour on one seller's GPU, minted as an ERC-721 when bought.
/// The price is held in escrow: the seller claims it once the hour is over, and the
/// operator can refund the holder if the seller never served the hour.
/// Seats can change hands until the hour starts; after that they can only be redeemed.
contract CoastrSeats is ERC721, Ownable, ReentrancyGuard {
    struct Seat {
        address seller;
        uint64 start;
        uint64 end;
        uint128 price;
        bool sold;
        bool redeemed;
        bool settled;
    }

    uint256 public constant HOUR = 3600;
    uint16 public constant MAX_FEE_BPS = 1000;

    uint256 public nextId = 1;
    uint16 public feeBps;
    address public feeTo;
    mapping(uint256 => Seat) public seats;
    mapping(uint256 => address) public redeemedBy;

    event Listed(uint256 indexed id, address indexed seller, uint64 start, uint128 price);
    event Cancelled(uint256 indexed id);
    event Bought(uint256 indexed id, address indexed buyer, uint128 price);
    event Redeemed(uint256 indexed id, address indexed holder);
    event Claimed(uint256 indexed id, address indexed seller, uint256 toSeller, uint256 fee);
    event Refunded(uint256 indexed id, address indexed to, uint256 amount);
    event FeeChanged(address feeTo, uint16 feeBps);

    error NoSuchSeat();
    error NotSeller();
    error AlreadySold();
    error NotSold();
    error WrongPrice();
    error BadTime();
    error OwnSeat();
    error NotHolder();
    error AlreadySettled();
    error TransferLocked();
    error FeeTooHigh();
    error PayoutFailed();

    constructor(address feeTo_, uint16 feeBps_) ERC721("Coastr Seat", "SEAT") Ownable(msg.sender) {
        _setFee(feeTo_, feeBps_);
    }

    // ---- Sellers ------------------------------------------------------------

    /// @notice List one hour starting at `start` (unix seconds) for `price` wei.
    function list(uint64 start, uint128 price) public returns (uint256 id) {
        if (price == 0) revert WrongPrice();
        if (uint256(start) + HOUR <= block.timestamp) revert BadTime();
        id = nextId++;
        seats[id] = Seat(msg.sender, start, start + uint64(HOUR), price, false, false, false);
        emit Listed(id, msg.sender, start, price);
    }

    /// @notice List several hours at the same price. Returns the first id; the rest follow in order.
    function listMany(uint64[] calldata starts, uint128 price) external returns (uint256 firstId) {
        firstId = nextId;
        for (uint256 i = 0; i < starts.length; i++) list(starts[i], price);
    }

    /// @notice Withdraw an unsold hour.
    function cancel(uint256 id) external {
        Seat storage s = _seat(id);
        if (s.seller != msg.sender) revert NotSeller();
        if (s.sold) revert AlreadySold();
        delete seats[id];
        emit Cancelled(id);
    }

    /// @notice Collect the escrowed price once the hour is over (minus the protocol fee).
    function claim(uint256 id) external nonReentrant {
        _claim(id);
    }

    /// @notice Collect several finished hours in one transaction.
    function claimMany(uint256[] calldata ids) external nonReentrant {
        for (uint256 i = 0; i < ids.length; i++) _claim(ids[i]);
    }

    // ---- Buyers -------------------------------------------------------------

    /// @notice Buy a listed hour. The seat is minted to the buyer and the payment held in escrow.
    function buy(uint256 id) external payable nonReentrant {
        Seat storage s = _seat(id);
        if (s.sold) revert AlreadySold();
        if (msg.sender == s.seller) revert OwnSeat();
        if (block.timestamp >= s.end) revert BadTime();
        if (msg.value != s.price) revert WrongPrice();
        s.sold = true;
        _mint(msg.sender, id);
        emit Bought(id, msg.sender, s.price);
    }

    /// @notice Buy an hour that has already started and use it at once, in one transaction.
    /// No token is minted: the seat goes straight to "redeemed by" the renter.
    function rentNow(uint256 id) external payable nonReentrant {
        Seat storage s = _seat(id);
        if (s.sold) revert AlreadySold();
        if (msg.sender == s.seller) revert OwnSeat();
        if (block.timestamp < s.start || block.timestamp >= s.end) revert BadTime();
        if (msg.value != s.price) revert WrongPrice();
        s.sold = true;
        s.redeemed = true;
        redeemedBy[id] = msg.sender;
        emit Bought(id, msg.sender, s.price);
        emit Redeemed(id, msg.sender);
    }

    /// @notice Burn your seat during its hour to start using the GPU.
    function redeem(uint256 id) external {
        Seat storage s = _seat(id);
        if (_ownerOf(id) != msg.sender) revert NotHolder();
        if (block.timestamp < s.start || block.timestamp >= s.end) revert BadTime();
        s.redeemed = true;
        redeemedBy[id] = msg.sender;
        _burn(id);
        emit Redeemed(id, msg.sender);
    }

    // ---- Operator -----------------------------------------------------------

    /// @notice Refund the holder (or the redeemer) when the seller didn't serve the hour.
    function refund(uint256 id) external onlyOwner nonReentrant {
        Seat storage s = _seat(id);
        if (!s.sold) revert NotSold();
        if (s.settled) revert AlreadySettled();
        s.settled = true;
        address to = _ownerOf(id);
        if (to != address(0)) _burn(id);
        else to = redeemedBy[id];
        _pay(to, s.price);
        emit Refunded(id, to, s.price);
    }

    function setFee(address feeTo_, uint16 feeBps_) external onlyOwner {
        _setFee(feeTo_, feeBps_);
    }

    // ---- Internals ----------------------------------------------------------

    function _claim(uint256 id) private {
        Seat storage s = _seat(id);
        if (s.seller != msg.sender) revert NotSeller();
        if (!s.sold) revert NotSold();
        if (s.settled) revert AlreadySettled();
        if (block.timestamp < s.end) revert BadTime();
        s.settled = true;
        uint256 fee = (uint256(s.price) * feeBps) / 10_000;
        uint256 toSeller = uint256(s.price) - fee;
        _pay(s.seller, toSeller);
        if (fee > 0) _pay(feeTo, fee);
        emit Claimed(id, s.seller, toSeller, fee);
    }

    /// Seats trade freely before their hour; once it starts they can only be redeemed or burned.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && block.timestamp >= seats[tokenId].start) revert TransferLocked();
        return super._update(to, tokenId, auth);
    }

    function _seat(uint256 id) private view returns (Seat storage s) {
        s = seats[id];
        if (s.seller == address(0)) revert NoSuchSeat();
    }

    function _setFee(address feeTo_, uint16 feeBps_) private {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeTo = feeTo_;
        feeBps = feeBps_;
        emit FeeChanged(feeTo_, feeBps_);
    }

    function _pay(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayoutFailed();
    }
}
