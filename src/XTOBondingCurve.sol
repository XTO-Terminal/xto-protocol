// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "../lib/v4-core/src/types/PoolId.sol";
import {IXTOGraduationConfig} from "./interfaces/IXTOGraduationConfig.sol";
import {IXTOGraduationExecutor} from "./interfaces/IXTOGraduationExecutor.sol";

import {XTOToken} from "./XTOToken.sol";
import {XTOFeeAccounting} from "./XTOFeeAccounting.sol";

/// @notice Phase 04C prototype: net-reserve pricing and ETH fee escrow.
/// @dev Settlement integrated; default factory remains closed pending production FeeHook.
contract XTOBondingCurve {
    uint256 public constant VIRTUAL_ETH = 1 ether;
    uint256 private constant BPS = 10_000;
    uint256 private constant BASE_FEE_BPS = 100;
    /// @notice Creator curve buys cannot exceed 5% of the 1,000,000,000 initial supply.
    uint256 public constant CREATOR_BUY_CAP = 50_000_000 * 1e18;
    address public immutable factory;
    address public token;
    address public creator;
    uint256 public creatorTokensBought;
    address public accounting;
    uint16 public extraFeeBps;
    bool public initialized;
    bool public accountingConfigured;
    uint256 public realEthReserve;
    uint256 public graduationTarget;
    bool public graduationConfigured;
    bool public graduated;
    uint256 private entered;
    address private activeGraduationExecutor;

    error Unauthorized();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroAmount();
    error Slippage();
    error InsufficientRealReserve();
    error TransferFailed();
    error Reentrancy();
    error NotInitialized();
    error AccountingNotConfigured();
    error InvalidFee();
    error FeeTooSmall();
    error InvalidGraduationTarget();
    error GraduationNotReady();
    error AlreadyGraduated();
    error GraduationDisabled();
    error InvalidSettlement();
    error CreatorAlreadySet();
    error CreatorBuyCapExceeded();

    event MarketInitialized(address indexed token);
    event CreatorConfigured(address indexed creator);
    event AccountingConfigured(address indexed accounting, uint16 extraFeeBps);
    event GraduationConfigured(uint256 target);

    event GraduationCompleted(
        address indexed token,
        address indexed executor,
        bytes32 indexed poolId,
        uint256 ethUsed,
        uint256 tokenUsed,
        uint128 liquidity,
        uint256 tokensBurned,
        uint256 remainingSupply,
        uint256 ethRemainder
    );

    event TokenBought(address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 realEthReserve);
    event TokenSold(address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 realEthReserve);
    event TradeFees(address indexed trader, bool indexed isBuy, uint256 grossEth, uint256 feeEth);

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    modifier nonReentrant() {
        if (entered != 0) revert Reentrancy();
        entered = 1;
        _;
        entered = 0;
    }

    function initialize(address token_) external {
        if (msg.sender != factory) revert Unauthorized();
        if (initialized) revert AlreadyInitialized();
        if (token_ == address(0)) revert ZeroAddress();
        initialized = true;
        token = token_;
        emit MarketInitialized(token_);
    }

    /// @notice Factory records the market creator once. Cap applies only to that wallet's curve buys.
    function setCreator(address creator_) external {
        if (msg.sender != factory) revert Unauthorized();
        if (!initialized) revert NotInitialized();
        if (creator != address(0)) revert CreatorAlreadySet();
        if (creator_ == address(0)) revert ZeroAddress();
        creator = creator_;
        emit CreatorConfigured(creator_);
    }

    function configureAccounting(address accounting_, uint16 extraBps_) external {
        if (msg.sender != factory) revert Unauthorized();
        if (!initialized) revert NotInitialized();
        if (accountingConfigured) revert AlreadyInitialized();
        if (accounting_ == address(0) || accounting_.code.length == 0) revert ZeroAddress();
        if (extraBps_ > 1000) revert InvalidFee();
        accounting = accounting_;
        extraFeeBps = extraBps_;
        accountingConfigured = true;
        emit AccountingConfigured(accounting_, extraBps_);
    }

    function configureGraduation(uint256 target_) external {
        if (msg.sender != factory) revert Unauthorized();
        if (!initialized) revert NotInitialized();
        if (graduationConfigured) revert AlreadyInitialized();
        if (target_ < 0.001 ether) revert InvalidGraduationTarget();

        graduationTarget = target_;
        graduationConfigured = true;
        emit GraduationConfigured(target_);
    }

    function graduationReady() public view returns (bool) {
        return !graduated && graduationConfigured && realEthReserve >= graduationTarget;
    }

    function requireGraduationReady() external view {
        if (!graduationReady()) revert GraduationNotReady();
    }

    function graduationProgressBps() external view returns (uint256) {
        if (!graduationConfigured) return 0;
        uint256 progress = realEthReserve * 10_000 / graduationTarget;
        return progress > 10_000 ? 10_000 : progress;
    }

    function tokenReserve() public view returns (uint256) {
        if (!initialized) revert NotInitialized();
        return XTOToken(token).balanceOf(address(this));
    }

    function _fee(uint256 gross) internal view returns (uint256) {
        return (gross * BASE_FEE_BPS / BPS) + (gross * extraFeeBps / BPS);
    }

    function quoteBuy(uint256 grossEthIn) public view returns (uint256 tokensOut) {
        if (grossEthIn == 0) return 0;
        uint256 fee = _fee(grossEthIn);
        if (fee == 0) return 0;
        uint256 net = grossEthIn - fee;
        uint256 reserve = tokenReserve();
        tokensOut = reserve * net / (VIRTUAL_ETH + realEthReserve + net);
    }

    function quoteSellGross(uint256 tokensIn) public view returns (uint256 grossEthOut) {
        if (tokensIn == 0) return 0;
        uint256 reserve = tokenReserve();
        grossEthOut = (VIRTUAL_ETH + realEthReserve) * tokensIn / (reserve + tokensIn);
    }

    function quoteSell(uint256 tokensIn) public view returns (uint256 netEthOut) {
        uint256 gross = quoteSellGross(tokensIn);
        uint256 fee = _fee(gross);
        if (fee == 0) return 0;
        netEthOut = gross - fee;
    }

    function buy(uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        if (graduated) revert AlreadyGraduated();
        if (!accountingConfigured) revert AccountingNotConfigured();
        if (msg.value == 0) revert ZeroAmount();
        uint256 fee = _fee(msg.value);
        if (fee == 0) revert FeeTooSmall();
        uint256 net = msg.value - fee;
        tokensOut = quoteBuy(msg.value);
        if (tokensOut == 0 || tokensOut < minTokensOut) revert Slippage();
        if (msg.sender == creator) {
            uint256 nextBought = creatorTokensBought + tokensOut;
            if (nextBought > CREATOR_BUY_CAP) revert CreatorBuyCapExceeded();
            creatorTokensBought = nextBought;
        }
        realEthReserve += net;
        // ETH destination is the trader, immutable protocol, or factory-registered accounting; not an arbitrary withdrawer.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        XTOFeeAccounting(payable(accounting)).accrue{value: fee}(msg.value);
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        if (!XTOToken(token).transfer(msg.sender, tokensOut)) revert TransferFailed();
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit TokenBought(msg.sender, msg.value, tokensOut, realEthReserve);
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit TradeFees(msg.sender, true, msg.value, fee);
    }

    function sell(uint256 tokensIn, uint256 minEthOut) external nonReentrant returns (uint256 ethOut) {
        if (graduated) revert AlreadyGraduated();
        if (!accountingConfigured) revert AccountingNotConfigured();
        if (tokensIn == 0) revert ZeroAmount();
        uint256 gross = quoteSellGross(tokensIn);
        uint256 fee = _fee(gross);
        if (fee == 0) revert FeeTooSmall();
        ethOut = gross - fee;
        if (ethOut == 0 || ethOut < minEthOut) revert Slippage();
        if (gross > realEthReserve) revert InsufficientRealReserve();
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        if (!XTOToken(token).transferFrom(msg.sender, address(this), tokensIn)) revert TransferFailed();
        realEthReserve -= gross;
        // ETH destination is the trader, immutable protocol, or factory-registered accounting; not an arbitrary withdrawer.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        XTOFeeAccounting(payable(accounting)).accrue{value: fee}(gross);
        // State is committed before the payout and the nonReentrant/callback guard rejects reentry.
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool ok,) = payable(msg.sender).call{value: ethOut}("");
        if (!ok) revert TransferFailed();
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit TokenSold(msg.sender, tokensIn, ethOut, realEthReserve);
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit TradeFees(msg.sender, false, gross, fee);
    }

    /// @notice Trigger the factory-defined path; caller receives no funds or LP rights.
    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (!graduationReady()) revert GraduationNotReady();
        address executor = IXTOGraduationConfig(factory).graduationConfig().executor;
        if (executor == address(0) || executor.code.length == 0) revert GraduationDisabled();
        uint256 ethBudget = realEthReserve;
        uint256 tokenBudget = tokenReserve();
        graduated = true;
        realEthReserve = 0;
        activeGraduationExecutor = executor;
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        if (!XTOToken(token).approve(executor, tokenBudget)) revert TransferFailed();
        IXTOGraduationExecutor.Result memory result =
            // ETH destination is the trader, immutable protocol, or factory-registered accounting; not an arbitrary withdrawer.
            // forge-lint: disable-next-line(arbitrary-send-eth)
            IXTOGraduationExecutor(executor).execute{value: ethBudget}(tokenBudget);
        if (
            result.ethUsed > ethBudget || result.tokenUsed > tokenBudget || result.liquidity == 0
                || realEthReserve != ethBudget - result.ethUsed || tokenReserve() != tokenBudget - result.tokenUsed
        ) revert InvalidSettlement();
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        if (!XTOToken(token).approve(executor, 0)) revert TransferFailed();
        uint256 unused = tokenReserve();
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        XTOToken(token).burnUnusedCurveTokens(unused);
        activeGraduationExecutor = address(0);
        uint256 ethRemainder = realEthReserve;
        realEthReserve = 0;
        // ETH destination is the trader, immutable protocol, or factory-registered accounting; not an arbitrary withdrawer.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (ethRemainder != 0) XTOFeeAccounting(payable(accounting)).accrueGraduationDust{value: ethRemainder}();
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-start(reentrancy-events)
        emit GraduationCompleted(
            token,
            executor,
            PoolId.unwrap(result.poolId),
            result.ethUsed,
            result.tokenUsed,
            result.liquidity,
            unused,
            XTOToken(token).totalSupply(),
            ethRemainder
        );
        // forge-lint: disable-end(reentrancy-events)
    }

    receive() external payable {
        if (msg.sender != activeGraduationExecutor || activeGraduationExecutor == address(0) || entered == 0) {
            revert Unauthorized();
        }
        realEthReserve += msg.value;
    }
}
