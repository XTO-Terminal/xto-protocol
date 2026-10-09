// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed-supply launch token. Entire supply is minted to its dedicated curve.
/// @dev The curve may burn only tokens it itself owns, and only once during graduation.
contract XTOToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public totalSupply;
    address public immutable curve;
    bool public graduationBurnExecuted;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroAddress();
    error Unauthorized();
    error BurnAlreadyExecuted();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(string memory name_, string memory symbol_, address curve_) {
        if (curve_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        curve = curve_;
        totalSupply = INITIAL_SUPPLY;
        balanceOf[curve_] = INITIAL_SUPPLY;
        emit Transfer(address(0), curve_, INITIAL_SUPPLY);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = allowed - value; }
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, value);
        return true;
    }

    /// @notice Burns the curve's own unused balance exactly once during graduation.
    /// @dev Graduation contract must ensure liquidity mint succeeds atomically before calling.
    function burnUnusedCurveTokens(uint256 value) external {
        if (msg.sender != curve) revert Unauthorized();
        if (graduationBurnExecuted) revert BurnAlreadyExecuted();
        graduationBurnExecuted = true;
        uint256 current = balanceOf[curve];
        if (current < value) revert InsufficientBalance();
        unchecked { balanceOf[curve] = current - value; totalSupply -= value; }
        emit Transfer(curve, address(0), value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 current = balanceOf[from];
        if (current < value) revert InsufficientBalance();
        unchecked { balanceOf[from] = current - value; }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
