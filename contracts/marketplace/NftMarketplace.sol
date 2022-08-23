// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title NFT Marketplace
 * Facilitate NFT exchange.
 */

contract NFTMarketplace is ERC721Holder, Ownable {

  event MakeOrder(uint256 id, bytes32 indexed hash, address indexed seller, uint8 orderType, uint256 startPrice, uint256 endPrice, uint256 endBlock, uint256 timestamp);
  
  event CancelOrder(uint256 id, bytes32 indexed hash, address indexed seller, uint256 timestamp);
  
  event Bid(uint256 id, bytes32 indexed hash, address indexed bidder, uint256 bidPrice, uint256 timestamp);
  
  event CancelBid(uint256 id, bytes32 indexed hash, address indexed bidder, uint256 timestamp);
  
  event Claim(uint256 id, bytes32 indexed hash, address seller, address indexed taker, uint256 price, uint256 timestamp);

  event OrderExtended(uint256 id, bytes32 indexed hash, uint256 timestamp);

  /**
  * Used to represent the current auction status of an NFT
  * @dev The orderType represents the auction type where 0 = Fixed Price, 1 = Dutch Auction, and 2 = English Auction
  */
  struct Order {
    uint8 orderType;
    address seller;
    uint256 tokenId;
    uint256 startPrice;
    uint256 endPrice;
    uint256 startBlock;
    uint256 endBlock;
    uint256 lastBidPrice;
    address lastBidder;
    bool isSold;
    bool isCancelled;
    bool allowSniping;
  }

  /* tokenId => ordersIds */
  mapping (uint256 => bytes32[]) public orderIdByToken;
  
  /* seller => orderIds */
  mapping (address => bytes32[]) public orderIdBySeller;
  
  /* orderId => order */
  mapping (bytes32 => Order) public orderInfo;

  bool public marketIsActive = false;

  /* 5.5 average block time scaled to 1000 */
  uint256 internal avgBlockTime = 5500;

  /* duration extension expressed in seconds (300 seconds = 5 minutes) */
  uint256 public durationExtension = 300;
  
  uint16 public feePercent;
  
  address public feeAddress;
  
  IERC721 public immutable nftContract;

  constructor(uint16 _feePercent, IERC721 _nftContract) {
    require(_feePercent <= 10000, "Input value is more than 100%");
    feeAddress = msg.sender;
    feePercent = _feePercent;
    nftContract = _nftContract;
  }

  /**
   * Sets the average block time value. Used to find the number of blocks in a given number of seconds.
   * @dev Reverts when caller is not the contract owner.
   * @param blockTime The value set as average block time.
   */
  function setBlockTime(uint256 blockTime) public onlyOwner {
    avgBlockTime = blockTime;
  }

  /**
   * Returns the number of blocks within the given number of seconds based on the average block time.
   * @param _seconds The number of seconds used to calculate the number of blocks.
   */
  function _secondsToBlocks(uint256 _seconds) internal view returns(uint256) {
    return _seconds / (avgBlockTime / 1000);
  }

  /**
   * Disables public functions in the contract if enabled, enables if disabled.
   * @dev Reverts if not called by the contract owner.
   */
  function flipMarketState() external onlyOwner {
    marketIsActive = !marketIsActive;
  }

  /**
   * Sets the value of durationExtension.
   * @dev durationExtension is the number of seconds to extend an English auction.
   * @dev When a user performs a bid in the last 5 minutes before the auction expires, the auction end time is extended for `durationExtension` seconds.
   * @param _seconds The value to set as durationExtension, expressed in seconds.
   */
  function setDurationExtension (uint256 _seconds) public onlyOwner{
    durationExtension = _seconds;
  }

  /**
   * Returns the current price of an order.
   * @dev Returns the start price if auction is Fixed Price.
   * @dev Returns the last bid price (if any) or start price if auction is English.
   * @dev Returns the computed current price if auction is Dutch.
   * @param _order The identifier of order, referencing the order to get the current price.
   */
  function getCurrentPrice(bytes32 _order) public view returns (uint256) {
    Order storage o = orderInfo[_order];
    uint8 orderType = o.orderType;

    if (orderType == 0) {
      // Fixed Price
      return o.startPrice;

    } else if (orderType == 2) {

      // English Auction      
      uint256 lastBidPrice = o.lastBidPrice;
      return lastBidPrice == 0 ? o.startPrice : lastBidPrice;

    } else {

      if (block.number > o.endBlock) {
        return o.endPrice;
      }

      // Dutch auction
      uint256 _startPrice = o.startPrice;
      uint256 _startBlock = o.startBlock;
      uint256 tickPerBlock = (_startPrice - o.endPrice) / (o.endBlock - _startBlock);
      return _startPrice - ((block.number - _startBlock) * tickPerBlock);
    }
  }

  /**
   * Returns a token's order length.
   * @param _tokenId The identifier of the token.
   */
  function tokenOrderLength(uint256 _tokenId) public view returns (uint256) {
    return orderIdByToken[_tokenId].length;
  }

  /**
   * Returns a seller's order length.
   * @param _seller The address of the seller.
   */
  function sellerOrderLength(address _seller) external view returns (uint256) {
    return orderIdBySeller[_seller].length;
  }

  /**
   * Creates multiple auctions of the same type, start price, end price, and duration.
   * @dev Reverts if marketIsActive is false.
   * @dev Reverts if _ids array is empty.
   * @dev Reverts if auction _type is Dutch and _endPrice is higher than _startPrice.
   * @param _ids The identifiers of the tokens.
   * @param _startPrice The start price of the auctions.
   * @param _endPrice The end price of the auctions.
   * @param _endBlock The end time of the auctions, expressed as block number.
   * @param _type The auction type.
   * @param _allowSniping Sniping switch for English auctions. When set to true and someone bids in the last 5 minutes of the auction, the auction is not extended.
   */
  function bulkList(uint256[] memory _ids, uint256 _startPrice, uint256 _endPrice, uint256 _endBlock, uint256 _type, bool _allowSniping) public {
    require(marketIsActive == true, "Market must be active");
    require(_ids.length > 0, "At least 1 ID must be supplied");

    if(_type == 0) {
      for(uint i=0; i < _ids.length; i++) {
        _makeOrder(0, _ids[i], _startPrice, 0, _endBlock, false);
      }
    }

    if(_type == 1) {
      require(_startPrice > _endPrice, "End price higher than start");
      for(uint i=0; i < _ids.length; i++) {
        _makeOrder(1, _ids[i], _startPrice, _endPrice, _endBlock, false);
      }
    }

    if(_type == 2) {
      for(uint i=0; i < _ids.length; i++) {
        _makeOrder(2, _ids[i], _startPrice, 0, _endBlock, _allowSniping);
      }
    }
  }

  /**
   * Creates a Fixed Price auction for an NFT.
   * @dev _endBlock can be set to 0 to create an auction with no expiration.
   * @dev Reverts if marketIsActive is false.
   * @param _tokenId The token identifier.
   * @param _price The value set as the auction price.
   * @param _endBlock The end time of the auction, expressed as block number.
   */
  function fixedPrice(uint256 _tokenId, uint256 _price, uint256 _endBlock) public {
    require(marketIsActive == true, "Market must be active");
    _makeOrder(0, _tokenId, _price, 0, _endBlock, false);
  }

  /**
   * Creates a Dutch auction for an NFT.
   * @dev Reverts if marketIsActive is false.
   * @dev Reverts if _endPrice is higher than _startPrice.
   * @param _tokenId The token identifier.
   * @param _startPrice The value set as the auction start price.
   * @param _endPrice The value set as the auction end price.
   * @param _endBlock The end time of the auction, expressed as block number.
   */
  function dutchAuction(uint256 _tokenId, uint256 _startPrice, uint256 _endPrice, uint256 _endBlock) public {
    require(marketIsActive == true, "Market must be active");
    require(_startPrice > _endPrice, "End price higher than start");
    _makeOrder(1, _tokenId, _startPrice, _endPrice, _endBlock, false);
  }

  /**
   * Creates an English auction for an NFT.
   * @dev Reverts if marketIsActive is false.
   * @param _tokenId The token identifier.
   * @param _startPrice The value set as the auction start price.
   * @param _endBlock The end time of the auction, expressed as block number.
   * @param _allowSniping Sniping switch for English auctions. When set to true and someone bids in the last 5 minutes of the auction, the auction is not extended.
   */
  function englishAuction(uint256 _tokenId, uint256 _startPrice, uint256 _endBlock, bool _allowSniping) public {
    require(marketIsActive == true, "Market must be active");
    _makeOrder(2, _tokenId, _startPrice, 0, _endBlock, _allowSniping);
  }


  /**
   * Creates an auction for an NFT of type Fixed Price, English or Dutch.
   * @dev For Fixed Price and English auction, _endBlock can be set to 0 to mark an auction with no expiration.
   * @dev _endBlock is required for Dutch auction.
   * @dev Reverts if auction type is Dutch and duration is 0 or _endBlock is not a future block.
   * @dev Reverts if auction type is English or Fixed and _endBlock is not 0 and not a future block.
   * @dev Reverts if caller is not the original owner of the NFT
   * @dev emits a MakeOrder event
   * @param _orderType The auction type.
   * @param _tokenId The token identifier.
   * @param _startPrice The value set as the auction start price.
   * @param _endPrice The value set as the auction end price.
   * @param _endBlock The end time of the auction, expressed as block number.
   * @param _allowSniping Sniping switch for English auctions. When set to true and someone bids in the last 5 minutes of the auction, the auction is not extended.
   */
  function _makeOrder(
    uint8 _orderType,
    uint256 _tokenId,
    uint256 _startPrice,
    uint256 _endPrice,
    uint256 _endBlock,
    bool _allowSniping
  ) internal {

    if (_orderType != 1) {
      if (_endBlock != 0) {
        require(_endBlock > block.number, "Duration must be more than zero");
      }
    } else {
      require(_endBlock > block.number, "Duration must be more than zero");
    }

    bytes32 hash = _hash(_tokenId, msg.sender);
    orderInfo[hash] = Order(_orderType, msg.sender, _tokenId, _startPrice, _endPrice, block.number, _endBlock, 0, address(0), false, false, _allowSniping);
    orderIdByToken[_tokenId].push(hash);
    orderIdBySeller[msg.sender].push(hash);

    nftContract.safeTransferFrom(msg.sender, address(this), _tokenId);

    emit MakeOrder(_tokenId, hash, msg.sender, _orderType, _startPrice, _endPrice, _endBlock, block.timestamp);
  }

  /**
   * Creates a hash of the current block, _tokenId, and _seller. Used to create a unique order id.
   * @param _tokenId The token identifier.
   * @param _seller The address of the seller.
   */
  function _hash(uint256 _tokenId, address _seller) internal view returns (bytes32) {
    return keccak256(abi.encodePacked(block.number, _tokenId, _seller));
  }

  /**
   * Bids on an English auction.
   * @dev Bids must be at least 5% higher than the previous bid.
   * @dev If sniping is disabled and someone bids in the last 5 minutes, the auction will automatically extend by `durationExtension` seconds.
   * @dev If sniping is enabled and someone bids in the last 5 minutes, the auction deadline will not be extended.
   * @dev Refunds the previous last bid the the previous last bidder whenever there is a new bid.
   * @dev Reverts if market is not active.
   * @dev Reverts if auction is not an English auction.
   * @dev Reverts if auction is already cancelled.
   * @dev Reverts if bidder is the seller.
   * @dev Reverts if auction has an expiration that has already ended.
   * @dev Reverts if bid price is not 5% greater than the last bid price (if any).
   * @dev Reverts if bid price is not greater than the start price (if no last bid price).
   * @dev Emits an OrderExtended event if auction is extended.
   * @dev Emits a Bid event.
   * @param _order The order identifier, referencing the auction to bid.
   */
  function bid(bytes32 _order) payable external {
    require(marketIsActive == true, "Market must be active");

    Order storage o = orderInfo[_order];
    uint256 endBlock = o.endBlock;
    uint256 lastBidPrice = o.lastBidPrice;
    address lastBidder = o.lastBidder;

    require(o.orderType == 2, "only for English Auction");
    require(o.isCancelled == false, "Canceled order");
    require(o.seller != msg.sender, "Can not bid on your own order");

    if (endBlock != 0) {
      // if auction has expiration, require that auction is not expired
      require(block.number <= endBlock, "Auction has ended");
    }

    if (lastBidPrice != 0) {
      require(msg.value >= lastBidPrice + (lastBidPrice / 20), "low price bid");  //5%
    } else {
      require(msg.value >= o.startPrice && msg.value > 0, "low price bid");
    }

    if (endBlock != 0 && !o.allowSniping) {
      if (block.number > endBlock - _secondsToBlocks(300)) {
        o.endBlock = endBlock + _secondsToBlocks(durationExtension);
        emit OrderExtended(o.tokenId, _order, block.timestamp);
      }
    }

    o.lastBidder = msg.sender;
    o.lastBidPrice = msg.value;

    if (lastBidPrice != 0) {
      payable(lastBidder).transfer(lastBidPrice);
    }

    emit Bid(o.tokenId, _order, msg.sender, msg.value, block.timestamp);
  }

  /**
   * Cancels a bid and refunds the bid price to the last bidder.
   * @dev Reverts if market is not active.
   * @dev Reverts if auction is not English.
   * @dev Reverts if auction is already sold i.e. the NFT is already transferred to the last bidder.
   * @dev Reverts if auction is already cancelled.
   * @dev Reverts if caller is not the last bidder.
   * @dev Emits a CancelBid event.
   * @param _order The order identifier, referencing the auction to cancel bid.
   */
  function cancelBid(bytes32 _order) public {
    require(marketIsActive == true, "Market must be active");

    Order storage o = orderInfo[_order];
    uint256 lastBidPrice = o.lastBidPrice;
    address lastBidder = o.lastBidder;

    require(o.orderType == 2, "only for English Auction");
    require(o.isSold == false, "Already sold");
    require(o.isCancelled == false, "Canceled order");
    require(o.lastBidder == msg.sender, "Must be last bidder");

    o.lastBidder = address(0);
    o.lastBidPrice = 0;

    if (lastBidPrice != 0) {
      payable(lastBidder).transfer(lastBidPrice);
    }

    emit CancelBid(o.tokenId, _order, msg.sender, block.timestamp);
  }

  /**
   * Buys an NFT for Fixed Price or Dutch auction.
   * @dev Reverts if market is not active.
   * @dev Reverts if auction is English. 
   * @dev Reverts if auction is already sold i.e. the NFT is already transferred to the last bidder.
   * @dev Reverts if auction is already cancelled.
   * @dev Reverts if the auction has an expiration that has ended.
   * @dev Reverts if the sent BCH is less than the current auction price.
   * @dev Emits a Claim event.
   * @param _order The order identifier, referencing the auction to perform buy.
   */
  function buyItNow(bytes32 _order) payable external {
    require(marketIsActive == true, "Market must be active");

    Order storage o = orderInfo[_order];
    uint256 endBlock = o.endBlock;
    require(o.isCancelled == false, "Canceled order");
    require(o.orderType < 2, "It's a English Auction");
    require(o.isSold == false, "Already sold");

    if (endBlock != 0) {
      // if auction has expiration, require that auction is not expired
      require(endBlock > block.number, "Auction has ended");
    }

    uint256 currentPrice = getCurrentPrice(_order);
    require(msg.value >= currentPrice, "Price error");

    o.isSold = true;    //reentrancy proof

    uint256 fee = currentPrice * feePercent / 10000;
    payable(o.seller).transfer(currentPrice - fee);
    payable(feeAddress).transfer(fee);
    if (msg.value > currentPrice) {
      payable(msg.sender).transfer(msg.value - currentPrice);
    }

    nftContract.safeTransferFrom(address(this), msg.sender, o.tokenId);

    emit Claim(o.tokenId, _order, o.seller, msg.sender, currentPrice, block.timestamp);
  }

  /**
   * Claims an NFT listed on an English auction. This transfers the ownership of NFT to the last bidder
   * and sends bid price to seller.
   * @dev Can only be called by the seller if auction is set to have no expiration.
   * @dev Can be called by the seller or last bidder if auction has an expiration and has ended.
   * @dev Reverts if market is not active.
   * @dev Reverts if auction is already sold (or claimed).
   * @dev Reverts if auction is already cancelled.
   * @dev Reverts if caller is not seller.
   * @dev Reverts if auction has not ended (if auction has expiration).
   * @dev Emits a Claim event.
   * @param _order The order identifier.
   */
  function claim(bytes32 _order) public {
    require(marketIsActive == true, "Market must be active");

    Order storage o = orderInfo[_order];
    address seller = o.seller;
    address lastBidder = o.lastBidder;
    require(o.isSold == false, "Already sold");
    require(o.isCancelled == false, "Already cancelled");
    require(o.orderType == 2, "English Auction only");

    if (o.endBlock == 0) {
      // if auction has no expiration, require that caller is the seller
      require(seller == msg.sender, "Access denied");
    } else {
      // if auction has expiration, require that auction has ended and caller is either
      // the seller or the last bidder
      require(seller == msg.sender || lastBidder == msg.sender, "Access denied");
      require(block.number > o.endBlock, "Auction has not ended");
    }

    uint256 tokenId = o.tokenId;
    uint256 lastBidPrice = o.lastBidPrice;

    uint256 fee = lastBidPrice * feePercent / 10000;

    o.isSold = true;

    payable(seller).transfer(lastBidPrice - fee);
    payable(feeAddress).transfer(fee);
    nftContract.safeTransferFrom(address(this), lastBidder, tokenId);

    emit Claim(tokenId, _order, seller, lastBidder, lastBidPrice, block.timestamp);
  }

  /**
   * Claims multiple claimable NFTs.
   * This transfers the ownership of NFTs to the caller and sends bid prices to sellers.
   * @dev Reverts if market is not active.
   * @dev Reverts if _ids array is not empty.
   * @param _ids The order identifiers.
   */
  function bulkClaim(bytes32[] memory _ids) public {
    require(marketIsActive == true, "Market must be active");
    require(_ids.length > 0, "At least 1 ID must be supplied");
    for(uint i=0; i < _ids.length; i++) {
      claim(_ids[i]);
    }
  }

  /**
   * Cancels an auction.
   * @dev Refunds the last bidder if auction is English.
   * @dev Reverts if market is not active.
   * @dev Reverts if caller is not the original owner of the NFT.
   * @dev Reverts if auction is already sold.
   * @dev Reverts if auction is already cancelled.
   * @dev Emits a CancelOrder event.
   * @param _order The order identifier.
   */
  function cancelOrder(bytes32 _order) public {
    require(marketIsActive == true, "Market must be active");

    Order storage o = orderInfo[_order];
    require(o.seller == msg.sender, "Access denied");
    require(o.isSold == false, "Already sold");
    require(o.isCancelled == false, "Already cancelled");

    // if order is english auction, return last bidder's bid
    if (o.orderType == 2 && o.lastBidPrice != 0) {
      uint256 lastBidPrice = o.lastBidPrice;
      address lastBidder = o.lastBidder;
      
      o.lastBidder = address(0);
      o.lastBidPrice = 0;

      payable(lastBidder).transfer(lastBidPrice);
    }

    o.isCancelled = true;

    nftContract.safeTransferFrom(address(this), msg.sender, o.tokenId);
    emit CancelOrder(o.tokenId, _order, msg.sender, block.timestamp);
  }

  /**
   * Cancels multiple auctions.
   * @dev Reverts if market is not active.
   * @dev Reverts if _ids is empty.
   * @param _ids The order identifiers of auctions to cancel.
   */
  function bulkCancel(bytes32[] memory _ids) public {
    require(marketIsActive == true, "Market must be active");
    
    require(_ids.length > 0, "At least 1 ID must be supplied");
    for(uint i=0; i < _ids.length; i++) {
      cancelOrder(_ids[i]);
    }
  }

  /**
   * Sets the address where marketplace fees are sent.
   * @dev Reverts if caller is not the contract owner.
   * @param _feeAddress The value set as the fee address.
   */
  function setFeeAddress(address _feeAddress) external onlyOwner {
    feeAddress = _feeAddress;
  }

  /**
   * Updates the fee percent.
   * @dev Reverts if caller is not the contract owner.
   * @param _percent The value set as the fee percent.
   */
  function updateFeePercent(uint16 _percent) external onlyOwner {
    require(_percent <= 10000, "Input value is more than 100%");
    feePercent = _percent;
  }
}