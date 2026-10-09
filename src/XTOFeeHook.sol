// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "../lib/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "../lib/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../lib/v4-core/src/types/PoolId.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "../lib/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {IXTOGraduationConfig} from "./interfaces/IXTOGraduationConfig.sol";
import {XTOBondingCurve} from "./XTOBondingCurve.sol";
import {XTOFeeAccounting} from "./XTOFeeAccounting.sol";
import {XTOGraduationExecutor} from "./XTOGraduationExecutor.sol";

/// @notice ETH-denominated fees on canonical XTO V4 pools. Token transfers remain untaxed.
/// @dev No arbitrary calls, fee setters, minting of launch tokens, or LP management.
contract XTOFeeHook {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    uint160 public constant REQUIRED_FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    IPoolManager public immutable poolManager;
    IXTOGraduationConfig public immutable factory;
    XTOFeeAccounting public immutable accounting;
    address public immutable executor;
    mapping(PoolId => address) public marketOf;
    error Unauthorized();
    error InvalidAddress();
    error InvalidPool();
    error InvalidAmount();
    error FeeTooSmall();
    error PartialFill();
    event SwapFeeAccrued(PoolId indexed poolId, address indexed market, bool isBuy, uint256 grossEth, uint256 feeEth);

    constructor(address manager_, address factory_, address accounting_, address executor_) {
        if (
            manager_ == address(0) || manager_.code.length == 0 || factory_ == address(0)
                || accounting_ == address(0) || accounting_.code.length == 0
                || executor_ == address(0) || executor_.code.length == 0
        ) revert InvalidAddress();
        poolManager = IPoolManager(manager_);
        factory = IXTOGraduationConfig(factory_);
        accounting = XTOFeeAccounting(payable(accounting_));
        executor = executor_;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }
    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyManager returns (bytes4) {
        if (sender != executor) revert Unauthorized();
        IXTOGraduationConfig.Config memory c = factory.graduationConfig();
        address token = Currency.unwrap(key.currency1);
        address market = factory.curveOf(token);
        if (
            Currency.unwrap(key.currency0) != address(0) || address(key.hooks) != address(this)
                || c.hook != address(this) || c.executor != executor || key.fee != c.fee
                || key.tickSpacing != c.tickSpacing || market == address(0) || factory.tokenOf(market) != token
                || !XTOBondingCurve(payable(market)).graduated()
        ) revert InvalidPool();
        marketOf[key.toId()] = market;
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address market = _market(key);
        uint16 extra = XTOBondingCurve(payable(market)).extraFeeBps();
        uint256 amount = _amount(params.amountSpecified);
        // Currency0 (native ETH) is the specified currency in these two modes.
        if (params.zeroForOne && params.amountSpecified < 0) {
            uint256 fee = feeForGross(amount, extra);
            _accrue(key.toId(), market, true, amount, fee);
            // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
        }
        if (!params.zeroForOne && params.amountSpecified > 0) {
            uint256 gross = grossForNet(amount, extra);
            uint256 fee = gross - amount;
            _accrue(key.toId(), market, false, gross, fee);
            // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        returns (bytes4, int128)
    {
        address market = _market(key);
        uint16 extra = XTOBondingCurve(payable(market)).extraFeeBps();
        uint256 amount = _amount(params.amountSpecified);
        if (params.zeroForOne) {
            if (delta.amount0() >= 0 || delta.amount1() <= 0) revert InvalidAmount();
            // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 netEth = uint256(-int256(delta.amount0()));
            if (params.amountSpecified < 0) {
                // Before-swap specified fee cannot be changed after a partial fill.
                // Revert atomically rather than charge tax on unspent input.
                if (netEth != amount - feeForGross(amount, extra)) revert PartialFill();
                return (IHooks.afterSwap.selector, 0);
            }
            uint256 gross = grossForNet(netEth, extra);
            uint256 fee = gross - netEth;
            _accrue(key.toId(), market, true, gross, fee);
            // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (IHooks.afterSwap.selector, int128(uint128(fee)));
        }
        if (delta.amount0() <= 0 || delta.amount1() >= 0) revert InvalidAmount();
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 grossEth = uint256(int256(delta.amount0()));
        if (params.amountSpecified > 0) {
            if (grossEth != grossForNet(amount, extra)) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 sellFee = feeForGross(grossEth, extra);
        _accrue(key.toId(), market, false, grossEth, sellFee);
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (IHooks.afterSwap.selector, int128(uint128(sellFee)));
    }

    function _market(PoolKey calldata key) private view returns (address market) {
        market = marketOf[key.toId()];
        if (market == address(0)) revert InvalidPool();
        (PoolId poolId, uint128 liquidity, uint256 ethUsed, uint256 tokenUsed) =
            XTOGraduationExecutor(executor).positions(market);
        if (
            PoolId.unwrap(poolId) == bytes32(0) || liquidity == 0 || ethUsed == 0 || tokenUsed == 0
                || !XTOBondingCurve(payable(market)).graduated()
        ) revert InvalidPool();
    }

    function _accrue(PoolId id, address market, bool buy, uint256 gross, uint256 fee) private {
        if (fee == 0) revert FeeTooSmall();
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (gross > uint256(uint128(type(int128).max)) || fee > uint256(uint128(type(int128).max))) {
            revert InvalidAmount();
        }
        // Claim id 0 is native ETH, never the launch token. Hook delta nets this mint debt.
        poolManager.mint(address(accounting), 0, fee);
        accounting.accrueV4(market, gross);
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit SwapFeeAccrued(id, market, buy, gross, fee);
    }

    function _amount(int256 specified) private pure returns (uint256 amount) {
        if (specified == type(int256).min || specified == 0) revert InvalidAmount();
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = uint256(specified < 0 ? -specified : specified);
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount > uint256(uint128(type(int128).max))) revert InvalidAmount();
    }

    function feeForGross(uint256 gross, uint16 extra) public pure returns (uint256) {
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (extra > 1000 || gross > uint256(uint128(type(int128).max))) revert InvalidAmount();
        return _feeUnchecked(gross, extra);
    }

    function _feeUnchecked(uint256 gross, uint16 extra) private pure returns (uint256) {
        return gross * 100 / 10_000 + gross * extra / 10_000;
    }

    /// @dev Invert the two independently floored fees exactly. Their combined rounding error < 2 wei.
    function grossForNet(uint256 net, uint16 extra) public pure returns (uint256) {
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (net == 0 || extra > 1000 || net > uint256(uint128(type(int128).max))) revert InvalidAmount();
        uint256 high = FullMath.mulDivRoundingUp(net, 10_000, 9900 - extra);
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (high > uint256(uint128(type(int128).max))) revert InvalidAmount();
        uint256 low = high > 3 ? high - 3 : 0;
        for (uint256 gross = low; gross <= high; ++gross) {
            if (gross - _feeUnchecked(gross, extra) == net) return gross;
        }
        revert InvalidAmount();
    }
}
