// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC7540Deposit }  from "../../src/interfaces/IERC7540.sol";
import { IQueue }           from "../../src/interfaces/IQueue.sol";
import { ISparkPrimeVault } from "../../src/interfaces/ISparkPrimeVault.sol";
import { IVault }           from "../../src/interfaces/IVault.sol";

import { ForkTestBase, IERC4626Like } from "./ForkTestBase.t.sol";

contract RequestDepositTests is ForkTestBase {
    // TODO : Add failure tests

    // Success tests

    function test_requestDeposit_instantClaim() external {
        deal(address(usdc), user, 100e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 0,
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 100e6,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vm.startPrank(user);
        usdc.approve(address(spPRIME), 100e6);

        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 100e6);
        vm.expectEmit(address(spPRIME));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPRIME.requestDeposit(100e6, user, user);
        vm.stopPrank();

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply           = 100e6;
        vaultState.totalAssets           = 100e6;
        vaultState.availableCapacity     = VAULT_CAPACITY - 100e6;
        vaultState.availableLiquidAssets = int256(100e6);

        depositState.claimableDepositRequest = 100e6;
        depositState.maxDeposit              = 100e6;
        depositState.maxMint                 = 100e6;
        depositState.claimableDepositTotal   = 100e6;
        depositState.requestNonce            = 1;

        userBalances.asset = 0;

        spPrimeBalances.asset  = 100e6;
        spPrimeBalances.shares = 100e6;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_requestDeposit_instantClaim_exactCapacity() external {
        deal(address(usdc), user, VAULT_CAPACITY);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 0,
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : VAULT_CAPACITY,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vm.startPrank(user);
        usdc.approve(address(spPRIME), VAULT_CAPACITY);

        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, VAULT_CAPACITY);
        vm.expectEmit(address(spPRIME));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, VAULT_CAPACITY);

        spPRIME.requestDeposit(VAULT_CAPACITY, user, user);
        vm.stopPrank();

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply           = VAULT_CAPACITY;
        vaultState.totalAssets           = VAULT_CAPACITY;
        vaultState.availableCapacity     = 0;
        vaultState.availableLiquidAssets = int256(VAULT_CAPACITY);

        depositState.claimableDepositRequest = VAULT_CAPACITY;
        depositState.maxDeposit              = VAULT_CAPACITY;
        depositState.maxMint                 = VAULT_CAPACITY;
        depositState.claimableDepositTotal   = VAULT_CAPACITY;
        depositState.requestNonce            = 1;

        userBalances.asset = 0;

        spPrimeBalances.asset  = VAULT_CAPACITY;
        spPrimeBalances.shares = VAULT_CAPACITY;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_requestDeposit_partialInstantClaim() external {
        uint256 amount       = VAULT_CAPACITY + 500e6;
        uint256 queuedShares = spUSDC.previewDeposit(500e6);  // spUSDC shares backing this request

        deal(address(usdc), user, amount);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 0,
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : amount,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        assertEq(usdc.allowance(user,             address(spPRIME)), 0);
        assertEq(usdc.allowance(address(spPRIME), address(spUSDC)),  0);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(address(0), address(0), 0, 0, 0));

        vm.startPrank(user);
        usdc.approve(address(spPRIME), amount);

        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, VAULT_CAPACITY);
        vm.expectEmit(address(spPRIME));
        emit IQueue.DepositQueueValuation(queuedShares);
        vm.expectEmit(address(spPRIME));
        emit ISparkPrimeVault.DepositQueued(user, user, 1, queuedShares);
        vm.expectEmit(address(spPRIME));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, amount);

        spPRIME.requestDeposit(amount, user, user);
        vm.stopPrank();

        assertEq(usdc.allowance(user,             address(spPRIME)), 0);
        assertEq(usdc.allowance(address(spPRIME), address(spUSDC)),  0);

        vaultState.totalSupply           = VAULT_CAPACITY;
        vaultState.totalAssets           = VAULT_CAPACITY;
        vaultState.availableCapacity     = 0;
        vaultState.availableLiquidAssets = int256(VAULT_CAPACITY);

        depositState.claimableDepositRequest = VAULT_CAPACITY;
        depositState.maxDeposit              = VAULT_CAPACITY;
        depositState.maxMint                 = VAULT_CAPACITY;
        depositState.claimableDepositTotal   = VAULT_CAPACITY;
        depositState.pendingDepositRequest   = spUSDC.convertToAssets(queuedShares);
        depositState.totalPendingDeposits    = queuedShares;
        depositState.depositQueueLength      = 1;
        depositState.requestNonce            = 1;

        userBalances.asset = 0;

        spPrimeBalances.asset         = VAULT_CAPACITY;
        spPrimeBalances.shares        = VAULT_CAPACITY;
        spPrimeBalances.savingsShares = queuedShares;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));

        assertEq(spPRIME.pendingDepositRequest(0, user), 500e6 - 1);
    }

    function test_requestDeposit_queued_noCapacity() external {
        _requestDeposit(user2, VAULT_CAPACITY); // Consumed all capacity

        uint256 queuedShares = spUSDC.previewDeposit(100e6);  // spUSDC shares backing this request

        deal(address(usdc), user, 100e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : VAULT_CAPACITY,
            totalAssets           : VAULT_CAPACITY,
            availableCapacity     : 0,
            availableLiquidAssets : int256(VAULT_CAPACITY),
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 100e6,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : VAULT_CAPACITY,
            shares        : VAULT_CAPACITY,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        assertEq(usdc.allowance(user,             address(spPRIME)), 0);
        assertEq(usdc.allowance(address(spPRIME), address(spUSDC)),  0);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(address(0), address(0), 0, 0, 0));

        vm.startPrank(user);
        usdc.approve(address(spPRIME), 100e6);

        vm.expectEmit(address(spPRIME));
        emit IQueue.DepositQueueValuation(queuedShares);
        vm.expectEmit(address(spPRIME));
        emit ISparkPrimeVault.DepositQueued(user, user, 1, queuedShares);
        vm.expectEmit(address(spPRIME));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPRIME.requestDeposit(100e6, user, user);
        vm.stopPrank();

        assertEq(usdc.allowance(user,             address(spPRIME)), 0);
        assertEq(usdc.allowance(address(spPRIME), address(spUSDC)),  0);

        depositState.pendingDepositRequest = spUSDC.convertToAssets(queuedShares);
        depositState.totalPendingDeposits  = queuedShares;
        depositState.depositQueueLength    = 1;
        depositState.requestNonce          = 1;

        userBalances.asset = 0;

        spPrimeBalances.savingsShares = queuedShares;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));

        assertEq(spPRIME.pendingDepositRequest(0, user), 100e6 - 1);
    }

    function test_requestDeposit_queued_queueNotEmpty() external {
        _requestDeposit(user2, VAULT_CAPACITY); // Consumed all capacity
        _requestDeposit(user2, 100e6);          // Queued, no capacity left

        // Increase capacity, but the queue is not empty
        vm.prank(VAULT_MANAGER);
        spPRIME.setCapacity(VAULT_CAPACITY + 1_000e6);

        uint256 totalQueuedShares = spPRIME.totalPendingDeposits();  // spUSDC shares backing all queued deposits
        uint256 queuedShares      = spUSDC.previewDeposit(100e6);    // spUSDC shares backing this request

        deal(address(usdc), user, 100e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : VAULT_CAPACITY,
            totalAssets           : VAULT_CAPACITY,
            availableCapacity     : 1_000e6,
            availableLiquidAssets : int256(VAULT_CAPACITY),
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : totalQueuedShares,
            depositQueueLength      : 1,
            requestNonce            : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 100e6,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : VAULT_CAPACITY,
            shares        : VAULT_CAPACITY,
            savingsShares : totalQueuedShares
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        assertEq(usdc.allowance(user,             address(spPRIME)), 0);
        assertEq(usdc.allowance(address(spPRIME), address(spUSDC)),  0);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(address(0), address(0), 0, 0, 0));

        assertEq(spPRIME.depositQueueHead().controller, user2);

        vm.startPrank(user);
        usdc.approve(address(spPRIME), 100e6);

        vm.expectEmit(address(spPRIME));
        emit IQueue.DepositQueueValuation(totalQueuedShares + queuedShares);
        vm.expectEmit(address(spPRIME));
        emit ISparkPrimeVault.DepositQueued(user, user, 1, queuedShares);
        vm.expectEmit(address(spPRIME));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPRIME.requestDeposit(100e6, user, user);
        vm.stopPrank();

        // Capacity is free, but the request still queues behind the existing entry (FIFO)
        assertEq(usdc.allowance(user,             address(spPRIME)), 0);
        assertEq(usdc.allowance(address(spPRIME), address(spUSDC)),  0);

        depositState.pendingDepositRequest = spUSDC.convertToAssets(queuedShares);
        depositState.totalPendingDeposits  = totalQueuedShares + queuedShares;
        depositState.depositQueueLength    = 2;
        depositState.requestNonce          = 1;

        userBalances.asset = 0;

        spPrimeBalances.savingsShares = totalQueuedShares + queuedShares;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));

        assertEq(spPRIME.depositQueueHead().controller, user2);
    }

    function test_requestDeposit_instantAfterQueueFullyCancelled() external {
        _requestDeposit(user2, VAULT_CAPACITY); // Consumed all capacity
        _requestDeposit(user,  100e6);          // Queued as nonce 1, no capacity left

        vm.prank(VAULT_MANAGER);
        spPRIME.setCapacity(VAULT_CAPACITY + 100e6);

        vm.prank(user);
        spPRIME.cancelDepositRequest(user, 1);

        deal(address(usdc), user, 100e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : VAULT_CAPACITY,
            totalAssets           : VAULT_CAPACITY,
            availableCapacity     : 100e6,
            availableLiquidAssets : int256(VAULT_CAPACITY),
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 100e6,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : VAULT_CAPACITY,
            shares        : VAULT_CAPACITY,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(address(0), address(0), 0, 0, 0));

        vm.startPrank(user);
        usdc.approve(address(spPRIME), 100e6);

        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 100e6);
        vm.expectEmit(address(spPRIME));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPRIME.requestDeposit(100e6, user, user);
        vm.stopPrank();

        // The cancelled entry no longer counts as a queue, so the request fills instantly
        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply           = VAULT_CAPACITY + 100e6;
        vaultState.totalAssets           = VAULT_CAPACITY + 100e6;
        vaultState.availableCapacity     = 0;
        vaultState.availableLiquidAssets = int256(VAULT_CAPACITY + 100e6);

        depositState.claimableDepositRequest = 100e6;
        depositState.maxDeposit              = 100e6;
        depositState.maxMint                 = 100e6;
        depositState.claimableDepositTotal   = VAULT_CAPACITY + 100e6;
        depositState.requestNonce            = 2;

        userBalances.asset = 0;

        spPrimeBalances.asset  = VAULT_CAPACITY + 100e6;
        spPrimeBalances.shares = VAULT_CAPACITY + 100e6;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_requestDeposit_afterInterestAccrual() external {
        uint256 deployTimestamp = block.timestamp;

        skip(365 days);

        uint256 expectedIndex  = spPRIME.previewIndex();
        uint256 expectedShares = 100e6 * RAY / expectedIndex;

        // 10% APY over one year
        assertApproxEqRel(expectedIndex, 1.1e27, 0.0001e18);

        deal(address(usdc), user, 100e6);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 0,
            totalAssets           : 0,
            availableCapacity     : VAULT_CAPACITY,
            availableLiquidAssets : 0,
            index                 : RAY,
            lastAccrual           : deployTimestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : 0,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 0
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 100e6,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vm.startPrank(user);
        usdc.approve(address(spPRIME), 100e6);

        vm.expectEmit(address(spPRIME));
        emit IVault.AccruedInterest(expectedIndex, block.timestamp);
        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 100e6);
        vm.expectEmit(address(spPRIME));
        emit IERC7540Deposit.DepositRequest(user, user, 0, user, 100e6);

        spPRIME.requestDeposit(100e6, user, user);
        vm.stopPrank();

        // Shares are minted at the accrued index, so fewer shares than assets
        assertLt(expectedShares, 100e6);

        assertEq(usdc.allowance(user, address(spPRIME)), 0);

        vaultState.totalSupply           = expectedShares;
        vaultState.totalAssets           = expectedShares * expectedIndex / RAY;
        vaultState.availableCapacity     = VAULT_CAPACITY - expectedShares;
        vaultState.availableLiquidAssets = int256(100e6);
        vaultState.index                 = expectedIndex;
        vaultState.lastAccrual           = block.timestamp;

        depositState.claimableDepositRequest = 100e6;
        depositState.maxDeposit              = 100e6;
        depositState.maxMint                 = expectedShares;
        depositState.claimableDepositTotal   = expectedShares;
        depositState.requestNonce            = 1;

        userBalances.asset = 0;

        spPrimeBalances.asset  = 100e6;
        spPrimeBalances.shares = expectedShares;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_requestDeposit_queued_pendingValueAccruesSavingsYield() external {
        uint256 deployTimestamp = block.timestamp;

        _requestDeposit(user2, VAULT_CAPACITY); // Consumed all capacity

        uint256 queuedShares = spUSDC.previewDeposit(100e6);  // spUSDC shares backing this request

        _requestDeposit(user, 100e6);  // Queued as nonce 1, no capacity left

        uint256 pendingBefore = spPRIME.pendingDepositRequest(0, user);

        assertEq(pendingBefore, 100e6 - 1);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : VAULT_CAPACITY,
            totalAssets           : VAULT_CAPACITY,
            availableCapacity     : 0,
            availableLiquidAssets : int256(VAULT_CAPACITY),
            index                 : RAY,
            lastAccrual           : deployTimestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 0,
            maxDeposit              : 0,
            maxMint                 : 0,
            claimableDepositTotal   : VAULT_CAPACITY,
            pendingDepositRequest   : spUSDC.convertToAssets(queuedShares),
            totalPendingDeposits    : queuedShares,
            depositQueueLength      : 1,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : VAULT_CAPACITY,
            shares        : VAULT_CAPACITY,
            savingsShares : queuedShares
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));

        skip(30 days);

        uint256 expectedIndex = spPRIME.previewIndex();

        // The spUSDC share count is unchanged, its value grows with the spUSDC rate
        assertGt(spPRIME.pendingDepositRequest(0, user), pendingBefore);

        vaultState.totalAssets = VAULT_CAPACITY * expectedIndex / RAY;

        depositState.pendingDepositRequest = spUSDC.convertToAssets(queuedShares);

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        _assertQueuedDepositRequest(user, 1, IVault.Transaction(user, user, queuedShares, 1, 0));
    }

}

