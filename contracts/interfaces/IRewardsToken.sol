// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

interface IRewardsToken {
  function mint(address account, uint256 amount) external;
  function burn(address account, uint256 amount) external;
  function transfer(address recipient, uint256 amount) external returns(bool);
  function transferFrom(address from, address to, uint256 amount) external returns(bool);
  function balanceOf(address account) external returns(uint256);
}