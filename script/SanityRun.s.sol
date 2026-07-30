// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IAggregatorV3} from "../src/IAggregatorV3.sol";
import {IOracleHealthChecker as IOHC} from "../src/IOracleHealthChecker.sol";
import {OracleHealthChecker} from "../src/OracleHealthChecker.sol";

/// @title SanityRun — read the DEPLOYED contract and check it against arithmetic
///        done here.
///
/// @notice `eth_call` only. Nothing is broadcast, no key is read, no gas is
///         spent. This is the step that turns "it compiled and the tests passed"
///         into "the bytecode at that address, reading those feeds, on that
///         chain, answers correctly right now".
///
/// @dev    WHY THIS RECOMPUTES INSTEAD OF PRINTING. Asking the contract for its
///         verdict and printing it proves only that it returned something. So
///         this script reads the RAW round data straight off each aggregator,
///         derives the expected verdict here with an independent expression of
///         the rule, and REVERTS on any disagreement. A green run means two
///         implementations agreed about four live feeds.
///
/// @dev    It also reads `description()` off each aggregator and requires it to
///         match the pair the README claims is at that address. A registry
///         pointing at a live, healthy, correctly-answering feed for the WRONG
///         ASSET is the failure this catches, and no health check would notice
///         it: the feed is perfectly healthy, it is just not the price anyone
///         thinks it is.
///
/// Run:
///   CHECKER=0x... forge script script/SanityRun.s.sol:SanityRun --rpc-url "$DEMO_RPC_URL"
contract SanityRun is Script {
    uint256 internal constant EXPECTED_CHAIN_ID = 84532;

    /// @dev The pair names measured on chain before deployment, in registry
    ///      order. Restated here so this script can hold the contract to them.
    function expectedDescriptions() internal pure returns (string[] memory names) {
        names = new string[](4);
        names[0] = "BTC / USD";
        names[1] = "ETH / USD";
        names[2] = "LINK / USD";
        names[3] = "USDC / USD";
    }

    function run() external view {
        require(block.chainid == EXPECTED_CHAIN_ID, "SanityRun: not Base Sepolia 84532");

        OracleHealthChecker checker = OracleHealthChecker(vm.envAddress("CHECKER"));
        string[] memory names = expectedDescriptions();

        uint256 count = checker.feedCount();
        require(count == names.length, "SanityRun: feed count does not match the expected registry");

        console2.log("checker:", address(checker));
        console2.log("chain id:", block.chainid);
        console2.log("block timestamp:", block.timestamp);
        console2.log("feeds:", count);

        for (uint256 i = 0; i < count; i++) {
            _checkFeed(checker, i, names[i]);
        }

        console2.log("SANITY RUN: every feed's on-chain verdict matched local computation");
    }

    function _checkFeed(OracleHealthChecker checker, uint256 index, string memory expectedName)
        internal
        view
    {
        IOHC.FeedConfig memory config = checker.feedAt(index);
        IOHC.Report memory report = checker.check(index);

        // --- the feed is the asset the README says it is --------------------
        string memory actualName = IAggregatorV3(config.feed).description();
        require(
            keccak256(bytes(actualName)) == keccak256(bytes(expectedName)),
            "SanityRun: feed description does not match the expected pair"
        );

        // --- the round data, read straight off the aggregator ---------------
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = IAggregatorV3(config.feed).latestRoundData();
        uint8 decimals = IAggregatorV3(config.feed).decimals();

        // The contract must be reporting the same numbers it was given.
        require(report.feed == config.feed, "SanityRun: report names the wrong feed");
        require(report.roundId == roundId, "SanityRun: roundId disagrees");
        require(report.answer == answer, "SanityRun: answer disagrees");
        require(report.updatedAt == updatedAt, "SanityRun: updatedAt disagrees");
        require(report.decimals == decimals, "SanityRun: decimals disagrees");
        require(report.maxAge == config.maxAge, "SanityRun: maxAge disagrees");

        // --- the verdict, derived here rather than trusted ------------------
        uint8 expected = _expectedHealth(answer, updatedAt, block.timestamp, config.maxAge);
        require(
            uint8(report.health) == expected, "SanityRun: on-chain verdict disagrees with local computation"
        );

        uint256 age = updatedAt == 0 || updatedAt > block.timestamp ? 0 : block.timestamp - updatedAt;
        require(report.secondsSinceUpdate == age, "SanityRun: reported age disagrees");

        console2.log("---");
        console2.log(actualName);
        console2.log("  feed        :", config.feed);
        console2.log("  answer      :", answer);
        console2.log("  decimals    :", decimals);
        console2.log("  updatedAt   :", updatedAt);
        console2.log("  age (s)     :", age);
        console2.log("  maxAge (s)  :", config.maxAge);
        console2.log("  health      :", _healthName(report.health));
    }

    /// @dev The rule, restated. Written as a severity scan rather than copied
    ///      from `evaluate`'s early-return chain, so agreement between the two is
    ///      evidence rather than tautology.
    function _expectedHealth(int256 answer, uint256 updatedAt, uint256 observedAt, uint256 maxAge)
        internal
        pure
        returns (uint8)
    {
        bool incomplete = updatedAt == 0;
        bool future = updatedAt > observedAt;
        bool nonPositive = answer <= 0;
        bool stale = !incomplete && !future && observedAt - updatedAt > maxAge;

        uint8 worst = uint8(IOHC.Health.HEALTHY);
        if (stale) worst = _max(worst, uint8(IOHC.Health.STALE));
        if (nonPositive) worst = _max(worst, uint8(IOHC.Health.NON_POSITIVE_ANSWER));
        if (future) worst = _max(worst, uint8(IOHC.Health.FUTURE_TIMESTAMP));
        if (incomplete) worst = _max(worst, uint8(IOHC.Health.INCOMPLETE_ROUND));
        return worst;
    }

    function _max(uint8 a, uint8 b) internal pure returns (uint8) {
        return a >= b ? a : b;
    }

    function _healthName(IOHC.Health health) internal pure returns (string memory) {
        if (health == IOHC.Health.HEALTHY) return "HEALTHY";
        if (health == IOHC.Health.STALE) return "STALE";
        if (health == IOHC.Health.NON_POSITIVE_ANSWER) return "NON_POSITIVE_ANSWER";
        if (health == IOHC.Health.FUTURE_TIMESTAMP) return "FUTURE_TIMESTAMP";
        if (health == IOHC.Health.INCOMPLETE_ROUND) return "INCOMPLETE_ROUND";
        return "UNAVAILABLE";
    }
}
