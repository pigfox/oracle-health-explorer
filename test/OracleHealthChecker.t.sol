// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IOracleHealthChecker as IOHC} from "../src/IOracleHealthChecker.sol";
import {OracleHealthChecker} from "../src/OracleHealthChecker.sol";
import {
    HealthyRoundDecimalsRevertAggregator,
    HealthyRoundDecimalsWrongShapeAggregator,
    MockAggregator,
    RevertingAggregator,
    TryCatchConsumer,
    WrongShapeAggregator
} from "./mocks/MockAggregator.sol";

/// @title OracleHealthCheckerTest — the checker, stated case by case.
///
/// @notice The property harness claims things for whole ranges. This file pins
///         the individual answers a reader can check by eye: what each verdict
///         state looks like, where exactly the staleness boundary falls, and
///         which inputs the constructor refuses. Both are needed — a range claim
///         that happens to be vacuous still passes, and a named case cannot be
///         vacuous.
contract OracleHealthCheckerTest is Test {
    /// @dev A realistic Base Sepolia timestamp. The tests warp to it so ages are
    ///      computed against a clock that resembles the one production uses,
    ///      rather than against Foundry's default block 1.
    uint256 internal constant NOW = 1_785_421_112;

    /// @dev BTC/USD's measured max age in this repo's deployment: a one-hour
    ///      heartbeat plus fifteen minutes of grace.
    uint256 internal constant MAX_AGE = 4500;

    /// @dev A plausible eight-decimal answer.
    int256 internal constant ANSWER = 6470306000000;

    uint8 internal constant DECIMALS = 8;

    MockAggregator internal feed;
    OracleHealthChecker internal checker;

    function setUp() public {
        vm.warp(NOW);
        feed = new MockAggregator("BTC / USD", DECIMALS);
        feed.setRound(1, ANSWER, NOW);
        checker = new OracleHealthChecker(_configs(address(feed), MAX_AGE));
    }

    function _configs(address feed_, uint256 maxAge_)
        internal
        pure
        returns (IOHC.FeedConfig[] memory configs)
    {
        configs = new IOHC.FeedConfig[](1);
        configs[0] = IOHC.FeedConfig(feed_, maxAge_);
    }

    /*//////////////////////////////////////////////////////////////
                        THE VERDICT LOGIC, BY CASE
    //////////////////////////////////////////////////////////////*/

    function test_healthyRound() public view {
        assertEq(uint8(checker.evaluate(ANSWER, NOW - 60, NOW, MAX_AGE)), uint8(IOHC.Health.HEALTHY));
    }

    function test_staleRound() public view {
        assertEq(uint8(checker.evaluate(ANSWER, NOW - MAX_AGE - 1, NOW, MAX_AGE)), uint8(IOHC.Health.STALE));
    }

    function test_negativeAnswer() public view {
        assertEq(uint8(checker.evaluate(-1, NOW - 60, NOW, MAX_AGE)), uint8(IOHC.Health.NON_POSITIVE_ANSWER));
    }

    /// @dev Zero is non-positive too. A `< 0` test would let it through, and a
    ///      zero price is just as unusable as a negative one.
    function test_zeroAnswerIsNonPositive() public view {
        assertEq(uint8(checker.evaluate(0, NOW - 60, NOW, MAX_AGE)), uint8(IOHC.Health.NON_POSITIVE_ANSWER));
    }

    function test_incompleteRound() public view {
        assertEq(uint8(checker.evaluate(ANSWER, 0, NOW, MAX_AGE)), uint8(IOHC.Health.INCOMPLETE_ROUND));
    }

    function test_futureTimestamp() public view {
        assertEq(uint8(checker.evaluate(ANSWER, NOW + 1, NOW, MAX_AGE)), uint8(IOHC.Health.FUTURE_TIMESTAMP));
    }

    /*//////////////////////////////////////////////////////////////
                              THE BOUNDARY
    //////////////////////////////////////////////////////////////*/
    // The whole bug class, pinned by name. `maxAge` is INCLUSIVE.

    function test_ageExactlyMaxAgeIsHealthy() public view {
        assertEq(
            uint8(checker.evaluate(ANSWER, NOW - MAX_AGE, NOW, MAX_AGE)),
            uint8(IOHC.Health.HEALTHY),
            "an age of exactly maxAge must be healthy"
        );
    }

    function test_oneSecondPastMaxAgeIsStale() public view {
        assertEq(
            uint8(checker.evaluate(ANSWER, NOW - MAX_AGE - 1, NOW, MAX_AGE)),
            uint8(IOHC.Health.STALE),
            "one second past maxAge must be stale"
        );
    }

    function test_oneSecondInsideMaxAgeIsHealthy() public view {
        assertEq(
            uint8(checker.evaluate(ANSWER, NOW - MAX_AGE + 1, NOW, MAX_AGE)),
            uint8(IOHC.Health.HEALTHY),
            "one second inside maxAge must be healthy"
        );
    }

    function test_zeroAgeIsHealthy() public view {
        assertEq(uint8(checker.evaluate(ANSWER, NOW, NOW, MAX_AGE)), uint8(IOHC.Health.HEALTHY));
    }

    /*//////////////////////////////////////////////////////////////
                        MOST SEVERE STATE WINS
    //////////////////////////////////////////////////////////////*/

    /// @dev An incomplete round whose answer is also negative. INCOMPLETE_ROUND
    ///      outranks NON_POSITIVE_ANSWER, so that is what a consumer is told.
    function test_incompleteOutranksNonPositive() public view {
        assertEq(uint8(checker.evaluate(-5, 0, NOW, MAX_AGE)), uint8(IOHC.Health.INCOMPLETE_ROUND));
    }

    /// @dev A future timestamp on a negative answer.
    function test_futureOutranksNonPositive() public view {
        assertEq(uint8(checker.evaluate(-5, NOW + 10, NOW, MAX_AGE)), uint8(IOHC.Health.FUTURE_TIMESTAMP));
    }

    /// @dev A stale round whose answer is also negative. The sign problem is the
    ///      more severe of the two, and it is the one that would do the damage.
    function test_nonPositiveOutranksStale() public view {
        assertEq(
            uint8(checker.evaluate(-5, NOW - MAX_AGE - 1000, NOW, MAX_AGE)),
            uint8(IOHC.Health.NON_POSITIVE_ANSWER)
        );
    }

    /*//////////////////////////////////////////////////////////////
                             AGE REPORTING
    //////////////////////////////////////////////////////////////*/

    function test_secondsSinceNormalCase() public view {
        assertEq(checker.secondsSince(NOW - 300, NOW), 300);
    }

    /// @dev Zero, not `block.timestamp`. An incomplete round has no age.
    function test_secondsSinceIncompleteRoundIsZero() public view {
        assertEq(checker.secondsSince(0, NOW), 0);
    }

    /// @dev Zero, not an underflow. This is the line that would revert a naive
    ///      consumer under checked arithmetic.
    function test_secondsSinceFutureTimestampIsZero() public view {
        assertEq(checker.secondsSince(NOW + 500, NOW), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          THE SEVERITY RANKING
    //////////////////////////////////////////////////////////////*/

    /// @dev `severityOf` is documented as the enum's own ordinal. The property
    ///      harness deliberately does NOT route its comparisons through this
    ///      function — it uses its own cast — so that the harness's judgement
    ///      cannot be talked out of a failure by a lying implementation. Which
    ///      leaves this as the place the agreement is actually asserted.
    function test_severityIsTheEnumOrdinalAndStrictlyIncreasing() public view {
        assertEq(checker.severityOf(IOHC.Health.HEALTHY), 0);
        assertEq(checker.severityOf(IOHC.Health.STALE), 1);
        assertEq(checker.severityOf(IOHC.Health.NON_POSITIVE_ANSWER), 2);
        assertEq(checker.severityOf(IOHC.Health.FUTURE_TIMESTAMP), 3);
        assertEq(checker.severityOf(IOHC.Health.INCOMPLETE_ROUND), 4);
        assertEq(checker.severityOf(IOHC.Health.UNAVAILABLE), 5);
    }

    /*//////////////////////////////////////////////////////////////
                        READING A REGISTERED FEED
    //////////////////////////////////////////////////////////////*/

    function test_checkReadsTheFeedAndReportsEveryInput() public view {
        IOHC.Report memory report = checker.check(0);

        assertEq(uint8(report.health), uint8(IOHC.Health.HEALTHY));
        assertEq(report.feed, address(feed));
        assertEq(report.decimals, DECIMALS);
        assertEq(report.roundId, 1);
        assertEq(report.answer, ANSWER);
        assertEq(report.updatedAt, NOW);
        assertEq(report.checkedAt, NOW);
        assertEq(report.secondsSinceUpdate, 0);
        assertEq(report.maxAge, MAX_AGE);
    }

    /// @dev The report carries every input to the verdict, so a reader can redo
    ///      the arithmetic instead of trusting the answer. This is that
    ///      recomputation, performed.
    function test_theReportIsSelfVerifying() public {
        vm.warp(NOW + 1000);
        IOHC.Report memory report = checker.check(0);

        assertEq(report.secondsSinceUpdate, 1000);
        assertEq(
            uint8(report.health),
            uint8(checker.evaluate(report.answer, report.updatedAt, report.checkedAt, report.maxAge))
        );
    }

    function test_checkReportsStaleAfterTheHeartbeatLapses() public {
        vm.warp(NOW + MAX_AGE + 1);
        assertEq(uint8(checker.check(0).health), uint8(IOHC.Health.STALE));
    }

    function test_feedCountAndFeedAt() public view {
        assertEq(checker.feedCount(), 1);
        assertEq(checker.feedAt(0).feed, address(feed));
        assertEq(checker.feedAt(0).maxAge, MAX_AGE);
    }

    function test_feedAtRevertsPastTheEnd() public {
        vm.expectRevert(abi.encodeWithSelector(OracleHealthChecker.NoSuchFeed.selector, 1, 1));
        checker.feedAt(1);
    }

    function test_checkRevertsPastTheEnd() public {
        vm.expectRevert(abi.encodeWithSelector(OracleHealthChecker.NoSuchFeed.selector, 3, 1));
        checker.check(3);
    }

    /*//////////////////////////////////////////////////////////////
                        A FEED THAT CANNOT BE READ
    //////////////////////////////////////////////////////////////*/
    // Four distinct shapes, all UNAVAILABLE, none of them reverting the caller.

    function test_revertingFeedIsUnavailable() public {
        feed.setReverting(true);
        _assertUnavailable(checker.check(0));
    }

    function test_feedRevertingWithEmptyReturndataIsUnavailable() public {
        OracleHealthChecker c = new OracleHealthChecker(_configs(address(new RevertingAggregator()), MAX_AGE));
        _assertUnavailable(c.check(0));
    }

    function test_feedWithTheWrongAbiShapeIsUnavailable() public {
        OracleHealthChecker c =
            new OracleHealthChecker(_configs(address(new WrongShapeAggregator()), MAX_AGE));
        _assertUnavailable(c.check(0));
    }

    function test_addressWithNoCodeIsUnavailable() public {
        OracleHealthChecker c = new OracleHealthChecker(_configs(address(0xDEAD), MAX_AGE));
        _assertUnavailable(c.check(0));
    }

    /// @dev UNAVAILABLE means no data, and the report says so: every round field
    ///      is zero. A checker that reported UNAVAILABLE while still handing back
    ///      the last answer it saw would invite a consumer to use it anyway.
    function _assertUnavailable(IOHC.Report memory report) internal pure {
        assertEq(uint8(report.health), uint8(IOHC.Health.UNAVAILABLE));
        assertEq(report.answer, 0);
        assertEq(report.updatedAt, 0);
        assertEq(report.roundId, 0);
        assertEq(report.secondsSinceUpdate, 0);
        assertEq(report.decimals, 0);
    }

    /*//////////////////////////////////////////////////////////////
                     DECIMALS IS PRESENTATIONAL, NOT FATAL
    //////////////////////////////////////////////////////////////*/
    // A feed whose round data is fine but whose `decimals()` is not still gets a
    // real verdict. The verdict is derived from `latestRoundData` alone.

    function test_decimalsRevertingStillYieldsAVerdict() public {
        OracleHealthChecker c = new OracleHealthChecker(
            _configs(address(new HealthyRoundDecimalsRevertAggregator(ANSWER, NOW)), MAX_AGE)
        );
        IOHC.Report memory report = c.check(0);
        assertEq(uint8(report.health), uint8(IOHC.Health.HEALTHY), "the round data was fine");
        assertEq(report.decimals, 0, "decimals reported as the unknown sentinel");
        assertEq(report.answer, ANSWER);
    }

    function test_decimalsWithTheWrongShapeStillYieldsAVerdict() public {
        OracleHealthChecker c = new OracleHealthChecker(
            _configs(address(new HealthyRoundDecimalsWrongShapeAggregator(ANSWER, NOW)), MAX_AGE)
        );
        IOHC.Report memory report = c.check(0);
        assertEq(uint8(report.health), uint8(IOHC.Health.HEALTHY));
        assertEq(report.decimals, 0);
    }

    /*//////////////////////////////////////////////////////////////
              WHY `staticcall` AND NOT `try/catch` — DEMONSTRATED
    //////////////////////////////////////////////////////////////*/

    /// @dev The contract's design note says a `catch` clause does not catch a
    ///      returndata DECODE failure, and that this is why the reads are
    ///      length-checked `staticcall`s. That is a claim about Solidity, and an
    ///      unverified claim in a comment is how a design outlives its reason.
    ///
    ///      So: the same feed, read both ways. The naive `try/catch` consumer
    ///      reverts on it. The checker returns UNAVAILABLE. If a future compiler
    ///      makes `catch` cover this, this test fails and the design note gets
    ///      revisited deliberately rather than silently.
    function test_tryCatchDoesNotSurviveAWrongShapedFeedButTheCheckerDoes() public {
        address wrongShape = address(new WrongShapeAggregator());

        TryCatchConsumer naive = new TryCatchConsumer();
        vm.expectRevert();
        naive.readNaively(wrongShape);

        OracleHealthChecker c = new OracleHealthChecker(_configs(wrongShape, MAX_AGE));
        assertEq(uint8(c.check(0).health), uint8(IOHC.Health.UNAVAILABLE));
    }

    /*//////////////////////////////////////////////////////////////
                      WHAT THE CONSTRUCTOR REFUSES
    //////////////////////////////////////////////////////////////*/
    // Each of these would deploy a checker that reports something untrue, so none
    // of them is allowed to deploy at all. There is no setter, so a mistake here
    // is permanent — which is the argument for refusing rather than clamping.

    function test_rejectsAnEmptyRegistry() public {
        IOHC.FeedConfig[] memory configs = new IOHC.FeedConfig[](0);
        vm.expectRevert(OracleHealthChecker.NoFeeds.selector);
        new OracleHealthChecker(configs);
    }

    function test_rejectsMoreFeedsThanTheCeiling() public {
        uint256 tooMany = checker.MAX_FEEDS() + 1;
        IOHC.FeedConfig[] memory configs = new IOHC.FeedConfig[](tooMany);
        for (uint256 i = 0; i < tooMany; i++) {
            configs[i] = IOHC.FeedConfig(address(uint160(i + 1)), MAX_AGE);
        }
        vm.expectRevert(
            abi.encodeWithSelector(OracleHealthChecker.TooManyFeeds.selector, tooMany, checker.MAX_FEEDS())
        );
        new OracleHealthChecker(configs);
    }

    function test_rejectsTheZeroAddress() public {
        IOHC.FeedConfig[] memory configs = _configs(address(0), MAX_AGE);
        vm.expectRevert(abi.encodeWithSelector(OracleHealthChecker.ZeroFeedAddress.selector, 0));
        new OracleHealthChecker(configs);
    }

    /// @dev A zero max age would make every round STALE the second after it was
    ///      published, which is a checker that reports nothing useful forever.
    function test_rejectsAZeroMaxAge() public {
        IOHC.FeedConfig[] memory configs = _configs(address(feed), 0);
        vm.expectRevert(abi.encodeWithSelector(OracleHealthChecker.ZeroMaxAge.selector, 0));
        new OracleHealthChecker(configs);
    }

    /// @dev And a max age above the ceiling would make every round HEALTHY
    ///      forever, which is worse: it looks like a working check.
    function test_rejectsAMaxAgeAboveTheCeiling() public {
        uint256 tooLarge = checker.MAX_CONFIGURABLE_MAX_AGE() + 1;
        IOHC.FeedConfig[] memory configs = _configs(address(feed), tooLarge);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleHealthChecker.MaxAgeTooLarge.selector, 0, tooLarge, checker.MAX_CONFIGURABLE_MAX_AGE()
            )
        );
        new OracleHealthChecker(configs);
    }

    /// @dev The same feed twice would give it two max ages, and the verdict a
    ///      reader got would depend on which index they happened to ask about.
    function test_rejectsTheSameFeedTwice() public {
        IOHC.FeedConfig[] memory configs = new IOHC.FeedConfig[](2);
        configs[0] = IOHC.FeedConfig(address(feed), MAX_AGE);
        configs[1] = IOHC.FeedConfig(address(feed), MAX_AGE * 2);
        vm.expectRevert(abi.encodeWithSelector(OracleHealthChecker.DuplicateFeed.selector, 1, address(feed)));
        new OracleHealthChecker(configs);
    }

    /// @dev The ceiling itself is accepted — the rejection is strictly above it.
    function test_acceptsAMaxAgeExactlyAtTheCeiling() public {
        IOHC.FeedConfig[] memory configs = _configs(address(feed), checker.MAX_CONFIGURABLE_MAX_AGE());
        OracleHealthChecker c = new OracleHealthChecker(configs);
        assertEq(c.feedAt(0).maxAge, checker.MAX_CONFIGURABLE_MAX_AGE());
    }

    /// @dev And exactly MAX_FEEDS is accepted, for the same reason.
    function test_acceptsExactlyTheMaximumNumberOfFeeds() public {
        uint256 max = checker.MAX_FEEDS();
        IOHC.FeedConfig[] memory configs = new IOHC.FeedConfig[](max);
        for (uint256 i = 0; i < max; i++) {
            configs[i] = IOHC.FeedConfig(address(uint160(i + 1)), MAX_AGE);
        }
        OracleHealthChecker c = new OracleHealthChecker(configs);
        assertEq(c.feedCount(), max);
    }

    /*//////////////////////////////////////////////////////////////
                       PER-FEED MAX AGE IS THE POINT
    //////////////////////////////////////////////////////////////*/

    /// @dev The measured reason the registry is per-feed rather than global.
    ///      USDC/USD on Base Sepolia moves on a ~24-hour heartbeat while BTC/USD
    ///      moves every few minutes. At an age of six hours the same round data
    ///      is STALE against BTC's threshold and HEALTHY against USDC's — and
    ///      both verdicts are correct. A single estate-wide threshold cannot say
    ///      that, which is the whole argument for the design.
    function test_theSameAgeIsStaleForOneFeedAndHealthyForAnother() public view {
        uint256 sixHours = 6 hours;
        uint256 usdcMaxAge = 25 hours;

        assertEq(
            uint8(checker.evaluate(ANSWER, NOW - sixHours, NOW, MAX_AGE)),
            uint8(IOHC.Health.STALE),
            "six hours is stale for a feed that updates every few minutes"
        );
        assertEq(
            uint8(checker.evaluate(ANSWER, NOW - sixHours, NOW, usdcMaxAge)),
            uint8(IOHC.Health.HEALTHY),
            "six hours is fine for a feed on a 24-hour heartbeat"
        );
    }
}
