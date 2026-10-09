// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IXTOGraduationConfig} from "./interfaces/IXTOGraduationConfig.sol";
import {XTOToken} from "./XTOToken.sol";
import {XTOBondingCurve} from "./XTOBondingCurve.sol";
import {XTOFeeAccounting} from "./XTOFeeAccounting.sol";

/// @notice Phase 04C: each market is created and fee-registered atomically.
contract XTOFactory {
    uint256 public constant DEFAULT_GRADUATION_TARGET = 4.5 ether;
    address public immutable protocol;
    uint256 public defaultGraduationTarget = DEFAULT_GRADUATION_TARGET;
    event DefaultGraduationTargetUpdated(uint256 previousTarget, uint256 newTarget);
    error UnauthorizedProtocol();
    error InvalidProtocol();
    error InvalidGraduationTarget();
    uint256 public nextMarketId;
    mapping(address => address) public curveOf;
    mapping(address => address) public tokenOf;
    XTOFeeAccounting public immutable accounting;

    event MarketCreated(uint256 indexed marketId, address indexed token, address indexed curve, address creator);

    constructor(address protocol_) {
        if (protocol_ == address(0)) revert InvalidProtocol();
        protocol = protocol_;
        accounting = new XTOFeeAccounting(address(this), protocol_);
    }

    /// @notice Changes the target ONLY for markets created after this transaction.
    function setDefaultGraduationTarget(uint256 target_) external {
        if (msg.sender != protocol) revert UnauthorizedProtocol();
        if (target_ < 0.001 ether) revert InvalidGraduationTarget();
        uint256 previous = defaultGraduationTarget;
        defaultGraduationTarget = target_;
        emit DefaultGraduationTargetUpdated(previous, target_);
    }

    function createMarket(string calldata name_, string calldata symbol_) external returns (address token, address curve) {
        return _createMarket(name_, symbol_, 0);
    }

    function createMarket(string calldata name_, string calldata symbol_, uint16 extraBps) external returns (address token, address curve) {
        return _createMarket(name_, symbol_, extraBps);
    }

    function _createMarket(string memory name_, string memory symbol_, uint16 extraBps) internal returns (address token, address curve) {
        require(extraBps <= 1000, "EXTRA_FEE_TOO_HIGH");
        uint256 id = nextMarketId++;
        bytes32 salt = keccak256(abi.encode(block.chainid, address(this), id));
        XTOBondingCurve c = new XTOBondingCurve{salt: salt}(address(this));
        curve = address(c);
        token = address(new XTOToken(name_, symbol_, curve));
        c.initialize(token);
        c.setCreator(msg.sender);
        curveOf[token] = curve;
        tokenOf[curve] = token;
        // Event follows a guarded call. Reentry is rejected by the entered/callback guard, so logs cannot be reordered by an attacker.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MarketCreated(id, token, curve, msg.sender);
        accounting.registerMarket(curve, msg.sender, extraBps);
        c.configureAccounting(address(accounting), extraBps);
        c.configureGraduation(defaultGraduationTarget);
    }

    function graduationConfig() public view virtual returns (IXTOGraduationConfig.Config memory c) {
        return c;
    }

    function predictCurve(uint256 marketId) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(block.chainid, address(this), marketId));
        bytes32 hash = keccak256(bytes.concat(type(XTOBondingCurve).creationCode, abi.encode(address(this))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
    }
}
