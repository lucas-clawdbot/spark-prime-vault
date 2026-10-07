// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {IVault} from "src/interfaces/IVault.sol";
import {ISparkPrimeVault} from "src/interfaces/ISparkPrimeVault.sol";
import {QueueHelper} from "./utils/QueueHelper.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Adversarial tests that try to break the deposit and withdraw queues
contract QueueBreakTests is QueueHelper {
    address[] internal actors;

    function setUp() public {
        _deployVault();
        for (uint256 i; i < 8; ++i)
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
    }

    function _queueDeposit(
        address who,
        uint256 amount
    ) internal returns (uint256 nonce) {
        _requestDeposit(who, amount);
        nonce = vault.requestNonce(who);
    }

    function _process(uint256 volume) internal {
        vm.prank(rebalancer);
        vault.processQueue(volume);
    }

    function _claimEverything(address who) internal {
        uint256 owed = vault.maxMint(who);
        if (owed > 0) {
            vm.prank(who);
            vault.mint(owed, who);
        }
        assertEq(vault.maxDeposit(who), 0, "STRANDED: deposited assets left after minting all shares");
        uint256 out = vault.maxRedeem(who);
        if (out > 0) {
            vm.prank(who);
            vault.redeem(out, who, who);
        }
        assertEq(vault.maxWithdraw(who), 0, "STRANDED: assets owed left after redeeming all shares");
    }

    /// @dev Builds a random mixed state: holders with queued redeems, a deposit
    /// queue with random sizes and cancels, and random liquidity and capacity
    function _randomState(uint256 seed) internal {
        uint256 nHolders = 1 + (seed % 4);
        for (uint256 i; i < nHolders; ++i) {
            uint256 value = bound(uint256(keccak256(abi.encode(seed, "h", i))), 1 ether, 20 ether);
            _depositAndClaim(actors[i], value);
        }
        _drainLiquidity();
        for (uint256 i; i < nHolders; ++i) {
            uint256 bal = vault.balanceOf(actors[i]);
            uint256 part = bound(uint256(keccak256(abi.encode(seed, "r", i))), bal / 10, bal);
            if (vault.convertToAssets(part) < MINIMUM_WITHDRAW) continue;
            _requestRedeem(actors[i], part);
        }

        _closeCapacity();
        uint256 nDeposits = 1 + ((seed >> 8) % 12);
        uint256[] memory nonces = new uint256[](nDeposits);
        for (uint256 i; i < nDeposits; ++i) {
            address who = actors[4 + (i % 4)];
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, "d", i))), MINIMUM_DEPOSIT, 15 ether);
            nonces[i] = _queueDeposit(who, amount);
        }
        for (uint256 i; i < nDeposits; ++i) {
            if (uint256(keccak256(abi.encode(seed, "c", i))) % 3 != 0) continue;
            address who = actors[4 + (i % 4)];
            vm.prank(who);
            vault.cancelDepositRequest(who, nonces[i]);
        }

        uint256 inject = bound(seed >> 16, 0, 10 ether);
        if (inject > 0) _injectLiquidity(inject);
        uint256 extraCap = bound(seed >> 24, 0, 30 ether);
        if (extraCap > 0) _openCapacity(extraCap);
        vm.warp(block.timestamp + bound(seed >> 32, 0, 30 days));
    }

    // ---------------------------------------------------------------------
    // Liveness: processQueue at the advertised max volume must never revert
    // ---------------------------------------------------------------------

    function testFuzz_processQueue_maxTradeVolume_neverReverts(uint256 seed) public {
        _randomState(seed);
        _process(vault.maxTradeVolume());
        assertSolvent();
    }

    function testFuzz_processQueue_uintMax_neverReverts(uint256 seed) public {
        _randomState(seed);
        _process(type(uint256).max);
        assertSolvent();
    }

    function testFuzz_processQueue_arbitraryVolume_neverReverts(uint256 seed, uint256 volume) public {
        _randomState(seed);
        volume = bound(volume, 0, vault.maxTradeVolume());
        _process(volume);
        assertSolvent();
    }

    function testFuzz_processQueue_repeatedChunks_drainAndEveryoneClaims(uint256 seed, uint256 chunks) public {
        _randomState(seed);
        chunks = bound(chunks, 1, 20);
        uint256 total = vault.maxTradeVolume();
        for (uint256 i; i < chunks; ++i) {
            _process(total / chunks + 1);
            assertSolvent();
        }
        _process(type(uint256).max);
        assertSolvent();
        for (uint256 i; i < actors.length; ++i) _claimEverything(actors[i]);
        assertSolvent();
    }

    // ---------------------------------------------------------------------
    // Cancel edge cases
    // ---------------------------------------------------------------------

    function test_cancel_twice_reverts() public {
        _closeCapacity();
        uint256 nonce = _queueDeposit(user, 1 ether);
        vm.prank(user);
        vault.cancelDepositRequest(user, nonce);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ISparkPrimeVault.RequestNotQueued.selector, user, nonce));
        vault.cancelDepositRequest(user, nonce);
    }

    function test_cancel_unknownNonce_reverts() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ISparkPrimeVault.RequestNotQueued.selector, user, 99));
        vault.cancelDepositRequest(user, 99);
    }

    function test_cancel_afterFullFill_reverts() public {
        _depositAndClaim(user, 20 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        uint256 nonce = _queueDeposit(userTwo, 5 ether);
        _process(type(uint256).max);
        assertEq(vault.depositQueueLength(), 0);

        vm.prank(userTwo);
        vm.expectRevert(abi.encodeWithSelector(ISparkPrimeVault.RequestNotQueued.selector, userTwo, nonce));
        vault.cancelDepositRequest(userTwo, nonce);
    }

    /// @dev A partly filled request keeps its key at the head; cancelling it
    /// must refund only the remainder and keep the filled part claimable
    function test_cancel_partiallyFilledHead_refundsOnlyRemainder() public {
        _depositAndClaim(user, 20 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        uint256 nonce = _queueDeposit(userTwo, 10 ether);
        _queueDeposit(userThree, 10 ether);

        _process(4 ether);
        IVault.Transaction memory head = vault.depositQueueHead();
        assertEq(head.controller, userTwo, "partial remainder stays at head");
        assertEq(head.nonce, nonce);
        uint256 claimable = vault.maxMint(userTwo);
        assertGt(claimable, 0);

        uint256 before = baseAsset.balanceOf(userTwo);
        vm.prank(userTwo);
        vault.cancelDepositRequest(userTwo, nonce);
        uint256 refund = baseAsset.balanceOf(userTwo) - before;

        assertApproxEqAbs(refund + vault.maxDeposit(userTwo), 10 ether, _drift(10 ether), "refund + filled = request");
        assertEq(vault.maxMint(userTwo), claimable, "filled part survives cancel");
        assertEq(vault.pendingDepositRequest(0, userTwo), 0);
        assertEq(vault.depositQueueHead().controller, userThree);
        assertSolvent();
        _claimEverything(userTwo);
    }

    /// @dev Cancelled entries in front of active ones must be skipped by fills,
    /// isEmpty and the head view
    function test_cancelledPrefix_isSkippedEverywhere() public {
        _depositAndClaim(user, 30 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();

        uint256[] memory nonces = new uint256[](5);
        for (uint256 i; i < 5; ++i) nonces[i] = _queueDeposit(actors[i], 1 ether);
        uint256 last = _queueDeposit(userTwo, 2 ether);
        for (uint256 i; i < 5; ++i) {
            vm.prank(actors[i]);
            vault.cancelDepositRequest(actors[i], nonces[i]);
        }
        assertEq(vault.depositQueueLength(), 1);
        assertEq(vault.depositQueueHead().controller, userTwo);
        assertEq(vault.depositQueueHead().nonce, last);

        _process(1 ether);
        assertEq(vault.depositQueueLength(), 1, "only the live entry remains");
        _process(type(uint256).max);
        assertEq(vault.depositQueueLength(), 0);
        assertSolvent();
        _claimEverything(userTwo);
    }

    /// @dev If every queued entry is cancelled the queue reads empty, so a new
    /// depositor goes instant instead of queuing behind ghosts
    function test_allCancelled_newDepositIsInstant() public {
        _closeCapacity();
        uint256 n1 = _queueDeposit(user, 1 ether);
        uint256 n2 = _queueDeposit(userTwo, 1 ether);
        vm.prank(user);
        vault.cancelDepositRequest(user, n1);
        vm.prank(userTwo);
        vault.cancelDepositRequest(userTwo, n2);
        assertEq(vault.depositQueueLength(), 0);

        _openCapacity(5 ether);
        _requestDeposit(userThree, 1 ether);
        assertGt(vault.maxMint(userThree), 0, "instant fill");
        assertEq(vault.pendingDepositRequest(0, userThree), 0);
        assertSolvent();
    }

    /// @dev Sanitize with a small iteration budget must keep FIFO order
    function testFuzz_sanitize_preservesOrder(uint256 mask, uint256 budget) public {
        _closeCapacity();
        uint256 n = 10;
        uint256[] memory nonces = new uint256[](n);
        for (uint256 i; i < n; ++i) nonces[i] = _queueDeposit(actors[i % 8], 1 ether + i);
        uint256 live;
        address firstLive;
        uint256 firstLiveNonce;
        for (uint256 i; i < n; ++i) {
            if ((mask >> i) & 1 == 1) {
                vm.prank(actors[i % 8]);
                vault.cancelDepositRequest(actors[i % 8], nonces[i]);
            } else {
                if (live == 0) (firstLive, firstLiveNonce) = (actors[i % 8], nonces[i]);
                ++live;
            }
        }
        vault.sanitizeDepositQueue(bound(budget, 0, 20));
        assertEq(vault.depositQueueLength(), live);
        if (live > 0) {
            assertEq(vault.depositQueueHead().controller, firstLive);
            assertEq(vault.depositQueueHead().nonce, firstLiveNonce);
        }
        vault.sanitizeDepositQueue(type(uint256).max);
        assertEq(vault.depositQueueLength(), live);
    }

    // ---------------------------------------------------------------------
    // Queue jumping
    // ---------------------------------------------------------------------

    /// @dev Once anyone is queued, a later depositor must queue too, even if
    /// capacity opens up before the rebalancer runs
    function test_noDepositQueueJump_whenCapacityReopens() public {
        _closeCapacity();
        _queueDeposit(user, 5 ether);
        _openCapacity(50 ether);
        _requestDeposit(userTwo, 1 ether);
        assertEq(vault.maxMint(userTwo), 0, "late depositor jumped the queue");
        assertGt(vault.pendingDepositRequest(0, userTwo), 0);
    }

    /// @dev Once anyone is queued to redeem, a later redeemer must queue too,
    /// even if liquidity arrives before the rebalancer runs
    function test_noWithdrawQueueJump_whenLiquidityArrives() public {
        _depositAndClaim(user, 10 ether);
        _depositAndClaim(userTwo, 10 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _injectLiquidity(50 ether);
        _requestRedeem(userTwo, vault.balanceOf(userTwo));
        assertEq(vault.maxRedeem(userTwo), 0, "late redeemer jumped the queue");
    }

    // ---------------------------------------------------------------------
    // Rounding leaks: tiny volumes consume queued value for nothing
    // ---------------------------------------------------------------------

    /// @dev processQueue(1) takes one savings share from the head depositor and
    /// mints zero spPRIME for it: the depositor's value moves into vault
    /// liquidity. Repeating it bleeds the head of the queue.
    function test_dustVolume_depositorLosesSavingsShareForZeroShares() public {
        _depositAndClaim(user, 20 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        _queueDeposit(userTwo, 1 ether);

        uint256 pendingBefore = vault.totalPendingDeposits();
        uint256 calls = 50;
        for (uint256 i; i < calls; ++i) _process(1);
        uint256 consumed = pendingBefore - vault.totalPendingDeposits();

        emit log_named_uint("savings shares consumed", consumed);
        emit log_named_uint("spPRIME shares credited", vault.maxMint(userTwo));
        emit log_named_uint("assets credited", vault.maxDeposit(userTwo));
        assertEq(consumed, calls, "one savings share consumed per call");
        assertEq(vault.maxMint(userTwo), 0, "no spPRIME credited for consumed shares");
    }

    /// @dev Withdraw side: with a fee, a tiny fill burns the redeemer's shares
    /// and the ceil-rounded fee eats the whole payout
    function test_dustVolume_withFee_redeemerBurnedForZeroAssets() public {
        vm.prank(riskManager);
        vault.updateWithdrawFee(10);
        _depositAndClaim(user, 20 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        _queueDeposit(userTwo, 1 ether);

        uint256 pendingBefore = vault.totalPendingWithdraws();
        uint256 calls = 50;
        for (uint256 i; i < calls; ++i) _process(2);
        uint256 burned = pendingBefore - vault.totalPendingWithdraws();
        emit log_named_uint("redeemer shares burned", burned);
        emit log_named_uint("redeemer assets owed", vault.maxWithdraw(user));
        assertGt(burned, 0);
        assertEq(vault.maxWithdraw(user), 0, "burned shares paid nothing");
    }

    // ---------------------------------------------------------------------
    // Claim edge cases
    // ---------------------------------------------------------------------

    /// @dev Claiming in random chunks via deposit() must never strand a
    /// remainder that neither deposit() nor mint() can claim
    function testFuzz_chunkedDepositClaims_neverStrand(uint256 seed) public {
        _depositAndClaim(user, 30 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        for (uint256 i; i < 6; ++i) _queueDeposit(userTwo, bound(uint256(keccak256(abi.encode(seed, i))), MINIMUM_DEPOSIT, 4 ether));
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 1 days);
            _process(bound(uint256(keccak256(abi.encode(seed, "v", i))), 1, 6 ether));
        }
        _process(type(uint256).max);

        for (uint256 i; i < 10 && vault.maxDeposit(userTwo) > 0; ++i) {
            uint256 left = vault.maxDeposit(userTwo);
            uint256 chunk = bound(uint256(keccak256(abi.encode(seed, "k", i))), 1, left);
            uint256 shares = Math.mulDiv(vault.maxMint(userTwo), chunk, left);
            if (shares == 0) continue;
            vm.prank(userTwo);
            vault.deposit(chunk, userTwo);
        }
        _claimEverything(userTwo);
        assertSolvent();
    }

    /// @dev Same for withdraw() chunks then redeem() of the rest
    function testFuzz_chunkedWithdrawClaims_neverStrand(uint256 seed) public {
        vm.prank(riskManager);
        vault.updateWithdrawFee(bound(seed, 0, 5_000));
        _depositAndClaim(user, 30 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _injectLiquidity(40 ether);
        _process(vault.maxTradeVolume());

        for (uint256 i; i < 10 && vault.maxWithdraw(user) > 0; ++i) {
            uint256 left = vault.maxWithdraw(user);
            uint256 chunk = bound(uint256(keccak256(abi.encode(seed, "w", i))), 1, left);
            vm.prank(user);
            vault.withdraw(chunk, user, user);
        }
        _claimEverything(user);
        assertSolvent();
    }

    // ---------------------------------------------------------------------
    // Loss socialisation while queued
    // ---------------------------------------------------------------------

    /// @dev A loss written down while redeems sit in the queue must not make
    /// the vault insolvent or block the queue
    function test_lossWhileQueued_queueStillClears() public {
        _depositAndClaim(user, 20 ether);
        _depositAndClaim(userTwo, 20 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        _queueDeposit(userThree, 10 ether);

        vm.prank(guardian);
        vault.pause();
        uint256 ta = vault.totalAssets();
        vm.prank(riskManager);
        vault.setTotalAssets(ta / 2);
        vm.prank(admin);
        vault.unpause();

        _process(vault.maxTradeVolume());
        assertSolvent();
        _injectLiquidity(40 ether);
        _process(type(uint256).max);
        assertSolvent();
        _claimEverything(user);
        _claimEverything(userThree);
    }

    // ---------------------------------------------------------------------
    // Gas griefing
    // ---------------------------------------------------------------------

    /// @dev Many cancelled entries ahead of one live request: measures the
    /// gas a fill pays before sanitize, and that sanitize clears it
    function test_cancelledSpam_gas() public {
        _depositAndClaim(user, 20 ether);
        _drainLiquidity();
        _requestRedeem(user, vault.balanceOf(user));
        _closeCapacity();
        uint256 spam = 300;
        address griefer = makeAddr("griefer");
        for (uint256 i; i < spam; ++i) {
            uint256 nonce = _queueDeposit(griefer, MINIMUM_DEPOSIT);
            vm.prank(griefer);
            vault.cancelDepositRequest(griefer, nonce);
        }
        _queueDeposit(userTwo, 1 ether);

        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        _process(0.5 ether);
        emit log_named_uint("partial fill gas with 300 cancelled ahead", g - gasleft());
        vm.revertToState(snap);

        vault.sanitizeDepositQueue(type(uint256).max);
        g = gasleft();
        _process(0.5 ether);
        emit log_named_uint("partial fill gas after sanitize", g - gasleft());
        assertSolvent();
    }
}
