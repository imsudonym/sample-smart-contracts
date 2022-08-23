// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title Nft contract
 * @dev Extends ERC721 Non-Fungible Token Standard basic implementation
 */
contract SlimeNft is ERC721Enumerable, Ownable {

    string internal nftName = "Slime";
    string internal nftSymbol = "SLIME";
    string baseURI = "";

    bool public saleIsActive = false;
    uint public constant maxPurchase = 10;
    uint256 public constant nftPrice = 10000000000000; // 0.000001 BCH
    uint256 public constant MAX_SUPPLY = 10000;
    uint256 internal nonce = 0;
    uint256[MAX_SUPPLY] internal indices;

    string public constant PROVENANCE_HASH = "";

    event Mint(uint256 indexed index, address indexed minter);

    constructor() ERC721(nftName, nftSymbol) {}

    function withdraw() public onlyOwner {
        uint balance = address(this).balance;
        payable(msg.sender).transfer(balance);
    }

    function _baseURI() override internal view virtual returns (string memory) {
        return baseURI;
    }

    /*
    * Pause sale if active, make active if paused
    */
    function flipSaleState() public onlyOwner {
        saleIsActive = !saleIsActive;
    }

    /**
    * Mint NFTs
    */
    function mint(uint numberOfTokens) public payable {
        require(saleIsActive, "Sale must be active to mint tokens");
        require(numberOfTokens <= maxPurchase, "Can only mint 10 tokens at a time");
        require(totalSupply().add(numberOfTokens) <= MAX_SUPPLY, "Purchase will exceed max supply");
        require(nftPrice.mul(numberOfTokens) <= msg.value, "Ether value sent is not correct");
        
        for(uint i = 0; i < numberOfTokens; i++) {
            uint mintIndex = _randomIndex();
            if (totalSupply() < MAX_SUPPLY) {
                _safeMint(msg.sender, mintIndex);
            }
            emit Mint(mintIndex, msg.sender);
        }
    }

    function _randomIndex() internal returns (uint256) {
        uint256 totalSize = MAX_SUPPLY - totalSupply();
        uint256 index = uint256(
            keccak256(
                abi.encodePacked(
                    nonce,
                    msg.sender,
                    block.difficulty,
                    block.timestamp
                )
            )
        ) % totalSize;
        uint256 value = 0;
        if (indices[index] != 0) {
            value = indices[index];
        } else {
            value = index;
        }

        // Move last value to selected position
        if (indices[totalSize - 1] == 0) {
            // Array position not initialized, so use position
            indices[index] = totalSize - 1;
        } else {
            // Array position holds a value so use that
            indices[index] = indices[totalSize - 1];
        }
        nonce++;
        // Don't allow a zero index, start counting at 1
        return value.add(1);
    }
}
