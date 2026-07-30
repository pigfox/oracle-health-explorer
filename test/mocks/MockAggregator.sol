// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockAggregator — a Chainlink feed that can be put into any state.
///
/// @notice THIS IS THE ONLY WAY THE FAILURE STATES GET TESTED. A live aggregator
///         cannot be made stale on request, cannot be persuaded to return a
///         negative answer, and will not hand out an incomplete round because
///         somebody is writing a test. Every state this explorer exists to name
///         is reachable here and nowhere else.
///
/// @dev    Nothing here reaches a network. It is a fresh contract built from
///         source inside the in-process EVM that `forge test`, Echidna and Medusa
///         each construct, and it stands in for nothing: the LIVE feeds are read
///         live, on Base Sepolia 84532, by the deployment sanity script and by
///         the web page.
contract MockAggregator {
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint8 private _decimals;
    string private _description;

    /// @dev When true, both read functions revert. A feed whose aggregator has
    ///      been retired, or whose proxy points at nothing, behaves like this.
    bool public reverting;

    constructor(string memory description_, uint8 decimals_) {
        _description = description_;
        _decimals = decimals_;
    }

    /// @notice Put the feed into an arbitrary round state.
    /// @dev    `startedAt` is set equal to `updatedAt`, which is what all four
    ///         measured Base Sepolia feeds actually do.
    function setRound(uint80 roundId_, int256 answer_, uint256 updatedAt_) external {
        roundId = roundId_;
        answer = answer_;
        updatedAt = updatedAt_;
        startedAt = updatedAt_;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    function decimals() external view returns (uint8) {
        if (reverting) revert("MockAggregator: down");
        return _decimals;
    }

    function description() external view returns (string memory) {
        if (reverting) revert("MockAggregator: down");
        return _description;
    }

    /// @dev `answeredInRound` is returned EQUAL to `roundId`, matching what every
    ///      measured live feed does. A mock that returned something else would
    ///      let a test pass against behaviour no real feed exhibits.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert("MockAggregator: down");
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}

/// @title RevertingAggregator — a feed that always reverts, with no revert reason.
/// @dev   Separate from `MockAggregator.setReverting` on purpose: this one reverts
///        with EMPTY returndata, which is the shape a `require(false)` with no
///        message and an out-of-gas both produce. `MockAggregator` reverts with a
///        string. The checker must reach UNAVAILABLE for both, and a single mock
///        would only ever demonstrate one of them.
contract RevertingAggregator {
    fallback() external {
        revert();
    }
}

/// @title WrongShapeAggregator — a feed that answers, with the wrong ABI shape.
///
/// @notice The case that makes `try/catch` insufficient and low-level
///         `staticcall` necessary. This contract's `latestRoundData` returns ONE
///         32-byte word where the interface declares five. The call SUCCEEDS —
///         there is nothing to catch — and it is the returndata length check in
///         `_readRound` that turns it into UNAVAILABLE. Without that check,
///         `abi.decode` reverts and takes the whole page down with it.
contract WrongShapeAggregator {
    function latestRoundData() external pure returns (uint256) {
        return 1;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @title HealthyRoundDecimalsRevertAggregator — round data works, `decimals()`
///        does not.
///
/// @notice `decimals` is presentational: it scales the answer for display and no
///         verdict depends on it. So a feed like this is NOT demoted to
///         UNAVAILABLE — it gets a real health verdict from its round data, and
///         its decimals are reported as the DECIMALS_UNKNOWN sentinel. This mock
///         is what proves that split is real rather than asserted, and it reaches
///         the `!ok` half of the decimals read.
contract HealthyRoundDecimalsRevertAggregator {
    int256 private immutable ANSWER;
    uint256 private immutable UPDATED_AT;

    constructor(int256 answer_, uint256 updatedAt_) {
        ANSWER = answer_;
        UPDATED_AT = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, ANSWER, UPDATED_AT, UPDATED_AT, 1);
    }

    function decimals() external pure returns (uint8) {
        revert("no decimals here");
    }
}

/// @title HealthyRoundDecimalsWrongShapeAggregator — round data works,
///        `decimals()` answers with the wrong ABI shape.
///
/// @dev   The OTHER half of the decimals read's guard. This call SUCCEEDS, so
///        `ok` is true and only the returndata length distinguishes it: a
///        dynamic `string` return is at least 96 bytes where a `uint8` is 32.
///        Without the length check, `abi.decode(data, (uint8))` would take a
///        length it was not given.
contract HealthyRoundDecimalsWrongShapeAggregator {
    int256 private immutable ANSWER;
    uint256 private immutable UPDATED_AT;

    constructor(int256 answer_, uint256 updatedAt_) {
        ANSWER = answer_;
        UPDATED_AT = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, ANSWER, UPDATED_AT, UPDATED_AT, 1);
    }

    function decimals() external pure returns (string memory) {
        return "eight";
    }
}

/// @title TryCatchConsumer — the design decision that justifies `staticcall`,
///        made testable.
///
/// @notice `OracleHealthChecker` documents that `try/catch` is NOT sufficient for
///         reading an untrusted aggregator, because a `catch` clause does not
///         catch a failure to DECODE the returndata. That is a claim about
///         Solidity, not about this repo, and an unverified claim in a comment is
///         how a design outlives its reason. This contract reads a feed the naive
///         way so a test can demonstrate it reverting on exactly the input the
///         real checker survives.
contract TryCatchConsumer {
    /// @dev Returns the answer, or zero if the feed reverted. The point is what
    ///      it does NOT do: survive a feed that returns the wrong shape.
    function readNaively(address feed) external view returns (int256) {
        try IWrongShapeProbe(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256, uint80
        ) {
            return answer;
        } catch {
            return 0;
        }
    }
}

/// @dev The five-value interface `TryCatchConsumer` believes it is calling.
interface IWrongShapeProbe {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