contract DepositTests is ForkTestBase {

    // TODO : Add failure tests

    // Success tests

    function test_deposit_fullClaim() external {
        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 100e6,
            totalAssets           : 100e6,
            availableCapacity     : VAULT_CAPACITY - 100e6,
            availableLiquidAssets : int256(100e6),
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 100e6,
            shares        : 100e6,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPRIME));
        emit IERC4626Like.Deposit(user, user, 100e6, 100e6);

        vm.prank(user);
        uint256 shares = spPRIME.deposit(100e6, user, user);

        assertEq(shares, 100e6);

        // Claiming only moves escrowed shares from the vault to the receiver
        depositState.claimableDepositRequest = 0;
        depositState.maxDeposit              = 0;
        depositState.maxMint                 = 0;
        depositState.claimableDepositTotal   = 0;

        userBalances.shares = 100e6;

        spPrimeBalances.shares = 0;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_deposit_partialClaim() external {
        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 100e6,
            totalAssets           : 100e6,
            availableCapacity     : VAULT_CAPACITY - 100e6,
            availableLiquidAssets : int256(100e6),
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 100e6,
            shares        : 100e6,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 60e6);
        vm.expectEmit(address(spPRIME));
        emit IERC4626Like.Deposit(user, user, 40e6, 40e6);

        vm.prank(user);
        uint256 shares = spPRIME.deposit(40e6, user, user);

        assertEq(shares, 40e6);

        depositState.claimableDepositRequest = 60e6;
        depositState.maxDeposit              = 60e6;
        depositState.maxMint                 = 60e6;
        depositState.claimableDepositTotal   = 60e6;

        userBalances.shares = 40e6;

        spPrimeBalances.shares = 60e6;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_deposit_multiplePartialClaims() external {
        // Request at an accrued index so shares owed differ from assets and every claim rounds
        skip(365 days);

        _requestDeposit(user, 100e6);

        uint256 index = spPRIME.index();

        // 10% APY over one year
        assertApproxEqRel(index, 1.1e27, 0.0001e18);

        uint256 sharesOwed = 100e6 * RAY / index;

        uint256 shares1 = sharesOwed * 30e6 / 100e6;
        uint256 shares2 = (sharesOwed - shares1) * 30e6 / 70e6;
        uint256 shares3 = sharesOwed - shares1 - shares2;  // Last claim takes every remaining share

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : sharesOwed,
            totalAssets           : sharesOwed * index / RAY,
            availableCapacity     : VAULT_CAPACITY - sharesOwed,
            availableLiquidAssets : int256(100e6),
            index                 : index,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : sharesOwed,
            claimableDepositTotal   : sharesOwed,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 100e6,
            shares        : sharesOwed,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        vm.prank(user);
        uint256 shares = spPRIME.deposit(30e6, user, user);

        assertEq(shares, shares1);

        depositState.claimableDepositRequest = 70e6;
        depositState.maxDeposit              = 70e6;
        depositState.maxMint                 = sharesOwed - shares1;
        depositState.claimableDepositTotal   = sharesOwed - shares1;

        userBalances.shares = shares1;

        spPrimeBalances.shares = sharesOwed - shares1;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        vm.prank(user);
        shares = spPRIME.deposit(30e6, user, user);

        assertEq(shares, shares2);

        depositState.claimableDepositRequest = 40e6;
        depositState.maxDeposit              = 40e6;
        depositState.maxMint                 = shares3;
        depositState.claimableDepositTotal   = shares3;

        userBalances.shares = shares1 + shares2;

        spPrimeBalances.shares = shares3;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        vm.prank(user);
        shares = spPRIME.deposit(40e6, user, user);

        assertEq(shares, shares3);

        // Every owed share reaches the user, no dust is left in escrow
        depositState.claimableDepositRequest = 0;
        depositState.maxDeposit              = 0;
        depositState.maxMint                 = 0;
        depositState.claimableDepositTotal   = 0;

        userBalances.shares = sharesOwed;

        spPrimeBalances.shares = 0;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_deposit_operatorAndDifferentReceiver() external {
        address operator = makeAddr("operator");

        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        vm.prank(user);
        spPRIME.setOperator(operator, true);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 100e6,
            totalAssets           : 100e6,
            availableCapacity     : VAULT_CAPACITY - 100e6,
            availableLiquidAssets : int256(100e6),
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory user2Balances = AssertBalancesParams({
            account       : user2,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory operatorBalances = AssertBalancesParams({
            account       : operator,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 100e6,
            shares        : 100e6,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(user2Balances);
        _assertBalances(operatorBalances);
        _assertBalances(spPrimeBalances);

        // Operator claims for the controller, and can only send to the controller
        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 60e6);
        vm.expectEmit(address(spPRIME));
        emit IERC4626Like.Deposit(user, user, 40e6, 40e6);

        vm.prank(operator);
        uint256 shares = spPRIME.deposit(40e6, user, user);

        assertEq(shares, 40e6);

        depositState.claimableDepositRequest = 60e6;
        depositState.maxDeposit              = 60e6;
        depositState.maxMint                 = 60e6;
        depositState.claimableDepositTotal   = 60e6;

        userBalances.shares = 40e6;

        spPrimeBalances.shares = 60e6;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(user2Balances);
        _assertBalances(operatorBalances);
        _assertBalances(spPrimeBalances);

        // Controller claims the rest to a different receiver
        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPRIME));
        emit IERC4626Like.Deposit(user, user2, 60e6, 60e6);

        vm.prank(user); // user is the controller
        shares = spPRIME.deposit(60e6, user2, user);

        assertEq(shares, 60e6);

        depositState.claimableDepositRequest = 0;
        depositState.maxDeposit              = 0;
        depositState.maxMint                 = 0;
        depositState.claimableDepositTotal   = 0;

        user2Balances.shares = 60e6;

        spPrimeBalances.shares = 0;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(user2Balances);
        _assertBalances(operatorBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_deposit_erc4626Overload() external {
        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 100e6,
            totalAssets           : 100e6,
            availableCapacity     : VAULT_CAPACITY - 100e6,
            availableLiquidAssets : int256(100e6),
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 100e6,
            shares        : 100e6,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        // deposit(assets, receiver) uses msg.sender as the controller
        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPRIME));
        emit IERC4626Like.Deposit(user, user, 100e6, 100e6);

        vm.prank(user);
        uint256 shares = spPRIME.deposit(100e6, user);

        assertEq(shares, 100e6);

        depositState.claimableDepositRequest = 0;
        depositState.maxDeposit              = 0;
        depositState.maxMint                 = 0;
        depositState.claimableDepositTotal   = 0;

        userBalances.shares = 100e6;

        spPrimeBalances.shares = 0;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_deposit_withReferral() external {
        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 100e6,
            totalAssets           : 100e6,
            availableCapacity     : VAULT_CAPACITY - 100e6,
            availableLiquidAssets : int256(100e6),
            index                 : RAY,
            lastAccrual           : block.timestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 100e6,
            shares        : 100e6,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        vm.expectEmit(address(spPRIME));
        emit ISparkPrimeVault.ReferralCode(user, 1);
        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPRIME));
        emit IERC4626Like.Deposit(user, user, 100e6, 100e6);

        vm.prank(user);
        uint256 shares = spPRIME.deposit(100e6, user, user, 1);

        assertEq(shares, 100e6);

        depositState.claimableDepositRequest = 0;
        depositState.maxDeposit              = 0;
        depositState.maxMint                 = 0;
        depositState.claimableDepositTotal   = 0;

        userBalances.shares = 100e6;

        spPrimeBalances.shares = 0;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

    function test_deposit_afterProcessQueue() external {
        // TODO
    }

    function test_deposit_combinedInstantAndQueuedFill() external {
        // TODO
    }

    function test_deposit_afterInterestAccrual() external {
        uint256 requestTimestamp = block.timestamp;

        _requestDeposit(user, 100e6);  // Instant claim, 100e6 shares at index 1

        assertEq(spPRIME.convertToAssets(100e6), 100e6);

        skip(365 days);

        uint256 expectedIndex = spPRIME.previewIndex();

        // 10% APY over one year
        assertApproxEqRel(expectedIndex, 1.1e27, 0.0001e18);

        AssertVaultStateParams memory vaultState = AssertVaultStateParams({
            totalSupply           : 100e6,
            totalAssets           : 100e6 * expectedIndex / RAY,
            availableCapacity     : VAULT_CAPACITY - 100e6,
            availableLiquidAssets : int256(100e6),
            index                 : RAY,
            lastAccrual           : requestTimestamp
        });

        AssertDepositStateParams memory depositState = AssertDepositStateParams({
            controller              : user,
            claimableDepositRequest : 100e6,
            maxDeposit              : 100e6,
            maxMint                 : 100e6,
            claimableDepositTotal   : 100e6,
            pendingDepositRequest   : 0,
            totalPendingDeposits    : 0,
            depositQueueLength      : 0,
            requestNonce            : 1
        });

        AssertBalancesParams memory userBalances = AssertBalancesParams({
            account       : user,
            asset         : 0,
            shares        : 0,
            savingsShares : 0
        });

        AssertBalancesParams memory spPrimeBalances = AssertBalancesParams({
            account       : address(spPRIME),
            asset         : 100e6,
            shares        : 100e6,
            savingsShares : 0
        });

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);

        vm.expectEmit(address(spPRIME));
        emit IVault.AccruedInterest(expectedIndex, block.timestamp);
        vm.expectEmit(address(spPRIME));
        emit IQueue.ClaimableDeposit(user, 0);
        vm.expectEmit(address(spPRIME));
        emit IERC4626Like.Deposit(user, user, 100e6, 100e6);

        vm.prank(user);
        uint256 shares = spPRIME.deposit(100e6, user, user);

        // Share count is fixed at request time, the shares gained value while escrowed
        assertEq(shares, 100e6);

        assertEq(spPRIME.convertToAssets(100e6), 109.999999e6);

        vaultState.index       = expectedIndex;
        vaultState.lastAccrual = block.timestamp;

        depositState.claimableDepositRequest = 0;
        depositState.maxDeposit              = 0;
        depositState.maxMint                 = 0;
        depositState.claimableDepositTotal   = 0;

        userBalances.shares = 100e6;

        spPrimeBalances.shares = 0;

        _assertVaultState(vaultState);
        _assertDepositState(depositState);
        _assertBalances(userBalances);
        _assertBalances(spPrimeBalances);
    }

}
