// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IOracleHealthChecker as IOHC} from "../src/IOracleHealthChecker.sol";
import {OracleHealthChecker} from "../src/OracleHealthChecker.sol";
import {Properties} from "./Properties.sol";

/// @title InvariantsTest — the third engine on the same property file.
///
/// @notice Echidna and Medusa both drive `test/Properties.sol`. So does this,
///         through Foundry's own invariant runner. Three engines, ONE set of
///         predicates: a property cannot hold under one and quietly rot under
///         another, and a `forge test` run is enough to catch a broken invariant
///         before anyone reaches for a fuzzer.
///
/// @dev    `fail_on_revert = true` is set in foundry.toml. Every entry point in
///         the harness bounds its own inputs, so a revert reaching the runner
///         means the HARNESS is broken — not that the checker is — and it must
///         fail loudly rather than quietly shrinking the search space to
///         whichever calls happen to succeed.
///
/// @dev    The second half of this file is the part that matters most. Nine
///         predicates that have never been contradicted are indistinguishable
///         from nine that CANNOT be contradicted, and only one of those is worth
///         running. So each detector is driven against a checker built to break
///         exactly the property it watches, and required to notice.
///
///         Each self-test drives ONLY the entry point that feeds its predicate.
///         That is what makes the result attributable: a detector that went red
///         because a neighbouring detector went red has not been shown to work.
contract InvariantsTest is Test {
    /*//////////////////////////////////////////////////////////////
                       DRAWS WITH KNOWN SHAPED VALUES
    //////////////////////////////////////////////////////////////*/
    // The harness shapes every raw draw before use. These constants are chosen so
    // the shaped values are known exactly, which is what lets a self-test say
    // "this call lands strictly inside the interior" rather than hoping it does.

    /// @dev `_maxAge` computes `1 + (raw % 30 days)`, so this yields exactly 3600.
    uint256 internal constant MAX_AGE_DRAW = 3599;

    /// @dev `_observedAt` computes `MIN_OBSERVED_AT + (raw % ...)`, so zero yields
    ///      the floor exactly: `30 days + 2`, or 2,592,002.
    uint256 internal constant TIME_DRAW = 0;
    uint256 internal constant OBSERVED_AT = 30 days + 2;
    uint256 internal constant MAX_AGE = 3600;

    /// @dev In `probeFreshRound`, `age = raw % (maxAge + 1)`, so this lands at an
    ///      age of 1800 — strictly inside the in-date range, and clear of both
    ///      ends of it.
    uint256 internal constant INTERIOR_AGE_DRAW = 1800;

    /// @dev In `probeAging`, `step = 1 + (raw % MAX_STEP)`, so this steps the
    ///      clock forward 3601 seconds: one second past `MAX_AGE`, which turns a
    ///      zero-age round stale and nothing less.
    uint256 internal constant STEP_PAST_MAX_AGE_DRAW = 3600;

    /// @dev `probeAging` computes `updatedAt = observedAt - (raw % observedAt)`,
    ///      so zero yields `updatedAt == observedAt`: an age of zero.
    uint256 internal constant ZERO_AGE_DRAW = 0;

    /// @dev A positive answer, so nothing in a self-test is unhealthy for a
    ///      reason the test did not intend.
    int256 internal constant POSITIVE_ANSWER = 100;

    Properties internal props;

    function setUp() public {
        props = new Properties();
        targetContract(address(props));
    }

    /*//////////////////////////////////////////////////////////////
                      THE NINE PREDICATES, VERBATIM
    //////////////////////////////////////////////////////////////*/

    function invariant_verdictIsTheMostSevereApplicableState() public view {
        assertTrue(
            props.echidna_verdict_is_the_most_severe_applicable_state(),
            "a verdict was not the worst thing true about the round"
        );
    }

    function invariant_ageNeverImprovesHealth() public view {
        assertTrue(props.echidna_age_never_improves_health(), "waiting made a feed look healthier");
    }

    function invariant_freshPositiveCompleteIsHealthy() public view {
        assertTrue(
            props.echidna_fresh_positive_complete_is_healthy(), "a good round was not reported healthy"
        );
    }

    function invariant_nonPositiveAnswerIsNeverHealthy() public view {
        assertTrue(
            props.echidna_non_positive_answer_is_never_healthy(), "a non-positive answer read as healthy"
        );
    }

    function invariant_incompleteRoundIsReported() public view {
        assertTrue(
            props.echidna_incomplete_round_is_reported(), "an incomplete round was not reported as one"
        );
    }

    function invariant_futureTimestampIsReported() public view {
        assertTrue(props.echidna_future_timestamp_is_reported(), "a future timestamp was not reported as one");
    }

    function invariant_maxAgeBoundaryIsExact() public view {
        assertTrue(props.echidna_max_age_boundary_is_exact(), "the staleness boundary was off by one");
    }

    function invariant_unreachableFeedIsUnavailable() public view {
        assertTrue(props.echidna_unreachable_feed_is_unavailable(), "a dead feed did not report UNAVAILABLE");
    }

    function invariant_feedVerdictMatchesPureLogic() public view {
        assertTrue(
            props.echidna_feed_verdict_matches_pure_logic(), "reading a feed disagreed with the pure logic"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      THE HARNESS'S OWN DECLARATION
    //////////////////////////////////////////////////////////////*/

    /// @dev The count `scripts/property-count.sh` checks statically, checked again
    ///      here at runtime against the predicates this file actually calls. If
    ///      someone adds a tenth predicate to Properties.sol and forgets this
    ///      file, the static gate catches the count and this catches the omission
    ///      — the pair is what makes "nine properties" mean nine.
    function test_declaredPropertyCountMatchesThisFile() public view {
        assertEq(props.pigfoxPropertyCount(), 9, "declared property count");
        assertEq(_predicatesDrivenHere(), props.pigfoxPropertyCount(), "predicates asserted by this file");
    }

    function test_harnessSaysWhatItProves() public view {
        assertEq(
            props.pigfoxHarnessDescription(),
            "a feed-health verdict is exact at the staleness boundary, never flatters bad data, and a dead feed never reverts the caller"
        );
    }

    /// @dev Counted by calling every predicate this file asserts. Deliberately a
    ///      literal list rather than a number: adding an `invariant_` above
    ///      without adding it here leaves the two disagreeing, which is the point.
    function _predicatesDrivenHere() internal view returns (uint256 n) {
        props.echidna_verdict_is_the_most_severe_applicable_state();
        n++;
        props.echidna_age_never_improves_health();
        n++;
        props.echidna_fresh_positive_complete_is_healthy();
        n++;
        props.echidna_non_positive_answer_is_never_healthy();
        n++;
        props.echidna_incomplete_round_is_reported();
        n++;
        props.echidna_future_timestamp_is_reported();
        n++;
        props.echidna_max_age_boundary_is_exact();
        n++;
        props.echidna_unreachable_feed_is_unavailable();
        n++;
        props.echidna_feed_verdict_matches_pure_logic();
        n++;
    }

    /// @dev The harness registers five feeds: one that answers and four distinct
    ///      ways of failing to. A harness that silently held fewer would still
    ///      pass every property, because the predicates only ever read the feeds
    ///      that are there.
    function test_harnessHoldsFiveDistinctFeeds() public view {
        address[5] memory seen;
        for (uint256 i = 0; i < 5; i++) {
            address feed = props.harnessFeedAt(i);
            assertTrue(feed != address(0), "feed slot never filled");
            for (uint256 j = 0; j < i; j++) {
                assertTrue(feed != seen[j], "two slots hold the same feed");
            }
            seen[i] = feed;
        }
    }

    /*//////////////////////////////////////////////////////////////
                   EVERY DETECTOR MUST BE ABLE TO FIRE
    //////////////////////////////////////////////////////////////*/

    function test_detectsAVerdictThatIsNotTheMostSevere() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.MostSevereIgnored);
        assertTrue(probe.echidna_verdict_is_the_most_severe_applicable_state(), "clean before");
        // Incomplete AND non-positive at once. The honest answer is
        // INCOMPLETE_ROUND, severity 4; the fault returns NON_POSITIVE_ANSWER,
        // severity 2. Every individual condition is still detected — only the
        // RANKING between them is wrong, which is what this predicate is for.
        probe.probeMostSevere(-5, TIME_DRAW, 0, MAX_AGE_DRAW);
        assertFalse(
            probe.echidna_verdict_is_the_most_severe_applicable_state(), "a flattered verdict went unnoticed"
        );
    }

    function test_detectsWaitingMakingAFeedLookHealthier() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.AgingInverted);
        assertTrue(probe.echidna_age_never_improves_health(), "clean before");
        // A zero-age round, read again 3601 seconds later. Honestly that is
        // HEALTHY then STALE; the fault swaps the two, so severity FALLS.
        probe.probeAging(POSITIVE_ANSWER, TIME_DRAW, ZERO_AGE_DRAW, STEP_PAST_MAX_AGE_DRAW, MAX_AGE_DRAW);
        assertFalse(probe.echidna_age_never_improves_health(), "a verdict improving with age went unnoticed");
    }

    function test_detectsAGoodRoundReportedUnhealthy() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.FreshReportedStale);
        assertTrue(probe.echidna_fresh_positive_complete_is_healthy(), "clean before");
        // An age of 1800 against a max age of 3600: strictly interior, so the
        // fault cannot be mistaken for a boundary error.
        probe.probeFreshRound(POSITIVE_ANSWER, TIME_DRAW, INTERIOR_AGE_DRAW, MAX_AGE_DRAW);
        assertFalse(probe.echidna_fresh_positive_complete_is_healthy(), "a false alarm went unnoticed");
        assertTrue(
            probe.echidna_non_positive_answer_is_never_healthy(),
            "the neighbouring detector must NOT have fired: this fault is not about the answer's sign"
        );
    }

    function test_detectsANonPositiveAnswerReadingAsHealthy() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.NonPositiveReportedHealthy);
        assertTrue(probe.echidna_non_positive_answer_is_never_healthy(), "clean before");
        probe.probeFreshRound(POSITIVE_ANSWER, TIME_DRAW, INTERIOR_AGE_DRAW, MAX_AGE_DRAW);
        assertFalse(
            probe.echidna_non_positive_answer_is_never_healthy(),
            "a negative price reading healthy went unnoticed"
        );
        assertTrue(
            probe.echidna_fresh_positive_complete_is_healthy(),
            "the neighbouring detector must NOT have fired: the positive round was answered honestly"
        );
    }

    function test_detectsAnIncompleteRoundNotReported() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.IncompleteReportedHealthy);
        assertTrue(probe.echidna_incomplete_round_is_reported(), "clean before");
        probe.probeDegenerateRounds(POSITIVE_ANSWER, TIME_DRAW, 0, MAX_AGE_DRAW);
        assertFalse(probe.echidna_incomplete_round_is_reported(), "an incomplete round went unnoticed");
        assertTrue(
            probe.echidna_future_timestamp_is_reported(),
            "the neighbouring detector must NOT have fired: a future round is not an incomplete one"
        );
    }

    function test_detectsAFutureTimestampNotReported() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.FutureReportedHealthy);
        assertTrue(probe.echidna_future_timestamp_is_reported(), "clean before");
        probe.probeDegenerateRounds(POSITIVE_ANSWER, TIME_DRAW, 0, MAX_AGE_DRAW);
        assertFalse(probe.echidna_future_timestamp_is_reported(), "a future timestamp went unnoticed");
        assertTrue(
            probe.echidna_incomplete_round_is_reported(),
            "the neighbouring detector must NOT have fired: an incomplete round is not a future one"
        );
    }

    /// @dev The one that matters most. The fault is a single character: `>=` where
    ///      the contract has `>`. It is correct everywhere except on one value,
    ///      which is exactly why interior sampling cannot find it and why the
    ///      boundary is constructed rather than drawn.
    function test_detectsAnOffByOneAtTheStalenessBoundary() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.BoundaryOffByOne);
        assertTrue(probe.echidna_max_age_boundary_is_exact(), "clean before");
        probe.probeBoundary(POSITIVE_ANSWER, TIME_DRAW, MAX_AGE_DRAW);
        assertFalse(probe.echidna_max_age_boundary_is_exact(), "an off-by-one boundary went unnoticed");
    }

    /// @dev And the control for that one: an interior draw does NOT catch it. This
    ///      is the test that justifies the boundary property existing separately
    ///      from the freshness property at all — without it, "we fuzz the range"
    ///      would sound like enough.
    function test_anInteriorDrawDoesNotCatchTheOffByOne() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.BoundaryOffByOne);
        probe.probeFreshRound(POSITIVE_ANSWER, TIME_DRAW, INTERIOR_AGE_DRAW, MAX_AGE_DRAW);
        assertTrue(
            probe.echidna_fresh_positive_complete_is_healthy(),
            "an interior age must NOT reveal an off-by-one at the boundary"
        );
    }

    function test_detectsADeadFeedNotReportingUnavailable() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.DeadFeedReportedHealthy);
        assertTrue(probe.echidna_unreachable_feed_is_unavailable(), "clean before");
        probe.probeUnreachableFeeds();
        assertFalse(
            probe.echidna_unreachable_feed_is_unavailable(), "a dead feed reading healthy went unnoticed"
        );
    }

    function test_detectsTheWrapperDisagreeingWithThePureLogic() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.WrapperReadsStartedAt);
        assertTrue(probe.echidna_feed_verdict_matches_pure_logic(), "clean before");
        probe.probeFeedRound(POSITIVE_ANSWER, 1_000_000, 7, 8);
        assertFalse(
            probe.echidna_feed_verdict_matches_pure_logic(),
            "a wrapper contradicting the pure logic went unnoticed"
        );
    }

    /// @dev The round-robin in `_afterCall` visits every unreachable feed, not
    ///      only the one the last entry point happened to read. A fault confined
    ///      to the LAST of them is therefore still caught, just later — which is
    ///      the whole reason the cursor exists rather than always re-reading the
    ///      first.
    function test_theRoundRobinReachesEveryUnreachableFeed() public {
        HarnessProbe probe = new HarnessProbe();
        probe.installFaultyChecker(_faultyOver(probe, FaultyChecker.Fault.LastDeadFeedReportedHealthy));
        assertTrue(probe.echidna_unreachable_feed_is_unavailable(), "clean before");

        // `probeBoundary` reads no feed itself, so the only thing that can notice
        // is the round-robin. Three calls cover feeds 1..3 and must stay clean;
        // the fourth reaches the last one.
        for (uint256 i = 0; i < 3; i++) {
            probe.probeBoundary(POSITIVE_ANSWER, TIME_DRAW, MAX_AGE_DRAW);
            assertTrue(probe.echidna_unreachable_feed_is_unavailable(), "tripped on an honest feed");
        }
        probe.probeBoundary(POSITIVE_ANSWER, TIME_DRAW, MAX_AGE_DRAW);
        assertFalse(
            probe.echidna_unreachable_feed_is_unavailable(), "the round-robin never reached the last feed"
        );
    }

    /// @dev The control. The same probe with a FAITHFUL checker must leave every
    ///      predicate true after the same driving — otherwise the assertions above
    ///      would be satisfied by a harness that simply always says no.
    function test_aFaithfulCheckerTripsNothing() public {
        HarnessProbe probe = _probeWith(FaultyChecker.Fault.None);

        probe.probeMostSevere(-5, TIME_DRAW, 0, MAX_AGE_DRAW);
        probe.probeAging(POSITIVE_ANSWER, TIME_DRAW, ZERO_AGE_DRAW, STEP_PAST_MAX_AGE_DRAW, MAX_AGE_DRAW);
        probe.probeFreshRound(POSITIVE_ANSWER, TIME_DRAW, INTERIOR_AGE_DRAW, MAX_AGE_DRAW);
        probe.probeDegenerateRounds(POSITIVE_ANSWER, TIME_DRAW, 0, MAX_AGE_DRAW);
        probe.probeBoundary(POSITIVE_ANSWER, TIME_DRAW, MAX_AGE_DRAW);
        probe.probeUnreachableFeeds();
        probe.probeFeedRound(POSITIVE_ANSWER, 1_000_000, 7, 8);

        assertTrue(probe.echidna_verdict_is_the_most_severe_applicable_state(), "control: most severe");
        assertTrue(probe.echidna_age_never_improves_health(), "control: aging");
        assertTrue(probe.echidna_fresh_positive_complete_is_healthy(), "control: fresh");
        assertTrue(probe.echidna_non_positive_answer_is_never_healthy(), "control: non-positive");
        assertTrue(probe.echidna_incomplete_round_is_reported(), "control: incomplete");
        assertTrue(probe.echidna_future_timestamp_is_reported(), "control: future");
        assertTrue(probe.echidna_max_age_boundary_is_exact(), "control: boundary");
        assertTrue(probe.echidna_unreachable_feed_is_unavailable(), "control: unreachable");
        assertTrue(probe.echidna_feed_verdict_matches_pure_logic(), "control: wrapper");
    }

    function _probeWith(FaultyChecker.Fault fault) internal returns (HarnessProbe probe) {
        probe = new HarnessProbe();
        probe.installFaultyChecker(_faultyOver(probe, fault));
    }

    /// @dev Builds a faulty checker wrapping a real one over THAT PROBE'S OWN
    ///      feeds, so the only difference between it and the checker it replaces
    ///      is the injected fault.
    ///
    ///      The feeds come from the probe rather than from `props`, and that
    ///      distinction is not pedantic: every `HarnessProbe` constructs its own
    ///      mock aggregators. An earlier draft read them off `props`, so
    ///      `probeFeedRound` wrote round data to the probe's mock and then read a
    ///      DIFFERENT mock back through the checker. The wrapper property failed
    ///      against a faithful checker, and `test_aFaithfulCheckerTripsNothing`
    ///      is what caught it — which is exactly the job a control has.
    function _faultyOver(HarnessProbe probe, FaultyChecker.Fault fault) internal returns (FaultyChecker) {
        uint256 count = probe.harnessFeedCount();
        IOHC.FeedConfig[] memory configs = new IOHC.FeedConfig[](count);
        for (uint256 i = 0; i < count; i++) {
            configs[i] = IOHC.FeedConfig(probe.harnessFeedAt(i), probe.harnessMaxAge());
        }
        return new FaultyChecker(fault, configs);
    }
}

