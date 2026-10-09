// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";

interface IGraduatedCurve {
    function graduated() external view returns (bool);
}

/// @notice Per-market ETH fee accounting across curve and canonical V4 pool.
/// @dev V4 native ETH claims are redeemed before payouts; no launch-token fee custody.
contract XTOFeeAccounting is IUnlockCallback {
    uint256 public constant BASE_BPS = 100;
    uint256 public constant CREATOR_BASE_BPS = 70;
    uint256 public constant MAX_EXTRA_BPS = 1000;
    uint256 public constant DENOMINATOR = 10_000;
    uint256 public constant PROTOCOL_PAYOUT_THRESHOLD = 0.1 ether;

    address public immutable factory;
    address public immutable protocol;
    uint256 public protocolClaimable;
    uint256 public protocolDustClaimable;
    event GraduationDustAccrued(address indexed market, uint256 amount);
    event GraduationDustDistributed(uint256 amount);
    uint256 public totalCreatorLiability;
    uint256 private locked;
    IPoolManager public v4Manager;
    address public v4Hook;
    uint256 public unredeemedV4Fees;
    uint256 private redeeming;
    event V4Configured(address indexed manager, address indexed hook);
    event V4FeesRedeemed(uint256 amount);
    event V4RedeemStarted(uint256 amount);

    struct Market {
        address feeRecipient;
        uint16 extraBps;
        bool registered;
        uint256 creatorClaimable;
    }
    mapping(address => Market) public markets;

    error Unauthorized();
    error InvalidAddress();
    error InvalidFee();
    error AlreadyRegistered();
    error NotRegistered();
    error InvalidDeposit();
    error NothingToClaim();
    error TransferFailed();
    error Reentrancy();

    event MarketRegistered(address indexed market, address indexed creator, uint16 extraBps);
    event FeeAccrued(address indexed market, uint256 creatorWei, uint256 protocolWei);
    event CreatorFeeRecipientChanged(address indexed market, address indexed previous, address indexed next);
    event CreatorFeeClaimed(address indexed market, address indexed recipient, uint256 amount);
    event ProtocolFeeClaimed(uint256 amount);
    event ProtocolFeeDistributed(uint256 amount);

    constructor(address factory_, address protocol_) {
        if (factory_ == address(0) || protocol_ == address(0)) revert InvalidAddress();
        factory = factory_;
        protocol = protocol_;
    }

    modifier nonReentrant() {
        if (locked != 0) revert Reentrancy();
        locked = 1;
        _;
        locked = 0;
    }

    function registerMarket(address market, address creator, uint16 extraBps) external {
        if (msg.sender != factory) revert Unauthorized();
        if (market == address(0) || creator == address(0)) revert InvalidAddress();
        if (extraBps > MAX_EXTRA_BPS) revert InvalidFee();
        if (markets[market].registered) revert AlreadyRegistered();
        markets[market] = Market(creator, extraBps, true, 0);
        emit MarketRegistered(market, creator, extraBps);
    }

    /// @notice Called by market with exact ETH fee amount, based on trade amount before fees.
    /// @dev Caller must prove a real trade occurred; registration alone does not establish that.
    function accrue(uint256 grossEthAmount) external payable nonReentrant {
        _accrue(msg.sender, grossEthAmount, msg.value);
    }

    /// @dev Factory constructor only in XTOFactoryV4; no runtime factory setter exists.
    function configureV4(address manager, address hook) external {
        if (msg.sender != factory) revert Unauthorized();
        if (v4Hook != address(0)) revert AlreadyRegistered();
        if (manager == address(0) || hook == address(0) || manager.code.length == 0 || hook.code.length == 0) revert InvalidAddress();
        v4Manager = IPoolManager(manager);
        // Transient sentinel or already-emitted configuration. Detector does not associate the adjacent configuration event.
        // forge-lint: disable-next-line(missing-events-access-control)
        v4Hook = hook;
        emit V4Configured(manager, v4Hook);
    }

    function accrueV4(address market, uint256 grossEthAmount) external nonReentrant {
        if (msg.sender != v4Hook || v4Hook == address(0)) revert Unauthorized();
        Market storage m = markets[market];
        uint256 fee = grossEthAmount * BASE_BPS / DENOMINATOR + grossEthAmount * m.extraBps / DENOMINATOR;
        if (v4Manager.balanceOf(address(this), 0) < unredeemedV4Fees + fee) revert InvalidDeposit();
        unredeemedV4Fees += fee;
        _accrue(market, grossEthAmount, fee);
    }

    function _accrue(address market, uint256 grossEthAmount, uint256 paid) private {
        Market storage m = markets[market];
        if (!m.registered) revert NotRegistered();
        if (grossEthAmount == 0) revert InvalidDeposit();
        uint256 baseFee = grossEthAmount * BASE_BPS / DENOMINATOR;
        uint256 extraFee = grossEthAmount * m.extraBps / DENOMINATOR;
        uint256 expected = baseFee + extraFee;
        if (expected == 0 || paid != expected) revert InvalidDeposit();
        // 30% of the 1% base fee. Parentheses keep the multiply-before-divide order explicit.
        // Expression is multiply-then-divide of the 30% protocol share; parentheses do not divide first.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 protocolPart = (baseFee * (BASE_BPS - CREATOR_BASE_BPS)) / BASE_BPS;
        uint256 creatorPart = expected - protocolPart;
        m.creatorClaimable += creatorPart;
        totalCreatorLiability += creatorPart;
        protocolClaimable += protocolPart;
        emit FeeAccrued(market, creatorPart, protocolPart);
    }

    /// @notice Anyone may convert recorded V4 ETH claims into native ETH after manager relocks.
    function settleV4Fees() external nonReentrant {
        _redeemV4Fees();
    }

    function _redeemV4Fees() private {
        uint256 amount = unredeemedV4Fees;
        if (amount == 0) return;
        uint256 beforeBalance = address(this).balance;
        uint256 beforeClaims = v4Manager.balanceOf(address(this), 0);
        // Transient sentinel or already-emitted configuration. Detector does not associate the adjacent configuration event.
        // forge-lint: disable-next-line(missing-events-access-control)
        redeeming = amount;
        unredeemedV4Fees = 0;
        emit V4RedeemStarted(amount);
        // Balance is checked after unlockCallback returns, and receive() accepts ETH only from PoolManager during the redeem sentinel. External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-balance, reentrancy-no-eth)
        bytes memory redeemed = v4Manager.unlock(abi.encode(amount));
        if (redeemed.length != 0) revert InvalidDeposit();
        if (
            // Equality is an exact settlement invariant: redeemed claim id 0 must match the recorded fee amount.
            // forge-lint: disable-next-line(incorrect-strict-equality)
            redeeming != 0 || address(this).balance != beforeBalance + amount
                // Equality is an exact settlement invariant: redeemed claim id 0 must match the recorded fee amount.
                // forge-lint: disable-next-line(incorrect-strict-equality)
                || v4Manager.balanceOf(address(this), 0) != beforeClaims - amount
        ) revert InvalidDeposit();
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit V4FeesRedeemed(amount);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        uint256 amount = redeeming;
        if (
            msg.sender != address(v4Manager) || amount == 0 || locked == 0
                || keccak256(data) != keccak256(abi.encode(amount))
        ) revert Unauthorized();
        // A separate sentinel authorizes receive only during PoolManager.take.
        redeeming = type(uint256).max;
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        v4Manager.burn(address(this), 0, amount);
        // External call is inside a nonReentrant function or PoolManager callback guard; storage is updated before the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        v4Manager.take(Currency.wrap(address(0)), address(this), amount);
        redeeming = 0;
        return "";
    }

    /// @notice Total backing: native ETH plus recorded, redeemable V4 native ETH claims.
    function backingAssets() external view returns (uint256) {
        return address(this).balance + unredeemedV4Fees;
    }

    /// @notice Graduation remainder belongs only to protocol, never creator fee revenue.
    function accrueGraduationDust() external payable nonReentrant {
        if (!markets[msg.sender].registered || !IGraduatedCurve(msg.sender).graduated()) revert Unauthorized();
        if (msg.value == 0) revert InvalidDeposit();
        protocolDustClaimable += msg.value;
        emit GraduationDustAccrued(msg.sender, msg.value);
        uint256 amount = protocolDustClaimable;
        protocolDustClaimable = 0;
        bool ok = _callLimited(protocol, amount, 50_000);
        // Configuration event is emitted in the same function; detector did not associate it.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        if (!ok) protocolDustClaimable = amount;
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        else emit GraduationDustDistributed(amount);
    }

    function rotateRecipient(address market, address next) external {
        Market storage m = markets[market];
        if (!m.registered) revert NotRegistered();
        if (msg.sender != m.feeRecipient) revert Unauthorized();
        if (next == address(0)) revert InvalidAddress();
        address previous = m.feeRecipient;
        m.feeRecipient = next;
        emit CreatorFeeRecipientChanged(market, previous, next);
    }

    function claimCreator(address market) external nonReentrant {
        Market storage m = markets[market];
        if (!m.registered) revert NotRegistered();
        if (msg.sender != m.feeRecipient) revert Unauthorized();
        uint256 amount = m.creatorClaimable;
        if (amount == 0) revert NothingToClaim();
        _redeemV4Fees();
        m.creatorClaimable = 0;
        totalCreatorLiability -= amount;
        // State is committed before the payout and the nonReentrant/callback guard rejects reentry.
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit CreatorFeeClaimed(market, msg.sender, amount);
    }

    function claimProtocol() external nonReentrant {
        if (msg.sender != protocol) revert Unauthorized();
        uint256 amount = protocolClaimable + protocolDustClaimable;
        if (amount == 0) revert NothingToClaim();
        _redeemV4Fees();
        protocolClaimable = 0;
        protocolDustClaimable = 0;
        // State is committed before the payout and the nonReentrant/callback guard rejects reentry.
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool ok,) = payable(protocol).call{value: amount}("");
        if (!ok) revert TransferFailed();
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ProtocolFeeClaimed(amount);
    }

    /// @notice Anyone may trigger payout at threshold. Failure leaves balance claimable.
    function distributeProtocol() external nonReentrant returns (bool success) {
        uint256 amount = protocolClaimable;
        if (amount < PROTOCOL_PAYOUT_THRESHOLD) return false;
        _redeemV4Fees();
        protocolClaimable = 0;
        success = _callLimited(protocol, amount, 50_000);
        if (!success) {
            protocolClaimable = amount;
            return false;
        }
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ProtocolFeeDistributed(amount);
    }

    function liabilities() external view returns (uint256) {
        return totalCreatorLiability + protocolClaimable + protocolDustClaimable;
    }

    /// @dev Gas-capped payout that does not copy returndata, so a recipient cannot return-bomb the stipend.
    function _callLimited(address to, uint256 value, uint256 gasLimit) private returns (bool ok) {
        assembly {
            ok := call(gasLimit, to, value, 0, 0, 0, 0)
        }
    }

    receive() external payable {
        if (msg.sender != address(v4Manager) || redeeming != type(uint256).max || locked == 0) revert InvalidDeposit();
    }
}
