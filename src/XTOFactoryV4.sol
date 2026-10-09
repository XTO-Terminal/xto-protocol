// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {XTOFactory} from "./XTOFactory.sol";
import {XTOGraduationExecutor} from "./XTOGraduationExecutor.sol";
import {XTOFeeHook} from "./XTOFeeHook.sol";
import {IXTOGraduationConfig} from "./interfaces/IXTOGraduationConfig.sol";
import {TickMath} from "../lib/v4-core/src/libraries/TickMath.sol";

/// @notice Immutable V4 factory wiring. Pool configuration is fixed at deployment.
/// @dev Deploy only after chain-specific configuration and integration review.
contract XTOFactoryV4 is XTOFactory {
    address public immutable graduationExecutor;
    address public immutable feeHook;
    uint24 public immutable poolFee;
    int24 public immutable poolTickSpacing;
    int24 public immutable poolTickLower;
    int24 public immutable poolTickUpper;
    error InvalidConfiguration();

    constructor(address manager, address protocol_, bytes32 hookSalt, uint24 fee, int24 spacing, int24 lower, int24 upper) XTOFactory(protocol_) {
        if (
            manager == address(0) || manager.code.length == 0 || fee > 1_000_000 || spacing <= 0 || spacing > type(int16).max || lower >= upper
                || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % spacing != 0
                || upper % spacing != 0
        ) revert InvalidConfiguration();
        graduationExecutor = address(new XTOGraduationExecutor(manager, address(this)));
        feeHook =
            address(new XTOFeeHook{salt: hookSalt}(manager, address(this), address(accounting), graduationExecutor));
        poolFee = fee;
        poolTickSpacing = spacing;
        poolTickLower = lower;
        poolTickUpper = upper;
        accounting.configureV4(manager, feeHook);
    }

    function graduationConfig() public view override returns (IXTOGraduationConfig.Config memory) {
        return IXTOGraduationConfig.Config(
            graduationExecutor, feeHook, poolFee, poolTickSpacing, poolTickLower, poolTickUpper
        );
    }
}