/// @dev A `Properties` subclass with one extra function: it swaps the checker out.
///      Nothing in the real harness can do this — the field is written only in the
///      constructor — which is exactly why proving the detectors work needs a
///      subclass that breaks the rule on purpose.
contract HarnessProbe is Properties {
    function installFaultyChecker(IOHC faulty) external {
        checker = faulty;
    }
}

/// @dev A checker that wraps a real one and corrupts exactly one thing.
///
///      It delegates everything it is not deliberately breaking, so a failing
///      predicate is attributable to the single injected fault rather than to a
///      stub that was never a plausible checker in the first place.
contract FaultyChecker is IOHC {
    enum Fault {
        None,
        MostSevereIgnored,
        AgingInverted,
        FreshReportedStale,
        NonPositiveReportedHealthy,
        IncompleteReportedHealthy,
        FutureReportedHealthy,
        BoundaryOffByOne,
        DeadFeedReportedHealthy,
        LastDeadFeedReportedHealthy,
        WrapperReadsStartedAt
    }

    /// @dev The index the `LastDeadFeedReportedHealthy` fault is confined to — the
    ///      last of the harness's four unreachable feeds.
    uint256 internal constant LAST_UNREACHABLE_INDEX = 4;

    OracleHealthChecker internal immutable INNER;
    Fault public immutable FAULT;

    constructor(Fault fault, IOHC.FeedConfig[] memory configs) {
        INNER = new OracleHealthChecker(configs);
        FAULT = fault;
    }

    function evaluate(int256 answer, uint256 updatedAt, uint256 observedAt, uint256 maxAge)
        public
        view
        returns (Health)
    {
        Health honest = INNER.evaluate(answer, updatedAt, observedAt, maxAge);

        // Ranks a genuinely-detected pair of problems the wrong way round. Every
        // individual condition is still reported; only the ordering is wrong.
        if (FAULT == Fault.MostSevereIgnored && updatedAt == 0 && answer <= 0) {
            return Health.NON_POSITIVE_ANSWER;
        }
        // Swaps the two states that a passing clock moves between, so severity
        // falls as the round ages.
        if (FAULT == Fault.AgingInverted) {
            if (honest == Health.HEALTHY) return Health.STALE;
            if (honest == Health.STALE) return Health.HEALTHY;
        }
        // A false alarm, confined to the strict interior of the in-date range so
        // it cannot be mistaken for a boundary error.
        if (FAULT == Fault.FreshReportedStale && honest == Health.HEALTHY && updatedAt < observedAt) {
            uint256 age = observedAt - updatedAt;
            if (age > 0 && age < maxAge) return Health.STALE;
        }
        if (
            FAULT == Fault.NonPositiveReportedHealthy && answer <= 0 && updatedAt != 0
                && updatedAt <= observedAt
        ) {
            return Health.HEALTHY;
        }
        if (FAULT == Fault.IncompleteReportedHealthy && updatedAt == 0) return Health.HEALTHY;
        if (FAULT == Fault.FutureReportedHealthy && updatedAt > observedAt) return Health.HEALTHY;
        // `>=` where the contract has `>`: one character, correct everywhere
        // except on a single value.
        if (
            FAULT == Fault.BoundaryOffByOne && honest == Health.HEALTHY && updatedAt != 0
                && updatedAt <= observedAt && observedAt - updatedAt >= maxAge
        ) {
            return Health.STALE;
        }

        return honest;
    }

    function secondsSince(uint256 updatedAt, uint256 observedAt) public view returns (uint256) {
        return INNER.secondsSince(updatedAt, observedAt);
    }

    function severityOf(Health health) public view returns (uint8) {
        return INNER.severityOf(health);
    }

    function feedCount() public view returns (uint256) {
        return INNER.feedCount();
    }

    function feedAt(uint256 index) public view returns (FeedConfig memory) {
        return INNER.feedAt(index);
    }

    function check(uint256 index) public view returns (Report memory report) {
        report = INNER.check(index);

        if (FAULT == Fault.DeadFeedReportedHealthy && report.health == Health.UNAVAILABLE) {
            report.health = Health.HEALTHY;
        }
        if (
            FAULT == Fault.LastDeadFeedReportedHealthy && index == LAST_UNREACHABLE_INDEX
                && report.health == Health.UNAVAILABLE
        ) {
            report.health = Health.HEALTHY;
        }
        // The wrapper bug that every pure-logic property would miss: reading the
        // right feed, applying the right rule, to the WRONG field. Here the age is
        // measured from a timestamp one hour earlier than the one reported, so the
        // report contradicts itself without any single field looking wrong.
        if (FAULT == Fault.WrapperReadsStartedAt && report.health != Health.UNAVAILABLE) {
            report.secondsSinceUpdate = report.secondsSinceUpdate + 1 hours;
        }
    }
}
