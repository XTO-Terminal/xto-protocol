// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../lib/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "../lib/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "../lib/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "../lib/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "../lib/v4-core/src/libraries/Position.sol";
import {FixedPointMathLib} from "../lib/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {IXTOGraduationConfig} from "./interfaces/IXTOGraduationConfig.sol";
import {IXTOGraduationExecutor} from "./interfaces/IXTOGraduationExecutor.sol";
import {XTOGraduationLiquidityMath} from "./XTOGraduationLiquidityMath.sol";
import {XTOBondingCurve} from "./XTOBondingCurve.sol";
import {XTOToken} from "./XTOToken.sol";

/// @notice Atomic V4 settlement with permanently executor-owned liquidity.
/// @dev No remove-liquidity, claim, arbitrary-call or withdrawal entrypoint.
///      Default factory is disabled pending the production FeeHook integration.
contract XTOGraduationExecutor is IUnlockCallback, IXTOGraduationExecutor {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    IPoolManager public immutable poolManager;
    address public immutable factory;

    struct Session {
        address curve;
        PoolKey key;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 ethBudget;
        uint256 tokenBudget;
        uint256 ethUsed;
        uint256 tokenUsed;
        bool callbackPending;
    }
    Session private session;
    mapping(address => Result) public positions;
    error Unauthorized();
    error ZeroAddress();
    error Reentrancy();
    error InvalidConfiguration();
    error InvalidPrice();
    error InvalidFunding();
    error UnexpectedDelta();
    error TransferFailed();
    error SettlementIncomplete();
    error AlreadyExecuted();

    constructor(address poolManager_, address factory_) {
        if (poolManager_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        factory = factory_;
    }

    function execute(uint256 tokenBudget) external payable override returns (Result memory result) {
        if (session.curve != address(0)) revert Reentrancy();
        IXTOGraduationConfig f = IXTOGraduationConfig(factory);
        address token = f.tokenOf(msg.sender);
        if (token == address(0) || f.curveOf(token) != msg.sender) revert Unauthorized();
        XTOBondingCurve curve = XTOBondingCurve(payable(msg.sender));
        if (curve.factory() != factory || curve.token() != token || !curve.graduated()) revert Unauthorized();
        if (positions[msg.sender].liquidity != 0) revert AlreadyExecuted();
        if (msg.value < curve.graduationTarget() || tokenBudget == 0 || tokenBudget != curve.tokenReserve()) {
            revert InvalidFunding();
        }
        IXTOGraduationConfig.Config memory c = f.graduationConfig();
        if (
            c.executor != address(this) || c.hook == address(0) || c.hook.code.length == 0
                || address(poolManager).code.length == 0 || c.tickSpacing <= 0 || c.tickLower >= c.tickUpper
                || c.tickLower < TickMath.MIN_TICK || c.tickUpper > TickMath.MAX_TICK
                || c.tickLower % c.tickSpacing != 0 || c.tickUpper % c.tickSpacing != 0
        ) revert InvalidConfiguration();
        uint160 price = graduationPrice(msg.value, tokenBudget);
        uint128 liquidity = XTOGraduationLiquidityMath.liquidityForReserves(
            price,
            TickMath.getSqrtPriceAtTick(c.tickLower),
            TickMath.getSqrtPriceAtTick(c.tickUpper),
            msg.value,
            tokenBudget
        );
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(token), c.fee, c.tickSpacing, IHooks(c.hook));
        // Transient sentinel or already-emitted configuration. Detector does not associate the adjacent configuration event.
        // forge-lint: disable-next-line(missing-events-access-control)
        session = Session(msg.sender, key, c.tickLower, c.tickUpper, liquidity, msg.value, tokenBudget, 0, 0, true);
        // Never adopt an existing pool with a potentially manipulated price or position.
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        int24 openedTick = poolManager.initialize(key, price);
        if (openedTick < c.tickLower || openedTick >= c.tickUpper) revert InvalidPrice();
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        bytes memory unlocked = poolManager.unlock(abi.encode(msg.sender));
        if (unlocked.length != 0) revert SettlementIncomplete();
        if (session.callbackPending) revert SettlementIncomplete();
        result = Result(key.toId(), liquidity, session.ethUsed, session.tokenUsed);
        bytes32 positionKey = Position.calculatePositionKey(address(this), c.tickLower, c.tickUpper, salt(msg.sender));
        if (StateLibrary.getPositionLiquidity(poolManager, result.poolId, positionKey) != liquidity) {
            revert SettlementIncomplete();
        }
        positions[msg.sender] = result;
        uint256 refund = msg.value - result.ethUsed;
        if (refund != 0) {
            // State is committed before the payout and the nonReentrant/callback guard rejects reentry.
            // forge-lint: disable-next-line(reentrancy-eth)
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
        delete session;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager) || session.curve == address(0) || !session.callbackPending) {
            revert Unauthorized();
        }
        if (keccak256(data) != keccak256(abi.encode(session.curve))) revert Unauthorized();
        // Transient sentinel or already-emitted configuration. Detector does not associate the adjacent configuration event.
        // forge-lint: disable-next-line(missing-events-access-control)
        session.callbackPending = false;
        ModifyLiquidityParams memory params = ModifyLiquidityParams(
            session.lower, session.upper, int256(uint256(session.liquidity)), salt(session.curve)
        );
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(session.key, params, "");
        if (delta.amount0() >= 0 || delta.amount1() >= 0 || BalanceDelta.unwrap(fees) != 0) revert UnexpectedDelta();
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ethUsed = uint256(-int256(delta.amount0()));
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 tokenUsed = uint256(-int256(delta.amount1()));
        if (ethUsed > session.ethBudget || tokenUsed > session.tokenBudget) revert InvalidFunding();
        session.ethUsed = ethUsed;
        session.tokenUsed = tokenUsed;
        poolManager.sync(session.key.currency0);
        if (poolManager.settle{value: ethUsed}() != ethUsed) revert SettlementIncomplete();
        poolManager.sync(session.key.currency1);
        // Token is sent only to PoolManager for V4 settlement of a callback-authenticated trade or graduation.
        // forge-lint: disable-start(arbitrary-send-erc20)
        if (!XTOToken(Currency.unwrap(session.key.currency1))
                .transferFrom(session.curve, address(poolManager), tokenUsed)) revert TransferFailed();
        // forge-lint: disable-end(arbitrary-send-erc20)
        if (poolManager.settle() != tokenUsed) revert SettlementIncomplete();
        return "";
    }

    function salt(address curve) public pure returns (bytes32) {
        return keccak256(abi.encode(curve));
    }

    function graduationPrice(uint256 ethReserve, uint256 tokenReserve) public pure returns (uint160) {
        if (ethReserve == 0 || tokenReserve == 0) revert InvalidPrice();
        uint256 ratio = FullMath.mulDiv(tokenReserve, uint256(1) << 128, 1 ether + ethReserve);
        uint256 root = FixedPointMathLib.sqrt(ratio);
        if (root > type(uint160).max >> 32) revert InvalidPrice();
        uint256 price = root << 32;
        if (price < TickMath.MIN_SQRT_PRICE || price >= TickMath.MAX_SQRT_PRICE) revert InvalidPrice();
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(price);
    }
}
