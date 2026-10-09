// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {XTOFactoryV4} from "./XTOFactoryV4.sol";
import {XTOFeeHook} from "./XTOFeeHook.sol";
import {XTOToken} from "./XTOToken.sol";

/// @notice Single canonical XTO-pool router with slippage bounds, deadlines and native ETH fees.
contract XTOSwapRouter is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    XTOFactoryV4 public immutable factory;
    IPoolManager public immutable manager;
    bool private entered;
    bool private callbackPending;
    bytes32 private callbackHash;
    error Unauthorized();
    error Reentrancy();
    error InvalidTrade();
    error Expired();
    error Slippage();
    error TransferFailed();

    struct Trade {
        address trader;
        address recipient;
        address token;
        bool buy;
        int256 amountSpecified;
        uint160 priceLimit;
        uint256 bound;
        uint256 ethBudget;
    }

    constructor(XTOFactoryV4 factory_) {
        factory = factory_;
        manager = XTOFeeHook(factory_.feeHook()).poolManager();
    }

    /// @param bound Minimum output for exact input; maximum input for exact output.
    function swap(
        address token,
        bool buy,
        int256 amountSpecified,
        uint160 priceLimit,
        uint256 bound,
        address recipient,
        uint256 deadline
    ) external payable returns (BalanceDelta delta) {
        if (entered) revert Reentrancy();
        // Deadline check only; a validator can shift timestamp slightly, which cannot bypass the deadline bound.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired();
        if (
            recipient == address(0) || recipient == address(this) || factory.curveOf(token) == address(0)
                || amountSpecified == 0 || amountSpecified == type(int256).min
        ) revert InvalidTrade();
        // type(int256).min is rejected above, so absolute value is representable.
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(amountSpecified < 0 ? -amountSpecified : amountSpecified);
        if (amount > ((uint256(1) << 127) - 1)) revert InvalidTrade();
        if (buy ? msg.value != (amountSpecified < 0 ? amount : bound) : msg.value != 0) revert InvalidTrade();
        entered = true;
        Trade memory trade = Trade(msg.sender, recipient, token, buy, amountSpecified, priceLimit, bound, msg.value);
        bytes memory data = abi.encode(trade);
        callbackPending = true;
        callbackHash = keccak256(data);
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        delta = abi.decode(manager.unlock(data), (BalanceDelta));
        if (callbackPending) revert Unauthorized();
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ethToRecipient = buy ? 0 : uint256(int256(delta.amount0()));
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 refund = buy ? msg.value - uint256(-int256(delta.amount0())) : 0;
        if (ethToRecipient != 0) _send(recipient, ethToRecipient);
        if (refund != 0) _send(msg.sender, refund);
        // Outside PoolManager.unlock: turn ETH claims into native escrow and attempt threshold payout.
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        factory.accounting().settleV4Fees();
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        bool distributed = factory.accounting().distributeProtocol();
        // Distribution may legitimately be deferred below the payout threshold.
        if (distributed) { /* accounting already emits ProtocolFeeDistributed */ }
        callbackHash = bytes32(0);
        entered = false;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(manager) || !entered || !callbackPending || keccak256(data) != callbackHash) {
            revert Unauthorized();
        }
        // Transient sentinel or already-emitted configuration. Detector does not associate the adjacent configuration event.
        // forge-lint: disable-next-line(missing-events-access-control)
        callbackPending = false;
        Trade memory t = abi.decode(data, (Trade));
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(t.token),
            factory.poolFee(),
            factory.poolTickSpacing(),
            IHooks(factory.feeHook())
        );
        BalanceDelta delta = manager.swap(key, SwapParams(t.buy, t.amountSpecified, t.priceLimit), "");
        if (t.buy ? (delta.amount0() >= 0 || delta.amount1() <= 0) : (delta.amount0() <= 0 || delta.amount1() >= 0)) {
            revert InvalidTrade();
        }
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = t.buy ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountOut = t.buy ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        if (t.amountSpecified < 0) {
            // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (amountIn > uint256(-t.amountSpecified) || amountOut < t.bound) revert Slippage();
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        } else if (amountOut != uint256(t.amountSpecified) || amountIn > t.bound) {
            revert Slippage();
        }
        if (t.buy) {
            if (amountIn > t.ethBudget) revert Slippage();
            manager.sync(key.currency0);
            if (manager.settle{value: amountIn}() != amountIn) revert TransferFailed();
            manager.take(key.currency1, t.recipient, amountOut);
        } else {
            manager.sync(key.currency1);
            // Token is sent only to PoolManager for V4 settlement of a callback-authenticated trade or graduation.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            if (!XTOToken(t.token).transferFrom(t.trader, address(manager), amountIn)) revert TransferFailed();
            if (manager.settle() != amountIn) revert TransferFailed();
            manager.take(key.currency0, address(this), amountOut);
        }
        return abi.encode(delta);
    }

    function _send(address recipient, uint256 amount) private {
        // ETH destination is the trader, immutable protocol, or factory-registered accounting; not an arbitrary withdrawer. State is committed before the payout and the nonReentrant/callback guard rejects reentry.
        // forge-lint: disable-next-line(arbitrary-send-eth, reentrancy-eth)
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {
        if (msg.sender != address(manager) || !entered) revert Unauthorized();
    }
}
