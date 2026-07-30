// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAggregatorV3 — the read surface of a Chainlink Data Feed.
/// @notice Declared here rather than imported so this repo has no dependency
///         beyond forge-std and the pigfox pipeline. Only the three functions
///         this repo actually calls are declared; a narrower interface is a
///         smaller thing to get wrong. Two of them are called by
///         OracleHealthChecker; `description()` is called by the deployment
///         sanity script, which uses it to prove each registered feed really is
///         the pair the README claims it is.
///
/// @dev    WHAT WAS MEASURED, NOT ASSUMED. Every signature below was verified
///         against all four live aggregators on Base Sepolia (84532) before this
///         file was written — see the feed table in the README. Each answered
///         `decimals()`, `description()` and `latestRoundData()`.
///
/// @dev    ON `answeredInRound`. It is still exposed by all four aggregators, so
///         it is declared here for completeness of the tuple. It is NOT checked
///         by OracleHealthChecker, and that is a measured decision rather than an
///         oversight: on every one of the four feeds `answeredInRound` came back
///         EQUAL to `roundId`. The classic guard `answeredInRound < roundId` —
///         still copied into consumer code from older Chainlink documentation —
///         therefore cannot fire on these feeds. Implementing it would produce a
///         check that always passes, which is worse than no check: it reads like
///         staleness is covered when the only thing actually covering it is the
///         `updatedAt` comparison. `startedAt` was likewise equal to `updatedAt`
///         on all four.
interface IAggregatorV3 {
    /// @notice Fixed-point scale of `answer`. All four measured feeds return 8.
    function decimals() external view returns (uint8);

    /// @notice Human-readable pair name, e.g. "ETH / USD".
    function description() external view returns (string memory);

    /// @notice The most recent round this aggregator has published.
    /// @return roundId Phase-encoded: `phaseId << 64 | aggregatorRoundId`, which
    ///         is why live values sit just above 2**64.
    /// @return answer The price, scaled by `decimals()`. SIGNED — see
    ///         OracleHealthChecker's NON_POSITIVE_ANSWER state.
    /// @return startedAt When the round opened.
    /// @return updatedAt When the answer was last written. This is the field
    ///         staleness is measured from.
    /// @return answeredInRound Legacy. See the note above before using it.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
