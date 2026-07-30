// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PigfoxProperties} from "pipeline/PigfoxProperties.sol";

import {IOracleHealthChecker as IOHC} from "../src/IOracleHealthChecker.sol";
import {OracleHealthChecker} from "../src/OracleHealthChecker.sol";
import {MockAggregator, RevertingAggregator, WrongShapeAggregator} from "./mocks/MockAggregator.sol";

/// @title Properties — a feed-health verdict, attacked.
///
/// @notice A staleness check is not interesting because it computes something.
///         It is interesting because a protocol's solvency rests on it being
///         RIGHT AT THE EDGE: that an age of exactly the threshold is not
///         quietly treated as stale, that one second past it is not quietly
///         treated as fresh, that a negative answer never reads as healthy at
///         any age, and that a feed which has stopped answering altogether
///         produces a verdict rather than taking the caller down with it. Those
///         are the nine statements below.
///
/// @dev    WHY THE HARNESS OWNS MOCK AGGREGATORS. Every failure state this
///         explorer names is unreachable through a live feed. A real aggregator
///         cannot be asked to go stale, to answer negative, or to hand back an
///         incomplete round, so a harness pointed at a live address could only
///         ever demonstrate the healthy path — the one path that needed no
///         verification. The mocks are how the other five get reached. They are
///         fresh contracts built from source in the in-process EVM each engine
///         constructs; they reach no network and they stand in for nothing.
///
/// @dev    WHY THE HARNESS HOLDS THE INTERFACE AND NOT THE CONCRETE TYPE.
///         Every check below goes through `IOracleHealthChecker`. That costs an
///         external call and buys the thing that makes this file trustworthy:
///         `test/Invariants.t.sol` installs a checker built to break each
///         property on purpose and requires the matching predicate to go false.
///         Nine predicates that have never been contradicted are
///         indistinguishable from nine that CANNOT be contradicted, and only one
///         of those is worth running.
///
/// @dev    WHY THE HARNESS CASTS THE ENUM ITSELF INSTEAD OF CALLING
///         `severityOf`. Wherever this file needs to compare two verdicts by
///         severity it uses its own `uint8(...)` cast, never the checker's
///         `severityOf`. The harness's judgement must not be routed through the
///         contract it is judging: a checker whose `severityOf` lied would
///         otherwise be able to talk the monotonicity property into passing.
///         `severityOf` agreeing with the cast is a separate claim, asserted in
///         `test/OracleHealthChecker.t.sol` where it can be stated directly.
///
/// @dev    EVERY PREDICATE IS AN O(1) FLAG READ. Echidna evaluates every
///         predicate after every call of every sequence, so a predicate that
///         recomputed a set of cases on each evaluation would spend the whole
///         campaign re-deriving answers instead of reaching new inputs. That is
///         not hypothetical: it took a sibling repo's 100,000-test run past
///         thirteen minutes. So the entry points do the work, compare eagerly,
///         and trip a sticky flag — which also means the shrunk counterexample is
///         the offending call itself rather than a sequence of noise.
///
/// @dev    EVERY ENTRY POINT IS TOTAL. Each one shapes its raw fuzz draw into
///         the case it is about, rather than testing a condition and returning
///         early when it does not hold. A property guarded by `if (age <=
///         maxAge)` is vacuous on almost every draw and reports green for the
///         inputs it skipped. And no entry point can revert: that is what makes
///         Foundry's `fail_on_revert = true` meaningful here, where a revert
///         means the harness is broken rather than that the checker is.
///
/// @dev    NO CHEATCODES. Echidna and Medusa have no `vm`. Everything here is
///         plain Solidity, which is also why the harness deploys its own checker
///         rather than pointing at the live address. The live checker is the same
///         bytecode; that is what `forge build` guarantees and what Basescan
///         verification shows.
contract Properties is PigfoxProperties {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Upper bound on any timestamp the harness constructs. Comfortably
    ///      past the year 2096, and far below the point where adding a delta
    ///      could overflow.
    uint256 internal constant MAX_TIME = 4_000_000_000;

    /// @dev Matches `OracleHealthChecker.MAX_CONFIGURABLE_MAX_AGE`. Restated
    ///      rather than read from the checker, so a max age the constructor would
    ///      reject is impossible to construct here — otherwise a harness bug
    ///      would surface as a finding about the contract.
    uint256 internal constant MAX_AGE_BOUND = 30 days;

    /// @dev The floor on every observed time the harness produces.
    ///
    ///      `MAX_AGE_BOUND + 2` is not arbitrary. The boundary property needs to
    ///      construct an `updatedAt` of `observedAt - maxAge - 1` — one second
    ///      older than the threshold — and that has to stay at least 1, because 0
    ///      means INCOMPLETE_ROUND and would test a different state than the one
    ///      the property is about. With `maxAge` capped at `MAX_AGE_BOUND`, this
    ///      floor makes the subtraction safe by construction rather than by a
    ///      guard that could be removed. Real timestamps are around 1.78e9
    ///      anyway, three orders of magnitude above this.
    uint256 internal constant MIN_OBSERVED_AT = MAX_AGE_BOUND + 2;

    /// @dev How far ahead of `observedAt` the future-timestamp case reaches, and
    ///      how far forward the aging case steps.
    uint256 internal constant MAX_STEP = 1_000_000;

    /// @dev The max age every registered feed in this harness is judged against.
    uint256 internal constant HARNESS_MAX_AGE = 3600;

    /// @dev The scale the good mock reports, matching all four measured live feeds.
    uint8 internal constant HARNESS_DECIMALS = 8;

    // Feed indices in the harness's checker. Index 0 answers; the rest are the
    // four distinct ways a feed can fail to answer usefully.
    uint256 internal constant FEED_GOOD = 0;
    uint256 internal constant FEED_REVERT_WITH_REASON = 1;
    uint256 internal constant FEED_REVERT_EMPTY = 2;
    uint256 internal constant FEED_WRONG_SHAPE = 3;
    uint256 internal constant FEED_NO_CODE = 4;

    /// @dev The first unreachable feed's index, and how many there are. The
    ///      round-robin in `_afterCall` walks exactly this range.
    uint256 internal constant FIRST_UNREACHABLE = FEED_REVERT_WITH_REASON;
    uint256 internal constant UNREACHABLE_FEED_COUNT = 4;

    /// @dev An address with no code, registered as a feed. Not `address(0)` —
    ///      the constructor rejects that, and rightly, so the "no code at all"
    ///      case needs a non-zero address that simply has nothing deployed to it.
    address internal constant NO_CODE_FEED = address(0xDEAD);

    /*//////////////////////////////////////////////////////////////
                          THE CHECKER AND ITS FEEDS
    //////////////////////////////////////////////////////////////*/

    /// @notice The checker every property is claimed about.
    /// @dev    `internal` and typed as the interface so a test-only subclass can
    ///         install a deliberately broken checker; see the detector self-tests
    ///         in `test/Invariants.t.sol`. Nothing in this contract writes to it
    ///         after construction.
    IOHC internal checker;

    /// @notice The one feed that answers. Its round data is what `probeFeedRound`
    ///         drives.
    MockAggregator internal good;

    /*//////////////////////////////////////////////////////////////
                              STICKY FLAGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set if a verdict was ever not the most severe applicable state.
    bool public verdictNotMostSevere;

    /// @notice Set if time passing ever made a verdict healthier.
    bool public agingImprovedHealth;

    /// @notice Set if a complete, positive, in-date round was ever not HEALTHY.
    bool public freshRoundNotHealthy;

    /// @notice Set if a non-positive answer ever read as HEALTHY.
    bool public nonPositiveWasHealthy;

    /// @notice Set if `updatedAt == 0` ever produced anything but INCOMPLETE_ROUND.
    bool public incompleteRoundNotReported;

    /// @notice Set if a future `updatedAt` ever produced anything but
    ///         FUTURE_TIMESTAMP.
    bool public futureTimestampNotReported;

    /// @notice Set if the staleness threshold was ever off by one in either
    ///         direction.
    bool public boundaryWrong;

    /// @notice Set if a feed that cannot be read usefully ever produced anything
    ///         but UNAVAILABLE.
    bool public unreachableFeedNotUnavailable;

    /// @notice Set if reading a real feed ever disagreed with the pure verdict
    ///         logic applied to the same round data.
    bool public wrapperDisagreedWithPureLogic;

    /// @dev Which unreachable feed the next entry point re-checks. See `_afterCall`.
    uint256 internal cursor;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    constructor() {
        good = new MockAggregator("HARNESS / USD", HARNESS_DECIMALS);
        // A plausible healthy starting state, so the feed-reading properties mean
        // something before the fuzzer has driven `probeFeedRound` even once.
        good.setRound(1, 2000e8, block.timestamp);

        MockAggregator revertWithReason = new MockAggregator("DOWN / USD", HARNESS_DECIMALS);
        revertWithReason.setReverting(true);

        IOHC.FeedConfig[] memory configs = new IOHC.FeedConfig[](5);
        configs[FEED_GOOD] = IOHC.FeedConfig(address(good), HARNESS_MAX_AGE);
        configs[FEED_REVERT_WITH_REASON] = IOHC.FeedConfig(address(revertWithReason), HARNESS_MAX_AGE);
        configs[FEED_REVERT_EMPTY] = IOHC.FeedConfig(address(new RevertingAggregator()), HARNESS_MAX_AGE);
        configs[FEED_WRONG_SHAPE] = IOHC.FeedConfig(address(new WrongShapeAggregator()), HARNESS_MAX_AGE);
        configs[FEED_NO_CODE] = IOHC.FeedConfig(NO_CODE_FEED, HARNESS_MAX_AGE);

        checker = new OracleHealthChecker(configs);
    }

    /*//////////////////////////////////////////////////////////////
                              DECLARATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc PigfoxProperties
    function pigfoxPropertyCount() public pure override returns (uint256) {
        return 9;
    }

    /// @inheritdoc PigfoxProperties
    function pigfoxHarnessDescription() public pure override returns (string memory) {
        return "a feed-health verdict is exact at the staleness boundary, never flatters bad data, and a dead feed never reverts the caller";
    }

    /// @notice Which checker the harness is driving.
    /// @dev    `view`, so no fuzzer mistakes it for an entry point.
    function checkerAddress() public view returns (address) {
        return address(checker);
    }

    /// @notice The feed registered at a given index, as the harness sees it.
    /// @dev    `view`, for the same reason.
    function harnessFeedAt(uint256 index) public view returns (address) {
        return checker.feedAt(index).feed;
    }

    /// @notice How many feeds this harness registered, and the max age they all
    ///         share.
    /// @dev    Exposed so `test/Invariants.t.sol` can rebuild a checker over
    ///         exactly THIS harness's feeds rather than over a set it restated.
    ///         An earlier draft restated them, and the control test caught it:
    ///         the probe wrote round data to its own mock and read a different
    ///         one, so the wrapper property failed against a faithful checker.
    ///         Anything a test needs to know about the harness comes from the
    ///         harness.
    function harnessFeedCount() public view returns (uint256) {
        return checker.feedCount();
    }

    /// @notice The max age every feed in this harness is registered with.
    function harnessMaxAge() public pure returns (uint256) {
        return HARNESS_MAX_AGE;
    }

    /*//////////////////////////////////////////////////////////////
                              ENTRY POINTS
    //////////////////////////////////////////////////////////////*/

    // ONE ENTRY POINT PER CLAIM, not one that drives everything.
    //
    // An earlier draft had a single `probeRound` shaping one draw into all six
    // single-round cases. It was replaced, for a reason worth recording: a fault
    // injected into the checker tripped four detectors at once, so the self-tests
    // in `test/Invariants.t.sol` could show that SOMETHING noticed but not that
    // the RIGHT thing did. Splitting the entry points means a self-test can drive
    // exactly the one that feeds the predicate under examination, and a detector
    // that only ever fires because a neighbour fired is not a detector.
    //
    // It costs nothing at runtime — the engines call one entry point per step
    // either way — and it shrinks better, because a counterexample names the one
    // case that broke rather than a call that tried six.

    /// @notice The verdict is the most severe thing true about an arbitrary round.
    /// @dev    Driven with the UNSHAPED draw, so this covers the combinations the
    ///         shaped entry points below exclude by construction — a zero
    ///         `updatedAt` together with a negative answer, a future timestamp on
    ///         a round that is also stale, and so on.
    function probeMostSevere(int256 rawAnswer, uint256 rawTime, uint256 rawUpdatedAt, uint256 rawMaxAge)
        public
    {
        _checkMostSevere(rawAnswer, rawUpdatedAt, _observedAt(rawTime), _maxAge(rawMaxAge));
        _afterCall();
    }

    /// @notice A complete, in-date round: healthy if the answer is positive, and
    ///         never healthy if it is not.
    ///
    /// @dev    Both checks run at the SAME in-date `updatedAt`, drawn from the
    ///         whole `[0, maxAge]` range rather than at one point in it. That
    ///         shared timestamp is what makes the second check mean something:
    ///         staleness is not what makes the non-positive round unhealthy,
    ///         because the positive round beside it is healthy at that very age.
    ///         `updatedAt` is at least 2 by the floor on `observedAt`, so it is
    ///         never mistaken for an incomplete round.
    function probeFreshRound(int256 rawAnswer, uint256 rawTime, uint256 rawSpan, uint256 rawMaxAge) public {
        uint256 maxAge = _maxAge(rawMaxAge);
        uint256 observedAt = _observedAt(rawTime);
        uint256 updatedAt = observedAt - (rawSpan % (maxAge + 1));

        if (checker.evaluate(_positive(rawAnswer), updatedAt, observedAt, maxAge) != IOHC.Health.HEALTHY) {
            freshRoundNotHealthy = true;
        }
        if (checker.evaluate(_nonPositive(rawAnswer), updatedAt, observedAt, maxAge) == IOHC.Health.HEALTHY) {
            nonPositiveWasHealthy = true;
        }

        _afterCall();
    }

    /// @notice The two rounds that are not merely old but malformed.
    /// @dev    Kept together because they are the same kind of claim — a round
    ///         whose timestamp is not a usable measurement — and kept apart from
    ///         the fresh cases because a fault in one must not be able to hide
    ///         behind a detector for the other.
    function probeDegenerateRounds(int256 rawAnswer, uint256 rawTime, uint256 rawStep, uint256 rawMaxAge)
        public
    {
        uint256 maxAge = _maxAge(rawMaxAge);
        uint256 observedAt = _observedAt(rawTime);

        if (checker.evaluate(rawAnswer, 0, observedAt, maxAge) != IOHC.Health.INCOMPLETE_ROUND) {
            incompleteRoundNotReported = true;
        }

        uint256 ahead = 1 + (rawStep % MAX_STEP);
        if (
            checker.evaluate(rawAnswer, observedAt + ahead, observedAt, maxAge)
                != IOHC.Health.FUTURE_TIMESTAMP
        ) {
            futureTimestampNotReported = true;
        }

        _afterCall();
    }

    /// @notice The staleness threshold, from both sides and at zero age.
    ///
    /// @dev    THE off-by-one. `maxAge` is inclusive, so an age of exactly
    ///         `maxAge` is HEALTHY and `maxAge + 1` is STALE. Both are
    ///         CONSTRUCTED exactly on every draw rather than waited for: the
    ///         threshold is one value out of `2**256`, and a campaign that
    ///         reached it by chance would be reporting luck. What the draw varies
    ///         is WHERE the threshold sits — every `maxAge` the checker accepts,
    ///         against every plausible clock.
    function probeBoundary(int256 rawAnswer, uint256 rawTime, uint256 rawMaxAge) public {
        uint256 maxAge = _maxAge(rawMaxAge);
        uint256 observedAt = _observedAt(rawTime);
        int256 positive = _positive(rawAnswer);

        if (checker.evaluate(positive, observedAt - maxAge, observedAt, maxAge) != IOHC.Health.HEALTHY) {
            boundaryWrong = true;
        }
        if (checker.evaluate(positive, observedAt - maxAge - 1, observedAt, maxAge) != IOHC.Health.STALE) {
            boundaryWrong = true;
        }
        // `updatedAt == observedAt`: an age of zero, the freshest a round can be,
        // and the other end a comparison can be wrong about.
        if (checker.evaluate(positive, observedAt, observedAt, maxAge) != IOHC.Health.HEALTHY) {
            boundaryWrong = true;
        }

        _afterCall();
    }

    /// @notice The same round, read at two times, compared.
    ///
    /// @dev    A PAIR in one call rather than a value remembered between calls.
    ///         The verdict logic is pure, so there is nothing a sequence can
    ///         build up that a single call cannot express — but monotonicity is a
    ///         statement about two observation times at once, and passing both
    ///         together means the shrinker reduces to the exact pair that broke
    ///         it.
    ///
    ///         `updatedAt` is drawn from `[1, observedAt]`, so it is neither zero
    ///         nor in the future at EITHER observation time. Those two states are
    ///         excluded on purpose: with a fixed `updatedAt` in the future,
    ///         advancing the clock legitimately moves FUTURE_TIMESTAMP to HEALTHY,
    ///         which lowers severity without anything being wrong. The claim is
    ///         about a round that is already valid — once a round is real, time
    ///         only ever makes it worse.
    function probeAging(
        int256 rawAnswer,
        uint256 rawTime,
        uint256 rawSpan,
        uint256 rawStep,
        uint256 rawMaxAge
    ) public {
        uint256 maxAge = _maxAge(rawMaxAge);
        uint256 observedAt = _observedAt(rawTime);
        uint256 updatedAt = observedAt - (rawSpan % observedAt);
        uint256 step = 1 + (rawStep % MAX_STEP);

        IOHC.Health before = checker.evaluate(rawAnswer, updatedAt, observedAt, maxAge);
        IOHC.Health afterwards = checker.evaluate(rawAnswer, updatedAt, observedAt + step, maxAge);

        // The harness's own cast, never the checker's `severityOf` — see the note
        // at the top of this file.
        if (uint8(afterwards) < uint8(before)) agingImprovedHealth = true;

        _afterCall();
    }

    /// @notice Read every feed that cannot be read usefully, and require a verdict.
    /// @dev    Four distinct failures, not four copies of one: a revert carrying a
    ///         string, a revert with empty returndata, a successful call with the
    ///         wrong ABI shape, and an address with no code at all. A single mock
    ///         would demonstrate whichever one it happened to be.
    function probeUnreachableFeeds() public {
        _checkUnreachable(FEED_REVERT_WITH_REASON);
        _checkUnreachable(FEED_REVERT_EMPTY);
        _checkUnreachable(FEED_WRONG_SHAPE);
        _checkUnreachable(FEED_NO_CODE);
        _afterCall();
    }

    /// @notice Put the answering feed into an arbitrary state, then require the
    ///         feed-reading wrapper to agree with the pure logic.
    ///
    /// @dev    This is the seam the other properties cannot see. Eight of them
    ///         are claims about `evaluate`, which is pure and takes its
    ///         observation time as an argument. This one is the claim that
    ///         `check` — which reads a real feed and supplies `block.timestamp`
    ///         itself — reports exactly what `evaluate` would say about the same
    ///         numbers. A wrapper that read the wrong field, or compared against
    ///         the wrong feed's max age, would satisfy every other property here.
    function probeFeedRound(int256 rawAnswer, uint256 rawUpdatedAt, uint80 rawRoundId, uint8 rawDecimals)
        public
    {
        uint256 updatedAt = rawUpdatedAt % (MAX_TIME + 1);
        good.setRound(rawRoundId, rawAnswer, updatedAt);
        good.setDecimals(rawDecimals);

        IOHC.Report memory report = checker.check(FEED_GOOD);

        // The round data came back unchanged from what the feed holds.
        if (report.answer != rawAnswer) wrapperDisagreedWithPureLogic = true;
        if (report.updatedAt != updatedAt) wrapperDisagreedWithPureLogic = true;
        if (report.roundId != rawRoundId) wrapperDisagreedWithPureLogic = true;
        if (report.decimals != rawDecimals) wrapperDisagreedWithPureLogic = true;
        if (report.feed != address(good)) wrapperDisagreedWithPureLogic = true;
        if (report.maxAge != HARNESS_MAX_AGE) wrapperDisagreedWithPureLogic = true;
        if (report.checkedAt != block.timestamp) wrapperDisagreedWithPureLogic = true;

        // And the verdict is what the pure logic says about exactly those
        // numbers, measured at the time the report says it was measured.
        IOHC.Health expected =
            checker.evaluate(report.answer, report.updatedAt, report.checkedAt, report.maxAge);
        if (report.health != expected) wrapperDisagreedWithPureLogic = true;
        if (report.secondsSinceUpdate != checker.secondsSince(report.updatedAt, report.checkedAt)) {
            wrapperDisagreedWithPureLogic = true;
        }

        _afterCall();
    }

    /*//////////////////////////////////////////////////////////////
                              PREDICATES
    //////////////////////////////////////////////////////////////*/

    /// @notice A verdict is always the MOST SEVERE thing true about the round.
    ///
    /// @dev    The enum's ordinal is documented as a severity ranking, and this
    ///         is that documentation being load-bearing. When several things are
    ///         wrong at once — an incomplete round whose answer is also negative,
    ///         a stale round whose timestamp is also in the future — a consumer
    ///         must be told the worst of them, not whichever one the
    ///         implementation happened to test first. Reordering the branches in
    ///         `evaluate` breaks this and nothing else here would notice.
    ///
    ///         Checked by deriving the applicable conditions independently and
    ///         taking their maximum severity, which is a different expression of
    ///         the rule from the early-return chain that implements it.
    function echidna_verdict_is_the_most_severe_applicable_state() public view returns (bool) {
        return !verdictNotMostSevere;
    }

    /// @notice Time passing never makes a verdict healthier.
    ///
    /// @dev    The direction of the whole check. A monitor that could be made to
    ///         report a feed as healthier by simply waiting would be worse than
    ///         no monitor, because the reading it gives improves exactly as the
    ///         data it describes decays. Claimed for rounds that are already
    ///         valid — see `probeAging` for why the future-timestamp case is
    ///         excluded rather than overlooked.
    function echidna_age_never_improves_health() public view returns (bool) {
        return !agingImprovedHealth;
    }

    /// @notice A complete, positive, in-date round is HEALTHY.
    ///
    /// @dev    The one property that can only fail in the direction of FALSE
    ///         ALARM, and it is here because the other eight cannot catch that.
    ///         A checker that returned STALE unconditionally would satisfy every
    ///         "never HEALTHY when X" claim in this file perfectly. Protocols
    ///         that treat an unhealthy verdict as a reason to halt would then
    ///         halt permanently, so being wrong in this direction is not the safe
    ///         kind of wrong.
    function echidna_fresh_positive_complete_is_healthy() public view returns (bool) {
        return !freshRoundNotHealthy;
    }

    /// @notice A non-positive answer is never HEALTHY, at any age.
    ///
    /// @dev    `answer` is signed, and negative values are not hypothetical — a
    ///         production feed has printed one. The damage is done downstream: a
    ///         consumer that casts to `uint256` without checking turns a small
    ///         negative price into a number near `2**256`, and any collateral
    ///         valuation built on it is then arbitrarily wrong in the attacker's
    ///         favour. Checked at an IN-DATE `updatedAt`, so staleness is not
    ///         what makes the verdict unhealthy.
    function echidna_non_positive_answer_is_never_healthy() public view returns (bool) {
        return !nonPositiveWasHealthy;
    }

    /// @notice `updatedAt == 0` is reported as INCOMPLETE_ROUND.
    ///
    /// @dev    Stronger than "never HEALTHY" on purpose. Zero is the one value
    ///         where age cannot be computed at all rather than merely being
    ///         large, and a checker that folded it into STALE would report a
    ///         number — `block.timestamp` — as the age of a round that has no
    ///         age. The distinction matters to a consumer deciding whether to
    ///         wait for the next round or to stop trusting the feed.
    function echidna_incomplete_round_is_reported() public view returns (bool) {
        return !incompleteRoundNotReported;
    }

    /// @notice A future `updatedAt` is reported as FUTURE_TIMESTAMP.
    ///
    /// @dev    The case that breaks naive consumers two different ways from the
    ///         same line of code. `block.timestamp - updatedAt` in checked
    ///         arithmetic reverts, taking down whatever was pricing; unchecked,
    ///         it underflows to a near-`2**256` age. Reported as its own state
    ///         rather than folded into STALE because the cause is different: a
    ///         stale feed has stopped being updated, while this one is
    ///         misreporting, and only one of those resolves itself.
    function echidna_future_timestamp_is_reported() public view returns (bool) {
        return !futureTimestampNotReported;
    }

    /// @notice The staleness threshold is exact in both directions.
    ///
    /// @dev    THE property. `maxAge` is inclusive: an age of exactly `maxAge` is
    ///         HEALTHY, and STALE begins one second later. Off-by-one on that
    ///         comparison is the entire bug class this contract exists to get
    ///         right, and it is invisible in testing that samples the interior of
    ///         a range — both wrong versions agree with the right one everywhere
    ///         except on a single value. So both sides of the threshold are
    ///         constructed exactly, on every draw, along with the zero-age case
    ///         at the other end.
    function echidna_max_age_boundary_is_exact() public view returns (bool) {
        return !boundaryWrong;
    }

    /// @notice A feed that cannot be read usefully yields UNAVAILABLE, and never
    ///         reverts the caller.
    ///
    /// @dev    Both halves are asserted by the same predicate because a violation
    ///         of the second one prevents the first from being observed at all: if
    ///         `check` reverted, the entry point would revert with it, which
    ///         `fail_on_revert = true` turns into a loud failure rather than a
    ///         quiet one. An explorer whose whole purpose is reporting broken
    ///         feeds must not break on one.
    ///
    ///         Four distinct failure shapes are covered — see
    ///         `probeUnreachableFeeds`. The wrong-ABI-shape one is why the
    ///         implementation uses a length-checked `staticcall` rather than
    ///         `try/catch`: that call SUCCEEDS, so there is nothing for a `catch`
    ///         clause to catch, and the decode is what would revert.
    function echidna_unreachable_feed_is_unavailable() public view returns (bool) {
        return !unreachableFeedNotUnavailable;
    }

    /// @notice Reading a real feed agrees with the pure logic on the same numbers.
    ///
    /// @dev    The seam between the two halves of the contract. Eight properties
    ///         above constrain `evaluate`, which is pure and cannot read a feed
    ///         or a clock. This one constrains the wrapper that does both: that
    ///         it passes through the round data unaltered, uses the max age
    ///         belonging to the feed it was asked about, measures against the
    ///         timestamp it reports measuring against, and returns the verdict
    ///         the pure logic gives for those inputs. A wrapper reading
    ///         `startedAt` instead of `updatedAt` would pass everything else here.
    function echidna_feed_verdict_matches_pure_logic() public view returns (bool) {
        return !wrapperDisagreedWithPureLogic;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Derives which conditions apply from the raw round independently of
    ///      the implementation, takes the most severe, and compares.
    ///
    ///      Written as an explicit maximum over applicable states rather than as
    ///      a chain of early returns, so it is a genuinely different expression
    ///      of the rule and not a transcription of the code it checks.
    function _checkMostSevere(int256 answer, uint256 updatedAt, uint256 observedAt, uint256 maxAge) internal {
        bool incomplete = updatedAt == 0;
        bool future = updatedAt > observedAt;
        bool nonPositive = answer <= 0;
        // Staleness is only a meaningful question when there is a real, past
        // timestamp to measure from. When there is not, one of the two more
        // severe states above applies, so leaving this false cannot change the
        // maximum.
        bool stale = !incomplete && !future && observedAt - updatedAt > maxAge;

        IOHC.Health expected = IOHC.Health.HEALTHY;
        if (stale) expected = _moreSevere(expected, IOHC.Health.STALE);
        if (nonPositive) expected = _moreSevere(expected, IOHC.Health.NON_POSITIVE_ANSWER);
        if (future) expected = _moreSevere(expected, IOHC.Health.FUTURE_TIMESTAMP);
        if (incomplete) expected = _moreSevere(expected, IOHC.Health.INCOMPLETE_ROUND);

        if (checker.evaluate(answer, updatedAt, observedAt, maxAge) != expected) {
            verdictNotMostSevere = true;
        }
    }

    /// @dev Reads one feed that cannot answer usefully and requires UNAVAILABLE.
    ///      Every other field of the report is required to be its zero value: a
    ///      checker that reported UNAVAILABLE while also handing back a stale
    ///      answer it happened to have would invite a consumer to use it.
    function _checkUnreachable(uint256 index) internal {
        IOHC.Report memory report = checker.check(index);
        if (report.health != IOHC.Health.UNAVAILABLE) unreachableFeedNotUnavailable = true;
        if (report.answer != 0) unreachableFeedNotUnavailable = true;
        if (report.updatedAt != 0) unreachableFeedNotUnavailable = true;
        if (report.roundId != 0) unreachableFeedNotUnavailable = true;
        if (report.secondsSinceUpdate != 0) unreachableFeedNotUnavailable = true;
    }

    /// @dev Runs after every entry point: re-reads ONE unreachable feed,
    ///      round-robin.
    ///
    ///      Strictly redundant against the harness as written — those feeds
    ///      cannot start answering. It is here because it is not redundant
    ///      against the harness as SUBCLASSED: `test/Invariants.t.sol` installs a
    ///      broken checker after construction, and this is what notices. A check
    ///      that only ever runs inside a constructor is a check that cannot be
    ///      demonstrated to work.
    ///
    ///      One feed per call rather than all four, because this cost is paid on
    ///      every call of every sequence of the campaign.
    function _afterCall() internal {
        _checkUnreachable(FIRST_UNREACHABLE + (cursor % UNREACHABLE_FEED_COUNT));
        cursor++;
    }

    /// @dev The more severe of two states, by the enum's own ordinal.
    function _moreSevere(IOHC.Health a, IOHC.Health b) internal pure returns (IOHC.Health) {
        return uint8(a) >= uint8(b) ? a : b;
    }

    /// @dev A max age in `[1, MAX_AGE_BOUND]` — every value the checker's
    ///      constructor accepts, and nothing it would reject.
    function _maxAge(uint256 raw) internal pure returns (uint256) {
        return 1 + (raw % MAX_AGE_BOUND);
    }

    /// @dev An observed time in `[MIN_OBSERVED_AT, MAX_TIME]`. See
    ///      MIN_OBSERVED_AT for why the floor is where it is.
    function _observedAt(uint256 raw) internal pure returns (uint256) {
        return MIN_OBSERVED_AT + (raw % (MAX_TIME - MIN_OBSERVED_AT));
    }

    /// @dev Any draw turned into a strictly positive answer.
    ///      `type(int256).min` is special-cased because negating it overflows —
    ///      the one input where the obvious `-x` is wrong.
    function _positive(int256 x) internal pure returns (int256) {
        if (x > 0) return x;
        if (x == 0) return 1;
        if (x == type(int256).min) return type(int256).max;
        return -x;
    }

    /// @dev Any draw turned into a non-positive answer. Zero stays zero, which is
    ///      itself a case worth reaching: `answer == 0` is non-positive and a
    ///      `< 0` test would miss it.
    function _nonPositive(int256 x) internal pure returns (int256) {
        if (x <= 0) return x;
        return -x;
    }
}
