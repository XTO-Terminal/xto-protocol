// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolId} from "../../lib/v4-core/src/types/PoolId.sol";

interface IXTOGraduationExecutor {
    struct Result {
        PoolId poolId;
        uint128 liquidity;
        uint256 ethUsed;
        uint256 tokenUsed;
    }
    function execute(uint256 tokenBudget) external payable returns (Result memory);
}
