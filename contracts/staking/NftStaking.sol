// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IRewardsToken.sol";

/**
 * @title NFT Staking
 * NFT staking with ERC20 rewards.
 */
contract NftStaking is ERC721Holder, Ownable {

    event Staked(address owner, uint256 tokenId);
    event Unstaked(address owner, uint256 tokenId);
    event Claimed(address owner, uint256 claimed);
    event RewardsPerBlockUpdated(uint256 rewardsPerBlock);
    event UpdatedStakingState(bool enabled);
    event WeightsUpdated(uint256[] tokenIds, uint256[] weights);

    struct Nft {
        uint256 weight;
        address owner;
    }    

    struct Staker {
        address addr;
        uint256 stakerIndex;    // index of staker in {stakers}
        uint256 weight;
        uint256 balance;
        uint256 claimed;
    }

    // tokenId => index
    mapping(uint256 => uint256) public stakedTokenIndex;

    // owner => tokenIds 
    mapping(address => uint256[]) public ownerStakedTokens;

    // tokenId => Nft info
    mapping(uint256 => Nft) public tokenInfo;

    // owner => Staker
    mapping(address => Staker) public stakerInfo; 

    address[] public stakers;
    uint256 public totalStakedWeights;
    uint256 public rewardsPerBlock;
    uint256 public lastAccountedBlock;

    bool public enabled = false;
    bool public permanentDisable = false;

    IERC721 public nft;
    IRewardsToken public rewardsToken;

    modifier stakingDisabled {
        require(!enabled, "staking is enabled");
        _;
    }

    modifier stakingEnabled {
        require(enabled, "staking is disabled");
        _;
    }

    /**
    * @dev Sets the value for {nft}, {rewardsToken} and initializes {lastAccountedBlock}.
    */
    constructor(address _nft, address _rewardsToken) {
        nft = IERC721(_nft);
        rewardsToken = IRewardsToken(_rewardsToken);
        lastAccountedBlock = block.number;
    }

    /**
    * @dev Returns the number of NFTs staked by {_staker}.
    */
    function stakerNftBalance(address _staker) public view returns (uint256) {
        return ownerStakedTokens[_staker].length;
    }

    /**
    * @dev Returns the list of staker's staked token IDs.
    */
    function stakerTokenIds(address _staker) external view returns (uint256[] memory tokenIds) {
        return ownerStakedTokens[_staker];
    }

    /**
    * @dev Returns the number of staking participants.
    */
    function stakersLength() external view returns(uint256) {
        return stakers.length;
    }

    /**
    * @dev Sets the token weights.
    *
    * emits a {WeightsUpdated} event.
    *
    * Requirements:
    * - `_tokenIds` and `_weights` length must match.
    * - limited to setting only 100 token weights at a time.
    */
    function setWeights(uint256[] calldata _tokenIds, uint256[] calldata _weights) external onlyOwner stakingDisabled {
        require(_tokenIds.length == _weights.length, "token and weights length mismatch");
        require(_weights.length <= 100, "can only set 100 token weights at a time");
    
        for (uint256 index; index < _tokenIds.length; index++) {
            tokenInfo[_tokenIds[index]].weight = _weights[index];
        }

        emit WeightsUpdated(_tokenIds, _weights);
    }

    /**
    * @dev Stakes {_tokenId}.
    * Emits a {Staked} event indicating the staker and staked token.
    */
    function _stake(uint256 _tokenId) internal stakingEnabled {
        address _staker = msg.sender;
        require(nft.ownerOf(_tokenId) != address(this), "already staked");
        Staker storage staker = stakerInfo[_staker];

        // inits Staker info if user has no staked tokens
        if (staker.addr == address(0)) {
            staker.addr = _staker;
            staker.stakerIndex = stakers.length;
            stakers.push(staker.addr);
        }

        // stores the index of the staked token & adds _tokenId in list of owner's
        // staked tokens
        stakedTokenIndex[_tokenId] = ownerStakedTokens[_staker].length;
        ownerStakedTokens[_staker].push(_tokenId);

        // increments the staked weight of current staker & 
        // the totalStakedWeights of all stakers.
        uint256 weight = tokenInfo[_tokenId].weight;
        staker.weight += weight;
        totalStakedWeights += weight;
        
        // saves the owner of token
        tokenInfo[_tokenId].owner = staker.addr;

        nft.safeTransferFrom(_staker, address(this), _tokenId);

        emit Staked(_staker, _tokenId);
    }

    function batchStake(uint256[] calldata _tokenIds) external stakingEnabled {
        require(_tokenIds.length <= 100, "stake max of 100 tokens at a time");
        
        // commit rewards before making updates that affect the
        // rewards computation
        computeRewards();

        for(uint index = 0; index < _tokenIds.length; index++) {
            _stake(_tokenIds[index]);
        }
    }

    /**
    * @dev Unstakes {_tokenId}.
    *
    * Claims the rewards if {_claimRewards} is true.
    * Emits an {Unstaked} event indicating the unstaked token and who unstaked.
    *
    * Requirement:
    * - `_staker` or caller of function must be the owner of the token to unstake.
    */
    function _unstake(uint256 _tokenId) internal stakingEnabled {
        address _staker = msg.sender;
        require(tokenInfo[_tokenId].owner == _staker, "not the owner");

        // removes _tokenId from the list of staked tokens 
        // owned by _staker.
        _popToken(_staker, _tokenId);

        // removes the owner of _tokenId
        delete tokenInfo[_tokenId].owner;

        // decrements the staker's weight & the global totalStakedWeights
        uint256 weight = tokenInfo[_tokenId].weight;
        stakerInfo[_staker].weight -= weight;
        totalStakedWeights -= weight;

        // if staker has no staked NFTs anymore, remove this staker from
        // the list of staking participants and reset its stakerInfo
        if (ownerStakedTokens[_staker].length == 0) {
            stakerInfo[_staker].addr = address(0);
            _popStaker(_staker);
        } 

        nft.safeTransferFrom(address(this), _staker, _tokenId);
        
        emit Unstaked(_staker, _tokenId);
    }

    function batchUnstake(uint256[] calldata _tokenIds, bool _claimRewards) external stakingEnabled {
        require(_tokenIds.length <= 100, "unstake max of 100 tokens at a time");
        
        // commit rewards before making updates that affect the
        // rewards computation
        computeRewards();

        // claim rewards if _claimRewards = true
        if (_claimRewards) {
            claimRewards(msg.sender);
        }

        for(uint index = 0; index < _tokenIds.length; index++) {
            _unstake(_tokenIds[index]);
        }
    }


    /**
    * @dev Claims the reward for {_staker}.
    *
    * Emits a {Claimed} event.
    */
    function claimRewards(address _staker) public stakingEnabled {

        // commit rewards before making updates that affect the
        // rewards computation
        computeRewards();
        
        // update staker's balance and claimed amount
        Staker storage staker = stakerInfo[_staker];
        uint256 amount = staker.balance;
        staker.balance = 0;
        staker.claimed += amount;
        
        // mint {amount} reward tokens to this staker
        rewardsToken.mint(_staker, amount);

        emit Claimed(_staker, amount);
    }

    /**
    * @dev Returns the projected rewards of {_staker}.
    */
    function checkRewards(address _staker) 
        external 
        view 
        returns (uint256 earned, uint256 elapsedBlocks) {

        uint256 projectedRewards;
        uint256 weight;
        uint256 rewardsPerBlock_ = rewardsPerBlock;
        elapsedBlocks = getElapsedBlocks();

        if (totalStakedWeights > 0) {
            weight = stakerInfo[_staker].weight;
            projectedRewards = weight * elapsedBlocks * (rewardsPerBlock_ / totalStakedWeights);
        }
        earned += stakerInfo[_staker].balance + projectedRewards;
    }

    /**
    * @dev Commits the rewards of all staking participants.
    *
    * Invoked when calling {stake}, {unstake}, {claimRewards}, when updating 
    * {rewardsPerBlock} through {setRewardsPerBlock} method, and disabling staking
    * through {setStakingState} method.
    *
    * Can also be invoked externally.
    */
    function computeRewards() public stakingEnabled {
        uint256 currentBlock = block.number;
        if (totalStakedWeights > 0) {
            uint256 elapsedBlocks = getElapsedBlocks();
            uint256 rewardsPerBlock_ = rewardsPerBlock;
            uint256 rewardPerNft = elapsedBlocks * (rewardsPerBlock_ / totalStakedWeights);

            // updates the balance of each staking participant
            for (uint256 i = 0; i < stakers.length;) {
                Staker storage staker = stakerInfo[stakers[i]];
                staker.balance +=  staker.weight * rewardPerNft;
                unchecked { i++; }
            }
        }
        lastAccountedBlock = currentBlock;
    }

    /**
    * @dev Updates the rewards emitted per block: {rewardsPerBlock}.
    * 
    * Can only be called by contract owner.
    * Commits the rewards before updating {rewardsPerBlock}.
    *
    * emits a {RewardsPerBlockUpdated} indicating the new value.
    */
    function setRewardsPerBlock(uint256 _rewardsPerBlock) external onlyOwner {

        // Commit rewards if staking is currently enabled
        if (enabled) {
            computeRewards();
        }
        
        rewardsPerBlock = _rewardsPerBlock;
        emit RewardsPerBlockUpdated(_rewardsPerBlock);
    }

    /**
    * @dev Sets the staking status to: enabled, disabled or permanently disabled.
    *
    * Allows switching from status enabled to disabled and vice versa. 
    *
    * Warning: Permanently disabling staking status by setting parameters {_enabled} = false 
    * and {_permanent} = true cannot be undone. 
    * 
    * Requirement:
    * - `_enabled` and `_permanent` cannot be both true.
    */
    function setStakingState(bool _enabled, bool _permanent) external onlyOwner {

        // Revert if both _enabled and _permanent is true.
        // Permanently enabling staking is not allowed.
        if (_enabled && _permanent) {
            revert("cannot permanently enable");
        } 

        // Reverts if staking is permanently disabled.
        require(!permanentDisable, "contract permanently disabled");

        // Commit rewards before disabling staking
        if (!_enabled) {
            computeRewards();
        }

        enabled = _enabled;
        permanentDisable = _permanent;
        emit UpdatedStakingState(_enabled);
    }

    /**
    * @dev Returns the number of blocks elapsed since {lastAccountedBlock}.
    * Returns 0 if staking is not enabled.
    * @return elapsedBlocks The number of blocks elapsed from lastAccountedBlock.
    */
    function getElapsedBlocks() public view returns(uint256 elapsedBlocks) {
        if (enabled) {
            elapsedBlocks = block.number - lastAccountedBlock;
        } 
    }

    /**
    * @dev Removes {_tokenId} from the list of staked tokens owned by {_owner}.
    *
    * Invoked whenever a token is unstaked. 
    * This moves tokens around, making the list unordered.
    *
    * @param _owner The owner of the token to remove.
    * @param _tokenId The identifier of token to remove from the list.
    */
    function _popToken(address _owner, uint256 _tokenId) internal {
        uint256[] storage stakedTokens = ownerStakedTokens[_owner];
        uint256 tokenLen = stakedTokens.length;
        // The current index of token to remove
        uint256 index = stakedTokenIndex[_tokenId];
        // Replace the element at `index` with the value of the last element
        stakedTokens[index] = stakedTokens[tokenLen - 1];
        // Update the index of new element at `index` (which is now equal to the value 
        // of the last element) with `index`.
        stakedTokenIndex[stakedTokens[index]] = index;
        // Remove the last element.
        stakedTokens.pop();
    }

    /**
    * @dev Removes {_staker} from the list of staking participants.
    * 
    * Invoked when a staker unstakes all their staked tokens. This reduces the number
    * of loops in {computeRewards} by removing the participants that do not have 
    * anything staked anymore.
    *
    * @param _staker The staker address to remove from the list.
    */
    function _popStaker(address _staker) internal {
        uint256 stakerIndex = stakerInfo[_staker].stakerIndex;
        stakers[stakerIndex] = stakers[stakers.length - 1];
        stakerInfo[stakers[stakerIndex]].stakerIndex = stakerIndex;
        stakers.pop();
    }
    
    /**
    * @dev Emergency function only to return tokens to their owners.
    * 
    * Requirement:
    * - staking must be permanently disabled.
    *
    * @param _tokenIds The list of tokens to transfer.
    */
    function emergencyReturnTokens(uint256[] calldata _tokenIds) external stakingDisabled {
        require(permanentDisable, "contract must be permanently disabled");
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            nft.safeTransferFrom(address(this), tokenInfo[tokenId].owner, tokenId);
        }
    }
}