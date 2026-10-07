// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {QueueHelper} from "./utils/QueueHelper.sol";
import {SavingsVault} from "./mocks/SavingsVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Busy-queue stress: 48 users over 40 simulated days. Hundreds of
/// deposit requests and dozens of redeems, random cancels, random fill sizes,
/// Arkis taking and returning liquidity, a 10% spUSDC sleeve that is moved in
/// and out, and random spUSDC liquidity crunches. Half the users claim every
/// day, the other half never claim until the very end. After every day the
/// accounting is checked end to end; at the end every user is checked to have
/// received what they are owed.
contract BusyQueueStressTests is QueueHelper {
    struct Dep {
        address who;
        uint256 nonce;
        uint256 day;
        bool closed;
    }

    uint256 internal constant DAYS = 40;
    uint256 internal constant HOLDERS = 16;
    uint256 internal constant DEPOSITORS = 32;
    uint256 internal constant FEE_BPS = 25;
    uint256 internal constant DUST_PER_USER = 1e9;

    address internal borrower = makeAddr("spusdc_borrower");
    address[] internal holders;
    address[] internal depositors;
    address[] internal everyone;
    mapping(address => bool) internal slow;

    Dep[] internal deps;
    mapping(address => uint256) internal requested;
    mapping(address => uint256) internal refunded;
    mapping(address => uint256) internal creditedAssets;
    mapping(address => uint256) internal redeemValueAtRequest;
    mapping(address => uint256) internal redeemSharesRequested;
    mapping(address => uint256) internal received;

    uint256 internal seed;
    bool internal crunched;
    uint256 internal crunchEnds;

    uint256 internal statCancels;
    uint256 internal statRedeems;
    uint256 internal statFills;
    uint256 internal statCrunchDays;
    uint256 internal statMaxDepQueue;
    uint256 internal statMaxWdQueue;
    uint256 internal statMaxFillGas;
    uint256 internal statMaxWait;
    uint256 internal statWaitSum;
    uint256 internal statClosed;

    function setUp() public {
        _deployVault();
        for (uint256 i; i < HOLDERS; ++i) {
            address a = makeAddr(string.concat("holder", vm.toString(i)));
            holders.push(a);
            everyone.push(a);
            slow[a] = i % 2 == 1;
        }
        for (uint256 i; i < DEPOSITORS; ++i) {
            address a = makeAddr(string.concat("depositor", vm.toString(i)));
            depositors.push(a);
            everyone.push(a);
            slow[a] = i % 2 == 1;
        }
    }

    function _rand(string memory tag, uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag, i, block.timestamp)));
    }

    function _sv() internal view returns (SavingsVault) {
        return SavingsVault(address(savingsVault));
    }

    function _freeSleeveShares() internal view returns (uint256) {
        return savingsVault.balanceOf(address(vault)) - vault.totalPendingDeposits();
    }

    // ------------------------------------------------------------------ setup

    function _bootstrap() internal {
        vm.prank(riskManager);
        vault.updateWithdrawFee(FEE_BPS);
        for (uint256 i; i < HOLDERS; ++i) _depositAndClaim(holders[i], 5 ether);
        vm.prank(rebalancer);
        vault.depositToSavings(8 ether);
        _drainLiquidity();
    }

    // ---------------------------------------------------------------- actions

    function _newDeposits(uint256 day) internal {
        uint256 n = 6 + (_rand("nd", day) % 5);
        for (uint256 i; i < n; ++i) {
            address who = depositors[_rand("dw", day * 100 + i) % DEPOSITORS];
            uint256 amount = bound(_rand("da", day * 100 + i), 0.05 ether, 3 ether);
            _requestDeposit(who, amount);
            requested[who] += amount;
            uint256 nonce = vault.requestNonce(who);
            if (vault.queuedDepositRequest(who, nonce).controller != address(0))
                deps.push(Dep(who, nonce, day, false));
        }
    }

    function _newRedeems(uint256 day) internal {
        uint256 n = 3 + (_rand("nr", day) % 4);
        for (uint256 i; i < n; ++i) {
            address who = holders[_rand("rw", day * 100 + i) % HOLDERS];
            uint256 bal = vault.balanceOf(who);
            uint256 shares = Math.mulDiv(bal, bound(_rand("rf", day * 100 + i), 10, 60), 100);
            if (shares == 0 || vault.convertToAssets(shares) < MINIMUM_WITHDRAW) continue;
            redeemValueAtRequest[who] += vault.convertToAssets(shares);
            redeemSharesRequested[who] += shares;
            _requestRedeem(who, shares);
            ++statRedeems;
        }
    }

    function _randomCancels() internal {
        for (uint256 i; i < deps.length; ++i) {
            Dep storage d = deps[i];
            if (d.closed || slow[d.who]) continue;
            if (uint256(keccak256(abi.encode(seed, "cx", i, block.timestamp))) % 10 != 0) continue;
            if (vault.queuedDepositRequest(d.who, d.nonce).controller == address(0)) continue;
            if (crunched) {
                // cancel redeems from spUSDC; skip if it cannot pay
                uint256 amt = vault.queuedDepositRequest(d.who, d.nonce).amount;
                if (savingsVault.maxRedeem(address(vault)) < amt) continue;
            }
            uint256 before = baseAsset.balanceOf(d.who);
            vm.prank(d.who);
            vault.cancelDepositRequest(d.who, d.nonce);
            refunded[d.who] += baseAsset.balanceOf(d.who) - before;
            ++statCancels;
        }
    }

    function _liquidityWeather(uint256 day) internal {
        // spUSDC crunches
        if (!crunched && _rand("cr", day) % 6 == 0) {
            uint256 cash = baseAsset.balanceOf(address(savingsVault));
            uint256 leave = bound(_rand("cl", day), 0, 2 ether);
            vm.prank(borrower);
            _sv().lend(cash > leave ? cash - leave : 0);
            crunched = true;
            crunchEnds = day + 2 + (_rand("ce", day) % 3);
        } else if (crunched && day >= crunchEnds) {
            uint256 lent = _sv().lent();
            deal(address(baseAsset), borrower, lent);
            vm.startPrank(borrower);
            baseAsset.approve(address(savingsVault), lent);
            _sv().repay(lent);
            vm.stopPrank();
            crunched = false;
        }
        if (crunched) ++statCrunchDays;

        // spUSDC yield, about 1bp a day
        uint256 held = baseAsset.balanceOf(address(savingsVault));
        deal(address(baseAsset), address(savingsVault), held + held / 10_000);

        // Arkis returns some USDC
        if (_rand("ar", day) % 3 == 0) {
            uint256 back = bound(_rand("ab", day), 0, 3 ether);
            deal(address(baseAsset), address(vault), baseAsset.balanceOf(address(vault)) + back);
        }
        // Arkis takes part of the idle USDC
        int256 free = vault.availableLiquidAssets();
        if (free > 0 && _rand("at", day) % 3 != 0) {
            vm.prank(liquidityManager);
            vault.take((uint256(free) * 9) / 10);
        }
        // sleeve rebalancing
        uint256 sleeve = _freeSleeveShares();
        uint256 redeemable = savingsVault.maxRedeem(address(vault));
        uint256 unwind = Math.min(sleeve, redeemable);
        if (unwind > 0 && _rand("su", day) % 5 < 2) {
            uint256 amt = (unwind * bound(_rand("sa", day), 1, 100)) / 100;
            if (amt > 0) {
                vm.prank(rebalancer);
                vault.withdrawFromSavings(amt);
            }
        } else {
            free = vault.availableLiquidAssets();
            if (free > 1 ether && _rand("sd", day) % 3 == 0) {
                vm.prank(rebalancer);
                vault.depositToSavings(uint256(free) / 2);
            }
        }
        // capacity wobbles
        uint256 supply = vault.totalSupply();
        vm.prank(vaultManager);
        vault.setCapacity(supply + bound(_rand("cp", day), 0, 15 ether));
    }

    function _fills(uint256 day) internal {
        uint256 n = 1 + (_rand("fn", day) % 3);
        for (uint256 i; i < n; ++i) {
            uint256 max = vault.maxTradeVolume();
            uint256 volume = (i == n - 1 && _rand("fm", day) % 2 == 0)
                ? type(uint256).max
                : bound(_rand("fv", day * 10 + i), 0, max);
            if (vault.depositQueueLength() > statMaxDepQueue) statMaxDepQueue = vault.depositQueueLength();
            if (vault.withdrawQueueLength() > statMaxWdQueue) statMaxWdQueue = vault.withdrawQueueLength();
            uint256 g = gasleft();
            vm.prank(rebalancer);
            vault.processQueue(volume);
            g -= gasleft();
            if (g > statMaxFillGas) statMaxFillGas = g;
            ++statFills;
        }
    }

    function _claimAll(address who, uint256 salt) internal {
        uint256 owed = vault.maxMint(who);
        if (owed > 0) {
            // sometimes claim part through deposit() first
            uint256 left = vault.maxDeposit(who);
            if (salt % 3 == 0 && left > 2) {
                uint256 part = left / 2;
                if (Math.mulDiv(owed, part, left) > 0) {
                    creditedAssets[who] += part;
                    vm.prank(who);
                    vault.deposit(part, who);
                }
            }
            uint256 rest = vault.maxMint(who);
            vm.prank(who);
            creditedAssets[who] += vault.mint(rest, who);
        }
        assertEq(vault.maxDeposit(who), 0, "STRANDED deposit assets");

        uint256 out = vault.maxRedeem(who);
        if (out > 0) {
            vm.prank(who);
            received[who] += vault.redeem(out, who, who);
        }
        uint256 tail = vault.maxWithdraw(who);
        if (tail > 0) {
            vm.prank(who);
            vault.withdraw(tail, who, who);
            received[who] += tail;
        }
        assertEq(vault.maxWithdraw(who), 0, "STRANDED withdraw assets");
    }

    function _promptClaims(uint256 day) internal {
        for (uint256 i; i < everyone.length; ++i)
            if (!slow[everyone[i]]) _claimAll(everyone[i], _rand("cs", day * 100 + i));
    }

    // ----------------------------------------------------------------- checks

    function _checkAccounting(uint256 day) internal {
        assertSolvent();

        uint256 pendingOut;
        uint256 owedShares;
        uint256 owedAssets;
        for (uint256 i; i < everyone.length; ++i) {
            pendingOut += vault.pendingRedeemRequest(0, everyone[i]);
            owedShares += vault.maxMint(everyone[i]);
            owedAssets += vault.maxWithdraw(everyone[i]);
        }
        assertEq(pendingOut, vault.totalPendingWithdraws(), "pending redeems != total");
        assertEq(owedShares, vault.claimableDepositTotal(), "claimable deposit shares != total");
        assertEq(owedAssets, vault.claimableWithdrawTotal(), "claimable withdraw assets != total");

        uint256 live;
        uint256 liveShares;
        for (uint256 i; i < deps.length; ++i) {
            Dep storage d = deps[i];
            if (d.closed) continue;
            uint256 amt = vault.queuedDepositRequest(d.who, d.nonce).amount;
            if (vault.queuedDepositRequest(d.who, d.nonce).controller == address(0)) {
                d.closed = true;
                uint256 wait = day - d.day;
                statWaitSum += wait;
                ++statClosed;
                if (wait > statMaxWait) statMaxWait = wait;
                continue;
            }
            ++live;
            liveShares += amt;
        }
        assertEq(live, vault.depositQueueLength(), "deposit queue length != live requests");
        assertEq(liveShares, vault.totalPendingDeposits(), "deposit queue total != live request amounts");
    }

    // ------------------------------------------------------------------- run

    function _run(uint256 seed_) internal {
        seed = seed_;
        _bootstrap();
        uint256 savingsPriceStart = savingsVault.convertToAssets(1e18);

        for (uint256 day = 1; day <= DAYS; ++day) {
            vm.warp(block.timestamp + 1 days);
            _liquidityWeather(day);
            _newDeposits(day);
            _newRedeems(day);
            if (vault.withdrawQueueLength() > statMaxWdQueue) statMaxWdQueue = vault.withdrawQueueLength();
            _randomCancels();
            _fills(day);
            _promptClaims(day);
            _checkAccounting(day);
        }

        // ---- wind down: liquidity returns, everything is processed
        if (crunched) {
            uint256 lent = _sv().lent();
            deal(address(baseAsset), borrower, lent);
            vm.startPrank(borrower);
            baseAsset.approve(address(savingsVault), lent);
            _sv().repay(lent);
            vm.stopPrank();
            crunched = false;
        }
        uint256 sleeve = _freeSleeveShares();
        if (sleeve > 0) {
            vm.prank(rebalancer);
            vault.withdrawFromSavings(sleeve);
        }
        uint256 need = vault.convertToAssets(vault.totalPendingWithdraws());
        deal(address(baseAsset), address(vault), baseAsset.balanceOf(address(vault)) + need + 1 ether);
        uint256 supply = vault.totalSupply();
        vm.prank(vaultManager);
        vault.setCapacity(supply + 1_000 ether);
        for (uint256 i; i < 5 && (vault.depositQueueLength() > 0 || vault.totalPendingWithdraws() > 0); ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(rebalancer);
            vault.processQueue(type(uint256).max);
        }
        assertEq(vault.depositQueueLength(), 0, "deposit queue did not drain");
        assertEq(vault.totalPendingWithdraws(), 0, "withdraw queue did not drain");
        _checkAccounting(DAYS + 1);

        // ---- slow claimers finally show up, a year later
        vm.warp(block.timestamp + 365 days);
        for (uint256 i; i < everyone.length; ++i) _claimAll(everyone[i], i);

        assertEq(vault.claimableDepositTotal(), 0);
        assertEq(vault.claimableWithdrawTotal(), 0);
        assertEq(vault.balanceOf(address(vault)), 0, "escrow not empty");
        uint256 userShares;
        for (uint256 i; i < everyone.length; ++i) userShares += vault.balanceOf(everyone[i]);
        assertEq(userShares, vault.totalSupply(), "supply != user balances");
        assertSolvent();

        // ---- per-user fairness
        uint256 savingsGrowthBound = Math.mulDiv(savingsVault.convertToAssets(1e18), 1e18, savingsPriceStart) + 1e15;
        for (uint256 i; i < DEPOSITORS; ++i) {
            address who = depositors[i];
            if (requested[who] == 0) continue;
            uint256 got = creditedAssets[who] + refunded[who];
            assertGe(got + DUST_PER_USER, requested[who], "depositor lost value");
            assertLe(got, Math.mulDiv(requested[who], savingsGrowthBound, 1e18) + DUST_PER_USER, "depositor credited more than spUSDC yield");
            // escrowed shares keep accruing, so slow claimers are not penalised
            assertGe(vault.convertToAssets(vault.balanceOf(who)) + DUST_PER_USER, creditedAssets[who], "claimed shares worth less than credited assets");
        }
        for (uint256 i; i < HOLDERS; ++i) {
            address who = holders[i];
            if (redeemSharesRequested[who] == 0) continue;
            uint256 floor_ = Math.mulDiv(redeemValueAtRequest[who], 10_000 - FEE_BPS, 10_000);
            assertGe(received[who] + DUST_PER_USER, floor_, "redeemer got less than request value minus fee");
            assertLe(received[who], vault.convertToAssets(redeemSharesRequested[who]), "redeemer got more than shares are worth");
        }

        // ---- bank run: everyone redeems everything, Arkis unwinds to cover it
        uint256 outstanding = vault.convertToAssets(vault.totalSupply());
        int256 freeNow = vault.availableLiquidAssets();
        uint256 idle = freeNow > 0 ? uint256(freeNow) : 0;
        uint256 arkisReturn = outstanding > idle ? outstanding - idle + 1 ether : 0;
        deal(address(baseAsset), address(vault), baseAsset.balanceOf(address(vault)) + arkisReturn);
        uint256[] memory exitValue = new uint256[](everyone.length);
        for (uint256 i; i < everyone.length; ++i) {
            address who = everyone[i];
            uint256 bal = vault.balanceOf(who);
            if (bal == 0 || vault.convertToAssets(bal) < MINIMUM_WITHDRAW) continue;
            exitValue[i] = vault.convertToAssets(bal);
            received[who] = 0;
            vm.prank(who);
            vault.requestRedeem(bal, who, who);
        }
        vm.prank(rebalancer);
        vault.processQueue(type(uint256).max);
        assertEq(vault.totalPendingWithdraws(), 0, "bank run not fully processed");
        for (uint256 i; i < everyone.length; ++i) {
            address who = everyone[i];
            if (exitValue[i] == 0) continue;
            _claimAll(who, i);
            assertGe(received[who] + DUST_PER_USER, Math.mulDiv(exitValue[i], 10_000 - FEE_BPS, 10_000), "exit paid less than share value minus fee");
            assertLe(received[who], exitValue[i], "exit paid more than share value");
        }
        assertSolvent();
        uint256 dustSupply = vault.totalSupply();
        emit log_named_decimal_uint("spPRIME supply left after bank run (sub-minimum dust)", dustSupply, 18);
        emit log_named_decimal_uint("Arkis USDC returned for the bank run", arkisReturn, 18);

        emit log_named_uint("deposit requests queued", deps.length);
        emit log_named_uint("deposit cancels", statCancels);
        emit log_named_uint("redeem requests", statRedeems);
        emit log_named_uint("processQueue calls", statFills);
        emit log_named_uint("days in spUSDC crunch", statCrunchDays);
        emit log_named_uint("max deposit queue length", statMaxDepQueue);
        emit log_named_uint("max withdraw queue length", statMaxWdQueue);
        emit log_named_uint("max processQueue gas", statMaxFillGas);
        emit log_named_uint("max deposit wait (days)", statMaxWait);
        emit log_named_uint("avg deposit wait (days x100)", statClosed == 0 ? 0 : (statWaitSum * 100) / statClosed);
        emit log_named_decimal_uint("vault USDC after bank run (fees + 1 USDC buffer)", baseAsset.balanceOf(address(vault)), 18);
    }

    function test_busyQueue_fixedSeed() public {
        _run(42);
    }

    /// forge-config: default.fuzz.runs = 8
    function testFuzz_busyQueue(uint256 seed_) public {
        _run(seed_);
    }
}
