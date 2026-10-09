// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IXTOGraduationConfig {
    struct Config {
        address executor;
        address hook;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
    }
    function graduationConfig() external view returns (Config memory);
    function curveOf(address token) external view returns (address);
    function tokenOf(address curve) external view returns (address);
}
