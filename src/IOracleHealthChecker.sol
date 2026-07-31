// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOracleHealthChecker — what a feed-health verdict looks like.
///
/// @notice The types and the read surface, separated from the implementation for
///         one concrete reason: `test/Properties.sol` holds this interface rather
///         than the concrete contract, so `test/Invariants.t.sol` can install a
///         checker built to break exactly one property and require the matching
///         predicate to notice. A harness that cannot report a violation reports
///         green forever, and from the outside those two look identical.
///
/// @dev    The verdict states, and the severity ranking they encode, are
///         documented on the enum below rather than duplicated in the
///         implementation — there is one definition of what STALE means.
interface IOracleHealthChecker {
    /// @notice What is wrong with a feed's latest round, or HEALTHY if nothing.
    ///
    /// @dev    THE ORDINAL IS A SEVERITY RANKING, and it is load-bearing rather
    ///         than incidental. Members are declared least to most severe, so
    ///         `uint8(health)` is directly comparable and `severityOf` is a cast
    ///         rather than a lookup table that could drift out of agreement with
    ///         the order the states are documented and tested in. `evaluate`
    ///         tests conditions in DESCENDING severity and returns the first
    ///         match, so when more than one thing is wrong the verdict is the
    ///         worst of them.
    enum Health {
        /// @dev The round is complete, the answer is positive, and the answer is
        ///      no older than this feed's configured max age.
        HEALTHY,
        /// @dev `age > maxAge`. The feed still answers; nobody has updated it.
        ///      The most common real failure, and the quietest: the data looks
        ///      perfectly well-formed, and a consumer that only checks for a
        ///      revert sees nothing wrong at all.
        STALE,
        /// @dev `answer <= 0`. `answer` is an int256 and negative values are
        ///      representable, so a consumer that casts to uint256 without
        ///      checking turns a negative price into an enormous positive one.
        NON_POSITIVE_ANSWER,
        /// @dev `updatedAt > block.timestamp`. The feed claims to have been
        ///      updated in the future. A consumer computing `now - updatedAt` in
        ///      checked arithmetic reverts here; one using unchecked arithmetic
        ///      underflows to a near-`2**256` age, which any `age < maxAge` test
        ///      reads as catastrophically stale — or, reversed, as fresh.
        FUTURE_TIMESTAMP,
        /// @dev `updatedAt == 0`. The round was started and never answered, so
        ///      there is no timestamp to measure age from at all. Age is
        ///      meaningless here, which is why it is reported as zero rather
        ///      than as `block.timestamp`.
        INCOMPLETE_ROUND,
        /// @dev The feed did not return usable round data: it reverted, it has
        ///      no code, or it answered with the wrong shape. Produced only by
        ///      `check`, never by `evaluate` — `evaluate` is handed round data
        ///      and so by construction has some.
        UNAVAILABLE
    }

    /// @notice One feed and the max age it is judged against.
    struct FeedConfig {
        address feed;
        uint256 maxAge;
    }

    /// @notice A feed's health plus every number the verdict was derived from,
    ///         so a reader can recompute the verdict instead of trusting it.
    struct Report {
        Health health;
        address feed;
        uint8 decimals;
        uint80 roundId;
        int256 answer;
        uint256 updatedAt;
        uint256 checkedAt;
        uint256 secondsSinceUpdate;
        uint256 maxAge;
    }

    // THE THREE FUNCTIONS BELOW ARE DECLARED `view`, AND THE IMPLEMENTATION IS
    // `pure`. That is deliberate and it is not a weakening.
    //
    // Solidity lets an override make mutability STRICTER, so
    // `OracleHealthChecker` declares all three `pure` and the compiler enforces
    // it: the deployed ABI says `pure`, and the contract genuinely cannot read
    // state or a clock in any of them. Verify it on Basescan.
    //
    // The interface is one step looser only so that a WRAPPING implementation is
    // possible — `test/Invariants.t.sol` builds a checker that delegates to a
    // real one and corrupts a single answer, which is an external call and so
    // cannot be `pure`. Without that, the detector self-tests could not exist,
    // and nine predicates that cannot be shown to fire are worth very little.

    /// @notice Decide what is wrong with a round, given only the round.
    /// @param answer The feed's answer. Signed: negative is representable.
    /// @param updatedAt When the answer was written. Zero means never.
    /// @param observedAt The time to measure against.
    /// @param maxAge Oldest acceptable age, INCLUSIVE.
    function evaluate(int256 answer, uint256 updatedAt, uint256 observedAt, uint256 maxAge)
        external
        view
        returns (Health);

    /// @notice How old a round is, or zero when age is not a meaningful number.
    /// @param updatedAt The round's own timestamp, straight from the aggregator.
    /// @param observedAt The time to measure the round against, normally `block.timestamp`.
    /// @return The age in seconds, or zero when the round carries no usable timestamp —
    ///         zero means "age is not a meaningful number here", never "brand new".
    function secondsSince(uint256 updatedAt, uint256 observedAt) external view returns (uint256);

    /// @notice The severity ranking of a state, as a comparable number.
    /// @param health The state to rank.
    /// @return The enum's ordinal, so callers can compare two states with `>` and get
    ///         "more severe" rather than having to know the state names.
    function severityOf(Health health) external view returns (uint8);

    /// @notice How many feeds are registered.
    /// @return The number of feeds, fixed at construction and never changed.
    function feedCount() external view returns (uint256);

    /// @notice The feed registered at `index` and its max age.
    /// @param index Position in the registry, in the order the constructor received them.
    /// @return The aggregator address and the max age that applies to it.
    function feedAt(uint256 index) external view returns (FeedConfig memory);

    /// @notice Read one registered feed and report its health.
    /// @param index Position of the feed in the registry.
    /// @return The feed address, its max age, the round that was read, the time it was
    ///         checked, and the verdict.
    function check(uint256 index) external view returns (Report memory);
}
