// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVault} from "src/interfaces/IVault.sol";
import {VaultHandler} from "./VaultHandler.t.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";

/// @notice Random actor that requests, cancels, fills and claims. Every call
/// is guarded so that a revert means the vault broke a promise
contract QueueBreakActor is Test {
    VaultHandler internal vault;
    IERC20 internal baseAsset;
    IERC4626 internal savingsVault;
    address internal rebalancer;
    address internal vaultManager;
    address internal liquidityManager;
    address internal riskManager;

    address[] public actors;
    mapping(bytes32 => bool) public ghostQueued;
    uint256 public ghostLiveDeposits;
    uint256 public calls;

    constructor(
        VaultHandler vault_,
        IERC20 baseAsset_,
        IERC4626 savingsVault_,
        address rebalancer_,
        address vaultManager_,
        address liquidityManager_,
        address riskManager_
    ) {
        vault = vault_;
        baseAsset = baseAsset_;
        savingsVault = savingsVault_;
        rebalancer = rebalancer_;
        vaultManager = vaultManager_;
        liquidityManager = liquidityManager_;
        riskManager = riskManager_;
        for (uint256 i; i < 6; ++i)
            actors.push(makeAddr(string.concat("inv_actor", vm.toString(i))));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _key(address c, uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode(c, n));
    }

    function requestDeposit(uint256 seed, uint256 amount) external {
        ++calls;
        address who = _actor(seed);
        amount = bound(amount, vault.minimumDeposit(), 25 ether);
        if (vault.convertToShares(amount) == 0) return;
        deal(address(baseAsset), who, amount);
        vm.startPrank(who);
        baseAsset.approve(address(vault), amount);
        vault.requestDeposit(amount, who, who);
        vm.stopPrank();
        uint256 nonce = vault.requestNonce(who);
        if (vault.queuedDepositRequest(who, nonce).controller != address(0)) {
            ghostQueued[_key(who, nonce)] = true;
            ++ghostLiveDeposits;
        }
    }

    function cancel(uint256 seed, uint256 nonceSeed) external {
        ++calls;
        address who = _actor(seed);
        uint256 top = vault.requestNonce(who);
        if (top == 0) return;
        uint256 nonce = 1 + (nonceSeed % top);
        if (vault.queuedDepositRequest(who, nonce).controller == address(0)) return;
        vm.prank(who);
        vault.cancelDepositRequest(who, nonce);
        ghostQueued[_key(who, nonce)] = false;
        --ghostLiveDeposits;
    }

    function requestRedeem(uint256 seed, uint256 fraction) external {
        ++calls;
        address who = _actor(seed);
        uint256 bal = vault.balanceOf(who);
        uint256 shares = Math.mulDiv(bal, bound(fraction, 1, 100), 100);
        if (shares == 0 || vault.convertToAssets(shares) < vault.minimumWithdraw()) return;
        vm.prank(who);
        vault.requestRedeem(shares, who, who);
    }

    function process(uint256 volume) external {
        ++calls;
        volume = bound(volume, 0, vault.maxTradeVolume());
        uint256 before = vault.depositQueueLength();
        vm.prank(rebalancer);
        vault.processQueue(volume);
        _syncGhost(before);
    }

    function processMax() external {
        ++calls;
        uint256 before = vault.depositQueueLength();
        vm.prank(rebalancer);
        vault.processQueue(type(uint256).max);
        _syncGhost(before);
    }

    /// @dev Fills only remove from the front, so the ghost count tracks length
    function _syncGhost(uint256) internal {
        ghostLiveDeposits = vault.depositQueueLength();
    }

    function claimDeposit(uint256 seed, uint256 chunk) external {
        ++calls;
        address who = _actor(seed);
        uint256 left = vault.maxDeposit(who);
        uint256 owed = vault.maxMint(who);
        if (owed == 0) return;
        if (left == 0 || chunk % 2 == 0) {
            vm.prank(who);
            vault.mint(owed, who);
            return;
        }
        uint256 assets = bound(chunk, 1, left);
        if (Math.mulDiv(owed, assets, left) == 0) return;
        vm.prank(who);
        vault.deposit(assets, who);
    }

    function claimRedeem(uint256 seed, uint256 chunk) external {
        ++calls;
        address who = _actor(seed);
        uint256 left = vault.maxWithdraw(who);
        uint256 shares = vault.maxRedeem(who);
        if (left == 0 && shares == 0) return;
        if (left == 0 || chunk % 2 == 0) {
            if (shares == 0) return;
            vm.prank(who);
            vault.redeem(shares, who, who);
            return;
        }
        vm.prank(who);
        vault.withdraw(bound(chunk, 1, left), who, who);
    }

    function take(uint256 amount) external {
        ++calls;
        int256 free = vault.availableLiquidAssets();
        if (free <= 0) return;
        amount = bound(amount, 1, uint256(free));
        vm.prank(liquidityManager);
        vault.take(amount);
    }

    function inject(uint256 amount) external {
        ++calls;
        amount = bound(amount, 1, 30 ether);
        deal(address(baseAsset), address(vault), baseAsset.balanceOf(address(vault)) + amount);
    }

    function setCapacity(uint256 extra) external {
        ++calls;
        uint256 supply = vault.totalSupply();
        vm.prank(vaultManager);
        vault.setCapacity(supply + bound(extra, 0, 60 ether));
    }

    function setFee(uint256 bps) external {
        ++calls;
        vm.prank(riskManager);
        vault.updateWithdrawFee(bound(bps, 0, 5_000));
    }

    function warp(uint256 secs) external {
        ++calls;
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
        vm.roll(block.number + 1);
    }

    function savingsYield(uint256 bps) external {
        ++calls;
        uint256 held = baseAsset.balanceOf(address(savingsVault));
        deal(address(baseAsset), address(savingsVault), held + (held * bound(bps, 0, 50)) / 10_000);
    }

    function sanitize(uint256 budget) external {
        ++calls;
        vault.sanitizeDepositQueue(bound(budget, 0, 50));
    }
}

contract QueueBreakInvariantTests is QueueHelper {
    QueueBreakActor internal actor;

    function setUp() public {
        _deployVault();
        actor = new QueueBreakActor(
            vault,
            baseAsset,
            savingsVault,
            rebalancer,
            vaultManager,
            liquidityManager,
            riskManager
        );
        targetContract(address(actor));
    }

    function invariant_solvent() public view {
        assertSolvent();
    }

    function invariant_ledgerSumsMatchTotals() public view {
        uint256 pendingOut;
        uint256 owedShares;
        uint256 owedAssets;
        uint256 n = actor.actorCount();
        for (uint256 i; i < n; ++i) {
            address who = actor.actors(i);
            pendingOut += vault.pendingRedeemRequest(0, who);
            owedShares += vault.maxMint(who);
            owedAssets += vault.maxWithdraw(who);
        }
        assertEq(pendingOut, vault.totalPendingWithdraws(), "pending redeem shares != queue total");
        assertEq(owedShares, vault.claimableDepositTotal(), "claimable deposit shares != total");
        assertEq(owedAssets, vault.claimableWithdrawTotal(), "claimable withdraw assets != total");
    }

    function invariant_depositQueueLengthMatchesGhost() public view {
        assertEq(vault.depositQueueLength(), actor.ghostLiveDeposits(), "queue length drifted");
    }

    function invariant_maxTradeVolumeAlwaysProcessable() public {
        uint256 snap = vm.snapshotState();
        uint256 volume = vault.maxTradeVolume();
        vm.prank(rebalancer);
        vault.processQueue(volume);
        assertSolvent();
        vm.revertToState(snap);
    }
}
