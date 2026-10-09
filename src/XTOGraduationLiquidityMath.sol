// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "../lib/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "../lib/v4-core/src/libraries/SqrtPriceMath.sol";

library XTOGraduationLiquidityMath {
    uint256 internal constant Q96 = 1 << 96;

    error InvalidPriceRange();
    error InsufficientReserves();
    error LiquidityOverflow();

    function liquidityForReserves(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint256 ethAvailable,
        uint256 tokenAvailable
    ) internal pure returns (uint128 liquidity) {
        if (
            sqrtLowerX96 >= sqrtPriceX96 ||
            sqrtPriceX96 >= sqrtUpperX96
        ) revert InvalidPriceRange();

        if (ethAvailable == 0 || tokenAvailable == 0) {
            revert InsufficientReserves();
        }

        uint256 liquidityFromEth = FullMath.mulDiv(
            ethAvailable,
            FullMath.mulDiv(
                uint256(sqrtPriceX96),
                uint256(sqrtUpperX96),
                Q96
            ),
            uint256(sqrtUpperX96) - uint256(sqrtPriceX96)
        );

        uint256 liquidityFromToken = FullMath.mulDiv(
            tokenAvailable,
            Q96,
            uint256(sqrtPriceX96) - uint256(sqrtLowerX96)
        );

        uint256 candidate = liquidityFromEth < liquidityFromToken
            ? liquidityFromEth
            : liquidityFromToken;

        if (candidate == 0) revert InsufficientReserves();
        if (candidate > ((uint256(1) << 127) - 1)) {
            revert LiquidityOverflow();
        }

        // candidate is positive and <= int128.max, hence representable as uint128.
        // Cast follows an explicit range check or converts a V4 int128 delta whose sign was checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        liquidity = uint128(candidate);

        // Verify actual V4 amounts with rounding-up semantics.
        uint256 ethRequired = SqrtPriceMath.getAmount0Delta(
            sqrtPriceX96,
            sqrtUpperX96,
            liquidity,
            true
        );

        uint256 tokenRequired = SqrtPriceMath.getAmount1Delta(
            sqrtLowerX96,
            sqrtPriceX96,
            liquidity,
            true
        );

        if (
            ethRequired > ethAvailable ||
            tokenRequired > tokenAvailable
        ) revert InsufficientReserves();
    }
}
