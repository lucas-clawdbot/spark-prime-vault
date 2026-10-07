// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {QueueHelper} from "./utils/QueueHelper.sol";
import {SavingsVault} from "./mocks/SavingsVault.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";

/// @notice spUSDC liquidity crunch scenarios. The vault keeps a 10% sleeve in
/// the savings vault (spUSDC) and the other 90% is taken to Arkis. The savings
/// vault's USDC is then lent out so it cannot honour redemptions.
contract LiquidityStressTests is QueueHelper {
    address internal borrower = makeAddr("spusdc_borrower");
    address[] internal holders;
    uint256 internal constant TVL = 100 ether;

    function setUp() public {
        _deployVault();
        for (uint256 i; i < 10; ++i)
            holders.push(makeAddr(string.concat("holder", vm.toString(i))));
    }

    function _sv() internal view returns (SavingsVault) {
        return SavingsVault(address(savingsVault));
    }

    /// @dev 10 holders deposit TVL instantly; 10% goes to spUSDC, 90% to Arkis
    function _setupSleeve() internal {
        for (uint256 i; i < holders.length; ++i)
            _depositAndClaim(holders[i], TVL / holders.length);
        vm.prank(rebalancer);
        vault.depositToSavings(TVL / 10);
        _drainLiquidity();
        assertEq(vault.availableLiquidAssets(), 0, "no idle USDC in the vault");
    }

    function _sleeveShares() internal view returns (uint256) {
        return savingsVault.balanceOf(address(vault)) - vault.totalPendingDeposits();
    }

    /// @dev Lend out spUSDC's USDC until only `leave` remains redeemable
    function _crunchSpUSDC(uint256 leave) internal {
        uint256 cash = baseAsset.balanceOf(address(savingsVault));
        vm.prank(borrower);
        _sv().lend(cash - leave);
    }

    function _restoreSpUSDC() internal {
        uint256 lent = _sv().lent();
        deal(address(baseAsset), borrower, lent);
        vm.startPrank(borrower);
        baseAsset.approve(address(savingsVault), lent);
        _sv().repay(lent);
        vm.stopPrank();
    }

    function _arkisReturns(uint256 amount) internal {
        deal(address(baseAsset), liquidityManager, amount);
        vm.prank(liquidityManager);
        baseAsset.transfer(address(vault), amount);
    }

    function _process() internal {
        uint256 volume = vault.maxTradeVolume();
        vm.prank(rebalancer);
        vault.processQueue(volume);
    }

    function _sharesWorth(address who, uint256 assets) internal view returns (uint256 s) {
        s = vault.convertToShares(assets);
        uint256 bal = vault.balanceOf(who);
        if (s > bal) s = bal;
    }

    function _logState(string memory label, address who) internal {
        emit log(label);
        emit log_named_decimal_uint("  spUSDC redeemable USDC      ", baseAsset.balanceOf(address(savingsVault)), 18);
        emit log_named_decimal_uint("  vault idle USDC             ", baseAsset.balanceOf(address(vault)), 18);
        emit log_named_decimal_uint("  vault sleeve value (spUSDC) ", savingsVault.convertToAssets(_sleeveShares()), 18);
        emit log_named_decimal_uint("  maxTradeVolume              ", vault.maxTradeVolume(), 18);
        emit log_named_decimal_uint("  redeemer pending (spPRIME)  ", vault.pendingRedeemRequest(0, who), 18);
        emit log_named_decimal_uint("  redeemer claimable USDC     ", vault.maxWithdraw(who), 18);
    }

    // ---------------------------------------------------------------------
    // Baseline: spUSDC fully liquid
    // ---------------------------------------------------------------------

    /// @dev Even with a liquid sleeve, a redeem is never instant: the vault's
    /// instant path only sees idle USDC, not the spUSDC sleeve. It takes a
    /// rebalancer withdrawFromSavings + processQueue, then the user's claim.
    function test_liquidSleeve_redeemNeedsRebalancerRoundTrip() public {
        _setupSleeve();
        address alice = holders[0];
        uint256 shares = _sharesWorth(alice, 8 ether);
        _requestRedeem(alice, shares);

        _logState("after requestRedeem (spUSDC liquid)", alice);
        assertEq(vault.maxWithdraw(alice), 0, "not instant even though spUSDC is liquid");
        assertEq(vault.pendingRedeemRequest(0, alice), shares);

        uint256 sleeveNow = _sleeveShares();
        vm.prank(rebalancer);
        vault.withdrawFromSavings(sleeveNow);
        _process();
        _logState("after withdrawFromSavings + processQueue", alice);

        assertEq(vault.pendingRedeemRequest(0, alice), 0, "filled in one rebalancer round");
        uint256 owed = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(owed, alice, alice);
        assertApproxEqAbs(baseAsset.balanceOf(alice), 8 ether, _drift(8 ether));
        assertSolvent();
    }

    // ---------------------------------------------------------------------
    // Crunch: spUSDC cannot honour the sleeve
    // ---------------------------------------------------------------------

    /// @dev Full timeline: sleeve stuck, partial unwind, Arkis returns funds,
    /// spUSDC recovers. The queue drains FIFO and the vault stays solvent.
    function test_crunch_redeemQueuesThenDrainsAsLiquidityReturns() public {
        _setupSleeve();
        address alice = holders[0];
        address bob = holders[1];
        _crunchSpUSDC(1 ether);

        uint256 aliceShares = _sharesWorth(alice, 8 ether);
        _requestRedeem(alice, aliceShares);
        _logState("T0 crunch: alice requests 8 USDC, spUSDC has 1 USDC", alice);

        // 1. The rebalancer cannot unwind the full 10 USDC sleeve
        uint256 sleeve = _sleeveShares();
        vm.prank(rebalancer);
        vm.expectRevert();
        vault.withdrawFromSavings(sleeve);

        // 2. It can unwind what spUSDC can pay: ~1 USDC
        uint256 redeemable = savingsVault.maxRedeem(address(vault));
        assertLt(redeemable, sleeve, "sleeve only partly redeemable");
        vm.prank(rebalancer);
        vault.withdrawFromSavings(redeemable);
        _process();
        _logState("T1 partial unwind + processQueue", alice);
        uint256 t1 = vault.maxWithdraw(alice);
        assertApproxEqAbs(t1, 1 ether, _drift(1 ether), "alice partly filled with what spUSDC paid");
        assertGt(vault.pendingRedeemRequest(0, alice), 0, "remainder still queued");

        // Alice claims her partial fill, the rest waits
        vm.prank(alice);
        vault.withdraw(t1, alice, alice);

        // 3. Bob arrives and must queue behind alice even if USDC shows up
        uint256 bobShares = _sharesWorth(bob, 5 ether);
        _arkisReturns(4 ether);
        _requestRedeem(bob, bobShares);
        assertEq(vault.maxWithdraw(bob), 0, "bob queued behind alice");
        _process();
        _logState("T2 Arkis returns 4 USDC + processQueue (alice)", alice);
        assertApproxEqAbs(vault.maxWithdraw(alice), 4 ether, _drift(4 ether), "FIFO: alice gets the 4 USDC");
        assertEq(vault.maxWithdraw(bob), 0, "bob still waiting");

        // 4. spUSDC recovers, the rest of the sleeve unwinds
        _restoreSpUSDC();
        uint256 sleeveNow = _sleeveShares();
        vm.prank(rebalancer);
        vault.withdrawFromSavings(sleeveNow);
        _process();
        _logState("T3 spUSDC recovers, sleeve unwound + processQueue (alice)", alice);
        emit log_named_decimal_uint("  bob pending (spPRIME)       ", vault.pendingRedeemRequest(0, bob), 18);
        emit log_named_decimal_uint("  bob claimable USDC          ", vault.maxWithdraw(bob), 18);

        assertEq(vault.pendingRedeemRequest(0, alice), 0, "alice complete");
        assertGt(vault.maxWithdraw(bob), 0, "bob partly or fully filled");
        assertSolvent();

        // 5. Arkis returns the rest, everyone is made whole
        _arkisReturns(10 ether);
        _process();
        assertEq(vault.totalPendingWithdraws(), 0);
        uint256 aliceLeft = vault.maxRedeem(alice);
        uint256 bobLeft = vault.maxRedeem(bob);
        vm.prank(alice);
        vault.redeem(aliceLeft, alice, alice);
        vm.prank(bob);
        uint256 bobGot = vault.redeem(bobLeft, bob, bob);
        assertApproxEqAbs(bobGot, 5 ether, _drift(5 ether));
        assertApproxEqAbs(baseAsset.balanceOf(alice), 8 ether, _drift(8 ether), "alice got 8 USDC overall");
        assertSolvent();
    }

    /// @dev Zero spUSDC liquidity and zero idle USDC: requestRedeem still works
    /// and queues, processQueue is a no-op, nothing reverts, nothing breaks
    function test_crunch_totalFreeze_queueIsInertButSafe() public {
        _setupSleeve();
        _crunchSpUSDC(0);
        for (uint256 i; i < 5; ++i)
            _requestRedeem(holders[i], vault.balanceOf(holders[i]) / 2);
        assertEq(vault.maxTradeVolume(), 0);

        vm.prank(rebalancer);
        vm.expectRevert();
        vault.withdrawFromSavings(1);

        uint256 pending = vault.totalPendingWithdraws();
        vm.prank(rebalancer);
        vault.processQueue(type(uint256).max);
        assertEq(vault.totalPendingWithdraws(), pending, "nothing filled");
        assertEq(vault.withdrawQueueLength(), 5);
        assertSolvent();
    }

    // ---------------------------------------------------------------------
    // Crunch: queued deposits sitting in spUSDC
    // ---------------------------------------------------------------------

    /// @dev Queued depositors' USDC sits in spUSDC. If spUSDC is lent out,
    /// they can't cancel (cancel redeems from spUSDC) and can't be matched
    /// against redeemers until liquidity returns.
    function test_crunch_queuedDepositorsCannotCancelOrFill() public {
        _setupSleeve();
        _requestRedeem(holders[0], _sharesWorth(holders[0], 5 ether));
        _closeCapacity();
        address dave = makeAddr("dave");
        _requestDeposit(dave, 5 ether);
        uint256 nonce = vault.requestNonce(dave);
        uint256 volumeBefore = vault.maxTradeVolume();
        assertGt(volumeBefore, 0, "deposit can match the redeem while spUSDC is liquid");

        _crunchSpUSDC(0);
        emit log_named_decimal_uint("maxTradeVolume before crunch", volumeBefore, 18);
        emit log_named_decimal_uint("maxTradeVolume during crunch", vault.maxTradeVolume(), 18);
        assertEq(vault.maxTradeVolume(), 0, "match blocked: spUSDC can't pay dave's shares out");

        vm.prank(dave);
        vm.expectRevert();
        vault.cancelDepositRequest(dave, nonce);
        vm.prank(guardian);
        vm.expectRevert();
        vault.cancelDepositRequest(dave, nonce);
        emit log("dave and the guardian both fail to cancel during the crunch");

        assertGt(vault.pendingDepositRequest(0, dave), 0, "dave still shown as pending");
        assertSolvent();

        _restoreSpUSDC();
        _process();
        assertEq(vault.depositQueueLength(), 0, "matched once spUSDC recovers");
        assertGt(vault.maxMint(dave), 0);
        assertSolvent();
    }

    /// @dev A partial crunch: the deposit queue can only be matched up to what
    /// spUSDC can pay, and the vault's own sleeve competes for that same cash
    function test_partialCrunch_depositFillCappedBySpUSDCCash() public {
        _setupSleeve();
        _requestRedeem(holders[0], _sharesWorth(holders[0], 6 ether));
        _closeCapacity();
        _requestDeposit(makeAddr("erin"), 6 ether);
        _crunchSpUSDC(2 ether);

        uint256 volume = vault.maxTradeVolume();
        emit log_named_decimal_uint("maxTradeVolume with 2 USDC in spUSDC", volume, 18);
        assertApproxEqAbs(volume, 2 ether, _drift(2 ether));
        _process();
        assertApproxEqAbs(vault.maxWithdraw(holders[0]), 2 ether, _drift(2 ether), "redeemer gets the 2 USDC");
        assertLe(vault.maxTradeVolume(), 1, "spUSDC cash now used up (1 wei dust)");
        assertEq(vault.depositQueueLength(), 1, "erin's remainder still queued");

        // The sleeve unwind now has nothing left to draw on
        uint256 sleeveLeft = _sleeveShares();
        vm.prank(rebalancer);
        vm.expectRevert();
        vault.withdrawFromSavings(sleeveLeft);
        assertSolvent();
    }

    /// @dev The rebalancer sizes a fill, then spUSDC is drained before it lands.
    /// processQueue re-reads maxTradeVolume, so it must not revert.
    function testFuzz_crunchFrontRunsProcessQueue(uint256 leave) public {
        _setupSleeve();
        _requestRedeem(holders[0], _sharesWorth(holders[0], 6 ether));
        _requestRedeem(holders[1], _sharesWorth(holders[1], 6 ether));
        _closeCapacity();
        _requestDeposit(makeAddr("f1"), 4 ether);
        _requestDeposit(makeAddr("f2"), 4 ether);
        _arkisReturns(1 ether);

        uint256 volume = vault.maxTradeVolume();
        _crunchSpUSDC(bound(leave, 0, 3 ether));
        vm.prank(rebalancer);
        vault.processQueue(volume);
        assertSolvent();
    }

    /// @dev New deposits during a crunch still work: the depositor's own USDC
    /// lands in spUSDC and is immediately the only cash that can match them
    function test_crunch_newDepositBringsItsOwnLiquidity() public {
        _setupSleeve();
        _requestRedeem(holders[0], _sharesWorth(holders[0], 5 ether));
        _closeCapacity();
        _crunchSpUSDC(0);
        address gus = makeAddr("gus");
        _requestDeposit(gus, 3 ether);
        uint256 volume = vault.maxTradeVolume();
        emit log_named_decimal_uint("maxTradeVolume from gus's fresh USDC", volume, 18);
        assertApproxEqAbs(volume, 3 ether, _drift(3 ether));
        _process();
        assertGt(vault.maxMint(gus), 0, "gus matched with his own cash");
        assertApproxEqAbs(vault.maxWithdraw(holders[0]), 3 ether, _drift(3 ether));
        assertSolvent();
    }
}

