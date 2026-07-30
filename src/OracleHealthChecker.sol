// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "./IAggregatorV3.sol";
import {IOracleHealthChecker} from "./IOracleHealthChecker.sol";

/// @title OracleHealthChecker — reads Chainlink Data Feeds and says what is wrong
///        with them, if anything.
/// @author pigfox
///
/// @notice Consuming a price feed without checking it has cost real protocols
///         real money. The failure is rarely "the oracle was hacked"; it is that
///         the consumer took `latestRoundData().answer` and used it, and the
///         answer was old, or negative, or from a round that never completed.
///         This contract performs the checks a consumer should have performed,
///         and names the result.
///
/// @dev    DESIGN — three properties, in order of how much they matter.
///
///         1. THE VERDICT LOGIC IS PURE. `evaluate` takes raw round data and a
///            max age as arguments and touches no state and no feed. That is
///            what makes it exhaustively testable and fuzzable: a live feed
///            cannot be made stale, or negative, or incomplete on demand, so a
///            design that could only be exercised through a real aggregator
///            could not be verified at all. `check` is a thin wrapper that reads
///            a feed and hands the numbers to `evaluate`.
///
///         2. IT CANNOT BE BRICKED BY A BAD FEED. Every external read is a
///            low-level `staticcall` with the returndata length checked before
///            decoding. A feed that reverts, a feed that is not a contract, and
///            a feed that answers with the wrong shape all yield the UNAVAILABLE
///            verdict. None of them reverts the caller. An explorer whose whole
///            job is reporting broken feeds must not itself break on one — and
///            `try/catch` is not sufficient for this, because a returndata
///            decode failure is not caught by a `catch` clause.
///
///         3. THERE IS NO PRIVILEGED ROLE. The feed registry and each feed's max
///            age are written once by the constructor and never again. There is
///            no owner, no setter, no pause and no upgrade path. What a feed was
///            registered with is what it means for the life of the contract.
///
/// @dev    STALENESS SEMANTICS, stated exactly once and then relied on. An age
///         of exactly `maxAge` is HEALTHY; STALE begins one second later. The
///         comparison is `age > maxAge`, not `>=`. Off-by-one on this line is
///         the entire bug class, so it is fuzzed at the boundary from both
///         sides and pinned by a named unit test.
///
/// @dev    MAX AGE IS PER FEED, and that is the point rather than a convenience.
///         Measured on Base Sepolia before this contract was written: BTC/USD,
///         ETH/USD and LINK/USD republish every two to four minutes, while
///         USDC/USD moves on a ~24-hour heartbeat (86,424 s and 86,416 s across
///         two consecutive observed intervals). A single estate-wide threshold
///         tight enough for BTC would report USDC as stale for almost all of
///         every day, and one loose enough for USDC would call a BTC feed that
///         had been frozen for twenty hours healthy. Neither is a staleness
///         check. The heartbeat is a property of the feed, so the threshold has
///         to be too.
/// @dev    The verdict states, the severity ranking they encode, and the two
///         structs live in IOracleHealthChecker — one definition of what STALE
///         means, and a surface the property harness can hold in place of this
///         contract so its own detectors can be proven to fire.
contract OracleHealthChecker is IOracleHealthChecker {
    // -------------------------------------------------------------------------
    // Constants — named, because a bare literal in a bound is a bound nobody
    // can review.
    // -------------------------------------------------------------------------

    /// @notice Upper bound on registered feeds, enforced where the registry is
    ///         built rather than left to whoever reads it.
    uint256 public constant MAX_FEEDS = 16;

    /// @notice Ceiling on a configurable max age. A threshold longer than this
    ///         is not a staleness check, so the constructor rejects it rather
    ///         than deploying a contract that always reports HEALTHY.
    uint256 public constant MAX_CONFIGURABLE_MAX_AGE = 30 days;

    /// @dev Exact ABI length of `latestRoundData()`'s five static return values.
    ///      Checked before decoding: `abi.decode` on short returndata reverts,
    ///      and this contract promises not to.
    uint256 private constant ROUND_DATA_RETURN_LENGTH = 160;

    /// @dev Exact ABI length of `decimals()`'s single static return value.
    uint256 private constant DECIMALS_RETURN_LENGTH = 32;

    /// @dev Reported for `decimals` when a feed does not answer that call
    ///      usefully. Zero is not a plausible real scale — all four measured
    ///      feeds return 8 — so it reads as "did not answer" rather than as a
    ///      value to compute with.
    uint8 private constant DECIMALS_UNKNOWN = 0;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice A checker with no feeds has nothing to report.
    error NoFeeds();
    /// @notice More feeds than `MAX_FEEDS`.
    error TooManyFeeds(uint256 given, uint256 max);
    /// @notice The zero address cannot be a feed.
    error ZeroFeedAddress(uint256 index);
    /// @notice A zero max age would make every feed permanently STALE.
    error ZeroMaxAge(uint256 index);
    /// @notice A max age above `MAX_CONFIGURABLE_MAX_AGE`.
    error MaxAgeTooLarge(uint256 index, uint256 given, uint256 max);
    /// @notice The same feed twice — its max age would be ambiguous.
    error DuplicateFeed(uint256 index, address feed);
    /// @notice No feed is registered at that index.
    error NoSuchFeed(uint256 index, uint256 feedCount);

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @dev Written once, by the constructor, and never again. Solidity cannot
    ///      mark a dynamic array `immutable`, so the guarantee is structural
    ///      instead: this is the only declaration, and no function in this
    ///      contract other than the constructor writes to it. There is no
    ///      setter to find because there is no setter.
    FeedConfig[] private _feeds;

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// @notice Register the feeds and their per-feed max ages, permanently.
    /// @param configs Feeds to watch. Rejected: empty, over `MAX_FEEDS`, a zero
    ///        address, a zero max age, a max age over the ceiling, or the same
    ///        feed twice. Every one of those would produce a checker that
    ///        reports something untrue, so none of them is allowed to deploy.
    constructor(FeedConfig[] memory configs) {
        uint256 count = configs.length;
        if (count == 0) revert NoFeeds();
        if (count > MAX_FEEDS) revert TooManyFeeds(count, MAX_FEEDS);

        for (uint256 i = 0; i < count; ++i) {
            FeedConfig memory config = configs[i];
            if (config.feed == address(0)) revert ZeroFeedAddress(i);
            if (config.maxAge == 0) revert ZeroMaxAge(i);
            if (config.maxAge > MAX_CONFIGURABLE_MAX_AGE) {
                revert MaxAgeTooLarge(i, config.maxAge, MAX_CONFIGURABLE_MAX_AGE);
            }
            for (uint256 j = 0; j < i; ++j) {
                if (configs[j].feed == config.feed) revert DuplicateFeed(i, config.feed);
            }
            _feeds.push(config);
        }
    }

    // -------------------------------------------------------------------------
    // The verdict logic — pure, and the whole point of the contract
    // -------------------------------------------------------------------------

    /// @notice Decide what is wrong with a round, given only the round.
    /// @dev    Pure and feed-free by design: this is the function the property
    ///         harness drives, and every state including the ones a live feed
    ///         will not produce on request is reachable by choosing arguments.
    ///
    ///         Conditions are tested in DESCENDING severity, so the verdict is
    ///         the worst thing true about the round rather than whichever
    ///         problem happened to be checked first. The order also makes the
    ///         arithmetic safe: `observedAt - updatedAt` on the last line cannot
    ///         underflow, because the `updatedAt > observedAt` branch above it
    ///         has already returned.
    ///
    /// @param answer The feed's answer. Signed: negative is representable.
    /// @param updatedAt When the answer was written. Zero means never.
    /// @param observedAt The time to measure against — `block.timestamp` in
    ///        production, an arbitrary value under test. Taking it as an
    ///        argument rather than reading it is what makes this pure.
    /// @param maxAge Oldest acceptable age, INCLUSIVE. `age == maxAge` is
    ///        HEALTHY; STALE begins at `maxAge + 1`.
    /// @return The single most severe applicable state.
    function evaluate(int256 answer, uint256 updatedAt, uint256 observedAt, uint256 maxAge)
        public
        pure
        returns (Health)
    {
        if (updatedAt == 0) return Health.INCOMPLETE_ROUND;
        if (updatedAt > observedAt) return Health.FUTURE_TIMESTAMP;
        if (answer <= 0) return Health.NON_POSITIVE_ANSWER;
        if (observedAt - updatedAt > maxAge) return Health.STALE;
        return Health.HEALTHY;
    }

    /// @notice How old a round is, or zero when age is not a meaningful number.
    /// @dev    Zero for an incomplete round (`updatedAt == 0`) and for a future
    ///         timestamp, rather than `observedAt` or an underflowed value. A
    ///         consumer that subtracts these two fields without this guard
    ///         either reverts on the underflow or, unchecked, reads a
    ///         near-`2**256` age as fresh — which is the FUTURE_TIMESTAMP
    ///         failure mode this explorer exists to name.
    function secondsSince(uint256 updatedAt, uint256 observedAt) public pure returns (uint256) {
        if (updatedAt == 0 || updatedAt > observedAt) return 0;
        return observedAt - updatedAt;
    }

    /// @notice The severity ranking of a state, as a comparable number.
    /// @dev    A cast, not a table. Deriving it from the enum's declaration
    ///         order means it cannot drift out of agreement with the order the
    ///         states are documented and tested in.
    function severityOf(Health health) public pure returns (uint8) {
        return uint8(health);
    }

    // -------------------------------------------------------------------------
    // Reading real feeds — the thin part
    // -------------------------------------------------------------------------

    /// @notice How many feeds are registered.
    function feedCount() public view returns (uint256) {
        return _feeds.length;
    }

    /// @notice The feed registered at `index` and its max age.
    function feedAt(uint256 index) public view returns (FeedConfig memory) {
        if (index >= _feeds.length) revert NoSuchFeed(index, _feeds.length);
        return _feeds[index];
    }

    /// @notice Read one registered feed and report its health.
    /// @dev    `view`, so the page reads it over `eth_call`: no transaction, no
    ///         signature, no visitor gas.
    function check(uint256 index) public view returns (Report memory report) {
        if (index >= _feeds.length) revert NoSuchFeed(index, _feeds.length);
        FeedConfig memory config = _feeds[index];

        report.feed = config.feed;
        report.maxAge = config.maxAge;
        report.checkedAt = block.timestamp;

        (bool answered, uint80 roundId, int256 answer, uint256 updatedAt) = _readRound(config.feed);
        if (!answered) {
            report.health = Health.UNAVAILABLE;
            return report;
        }

        report.roundId = roundId;
        report.answer = answer;
        report.updatedAt = updatedAt;
        report.secondsSinceUpdate = secondsSince(updatedAt, block.timestamp);
        report.health = evaluate(answer, updatedAt, block.timestamp, config.maxAge);
        report.decimals = _readDecimals(config.feed);
    }

    // NO BATCH READ ON CHAIN, deliberately — and this is worth reading before
    // adding one back.
    //
    // An earlier draft had `checkAll()` and `worstHealth()` looping over the
    // registry. Both are gone, for two reasons that point the same way.
    //
    // The first is that they were never the integration surface. A protocol
    // adopting this check calls it for the ONE feed it is about to price
    // something with, inside its own borrow or liquidate transaction. It has no
    // use for the health of feeds it is not reading. `check(index)` is what a
    // consumer actually wants; a batch read was only ever convenience for this
    // repo's own web page, and the page batches at the RPC layer instead, where
    // a slow feed costs a round trip rather than a block's gas.
    //
    // The second is that the estate's single Slither configuration runs
    // `calls-loop` at `fail-on: low`, and an on-chain loop of external reads
    // trips it. That detector's concern — one bad callee spoiling the batch, and
    // unbounded gas — is already answered here: the reads cannot revert this
    // contract and the registry is capped at MAX_FEEDS. But the argument above
    // means there is nothing to defend, so the loop went rather than the gate.
    //
    // -------------------------------------------------------------------------
    // Feed reads that cannot revert this contract
    // -------------------------------------------------------------------------

    /// @dev Low-level `staticcall` rather than `try/catch`, deliberately. A
    ///      `catch` clause does NOT catch a failure to decode the returndata, so
    ///      `try aggregator.latestRoundData()` still reverts the caller when the
    ///      address has no code, or has code that answers with the wrong shape.
    ///      Checking the length before decoding is what makes UNAVAILABLE a
    ///      verdict this contract can actually return.
    ///
    ///      The length is compared for EQUALITY, not `>=`: a feed answering with
    ///      more data than the interface declares is not a feed this contract
    ///      understands, and guessing which 160 bytes were meant is worse than
    ///      saying so.
    ///
    ///      `startedAt` and `answeredInRound` are decoded and discarded — see
    ///      IAggregatorV3 for why `answeredInRound` is not checked.
    function _readRound(address feed)
        private
        view
        returns (bool answered, uint80 roundId, int256 answer, uint256 updatedAt)
    {
        (bool ok, bytes memory data) = feed.staticcall(abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!ok || data.length != ROUND_DATA_RETURN_LENGTH) {
            return (false, 0, 0, 0);
        }
        (roundId, answer,, updatedAt,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        answered = true;
    }

    /// @dev Same shape as `_readRound`, and best-effort for the same reason.
    ///      `decimals` is presentational — it scales the answer for display and
    ///      no verdict depends on it — so a feed that answers round data but not
    ///      `decimals()` is reported with DECIMALS_UNKNOWN rather than being
    ///      demoted to UNAVAILABLE. The health verdict is derived from
    ///      `latestRoundData` alone.
    function _readDecimals(address feed) private view returns (uint8) {
        (bool ok, bytes memory data) = feed.staticcall(abi.encodeCall(IAggregatorV3.decimals, ()));
        if (!ok || data.length != DECIMALS_RETURN_LENGTH) {
            return DECIMALS_UNKNOWN;
        }
        return abi.decode(data, (uint8));
    }
}
