// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Constants} from "../helpers/Constants.sol";

contract MockIntentOracle {
    uint256 public price = Constants.ORACLE_PRICE_SCALE; // 1:1 price

    function setPrice(uint256 _price) external {
        price = _price;
    }
}
