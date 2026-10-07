// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;
import {
    ERC4626
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SavingsVault is ERC4626 {
    uint256 public lent;

    constructor(IERC20 asset) ERC4626(asset) ERC20("Spark Savings", "sVault") {}

    function lend(uint256 assets) external {
        lent += assets;
        IERC20(asset()).transfer(msg.sender, assets);
    }

    function repay(uint256 assets) external {
        lent -= assets;
        IERC20(asset()).transferFrom(msg.sender, address(this), assets);
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + lent;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _liquidity());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return
            Math.min(
                super.maxRedeem(owner),
                _convertToShares(_liquidity(), Math.Rounding.Floor)
            );
    }

    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256 assets) {
        assets = super.previewRedeem(shares);
        require(_liquidity() >= assets, "insufficient-liquidity");
    }

    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256) {
        require(_liquidity() >= assets, "insufficient-liquidity");
        return super.previewWithdraw(assets);
    }

    function _liquidity() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}