/// @notice One burst: 400 queued deposits and 150 queued redeems, then the
/// whole book is cleared in a single processQueue, versus in chunks
contract QueueBurstTests is QueueHelper {
    function setUp() public {
        _deployVault();
    }

    function _book() internal {
        for (uint256 i; i < 150; ++i) {
            address h = makeAddr(string.concat("bh", vm.toString(i)));
            _depositAndClaim(h, 1 ether);
        }
        _drainLiquidity();
        for (uint256 i; i < 150; ++i) {
            address h = makeAddr(string.concat("bh", vm.toString(i)));
            _requestRedeem(h, vault.balanceOf(h));
        }
        _closeCapacity();
        for (uint256 i; i < 400; ++i)
            _requestDeposit(makeAddr(string.concat("bd", vm.toString(i % 120))), 0.3 ether + i * 1e15);
        assertEq(vault.withdrawQueueLength(), 150);
        assertEq(vault.depositQueueLength(), 400);
    }

    function test_burst_singleCall() public {
        _book();
        _setCapacity(vault.totalSupply() + 500 ether);
        uint256 g = gasleft();
        vm.prank(rebalancer);
        vault.processQueue(type(uint256).max);
        emit log_named_uint("gas: clear 150 redeems + 400 deposits in one call", g - gasleft());
        assertEq(vault.totalPendingWithdraws(), 0);
        assertEq(vault.depositQueueLength(), 0);
        assertSolvent();
    }

    function test_burst_chunked() public {
        _book();
        _setCapacity(vault.totalSupply() + 500 ether);
        uint256 calls;
        uint256 maxGas;
        while (vault.depositQueueLength() > 0 || vault.totalPendingWithdraws() > 0) {
            uint256 g = gasleft();
            vm.prank(rebalancer);
            vault.processQueue(10 ether);
            g -= gasleft();
            if (g > maxGas) maxGas = g;
            ++calls;
            assertSolvent();
            require(calls < 100, "no progress");
        }
        emit log_named_uint("chunked calls (10 USDC each)", calls);
        emit log_named_uint("max gas per chunk", maxGas);
    }
}
