// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TokenA is ERC20("TokenA", "TKA"), Ownable {

    address authorized;
    
    modifier onlyAuthorized {
        require(msg.sender == authorized || msg.sender == owner(), "not authorized");
        _;
    }

    function setAuthorized(address _account) external onlyOwner {
        authorized = _account;
    }

    function mint(address _account, uint256 _amount) external onlyAuthorized {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external onlyAuthorized {
        _burn(_account, _amount);
    }
}