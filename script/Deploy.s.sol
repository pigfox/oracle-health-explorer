// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IOracleHealthChecker as IOHC} from "../src/IOracleHealthChecker.sol";
import {OracleHealthChecker} from "../src/OracleHealthChecker.sol";

/// @title Deploy — OracleHealthChecker to Base Sepolia (84532).
///
/// @notice DIRECT-CHAIN ONLY. This script broadcasts to Base Sepolia and nowhere
///         else. The four feeds below are live aggregators on that chain, each
///         verified by calling `decimals()`, `description()` and
///         `latestRoundData()` on it BEFORE it was written here — see the feed
///         table in the README for what each one answered and when.
///
/// @dev    THE MAX AGES ARE THE WHOLE CONFIGURATION. There is no setter, so what
///         is passed here is what the contract means for the rest of its life.
///         Each one is that feed's heartbeat plus a margin, and the four are not
///         the same number because the feeds are not the same feed:
///
///           BTC/USD, ETH/USD, LINK/USD — measured republishing every 150 to 230
///           seconds, driven by price deviation. Judged against 4,500 s: a
///           one-hour heartbeat plus fifteen minutes of grace, which is roughly
///           twenty times their observed cadence.
///
///           USDC/USD — measured republishing on a ~24-hour heartbeat, confirmed
///           across two consecutive intervals at 86,424 s and 86,416 s. Judged
///           against 90,000 s: the heartbeat plus an hour.
///
///         Applying BTC's threshold to USDC would report it stale for almost all
///         of every day. Applying USDC's to BTC would call a feed that had been
///         frozen for twenty hours healthy. Neither is a staleness check, and
///         that is the argument for the registry being per-feed.
///
/// @dev    KEY HANDLING. The deployer key is read from a repo-local `.env` via
///         `vm.envUint` and never appears in argv, in a log line, or in a
///         tracked file. `.gitignore` covered `.env` before any key material
///         existed in this working copy.
///
/// Run:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url "$DEMO_RPC_URL" --broadcast --verify
contract Deploy is Script {
    // --- the four measured feeds on Base Sepolia 84532 ----------------------
    address internal constant BTC_USD = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address internal constant ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant LINK_USD = 0xb113F5A928BCfF189C998ab20d753a47F9dE5A61;
    address internal constant USDC_USD = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;

    /// @dev One hour of heartbeat plus fifteen minutes of grace, for the three
    ///      deviation-driven crypto feeds.
    uint256 internal constant FAST_FEED_MAX_AGE = 4500;

    /// @dev Twenty-four hours of heartbeat plus one hour of grace, for the
    ///      stablecoin feed.
    uint256 internal constant DAILY_FEED_MAX_AGE = 90000;

    uint256 internal constant EXPECTED_CHAIN_ID = 84532;

    function run() external returns (OracleHealthChecker checker) {
        // A deployment aimed at the wrong chain is a deployment that should not
        // start, not one to notice afterwards.
        require(block.chainid == EXPECTED_CHAIN_ID, "Deploy: not Base Sepolia 84532");

        uint256 deployerKey = vm.envUint("DEMO_DEPLOYER_PK");

        IOHC.FeedConfig[] memory configs = feedConfigs();

        vm.startBroadcast(deployerKey);
        checker = new OracleHealthChecker(configs);
        vm.stopBroadcast();

        console2.log("OracleHealthChecker:", address(checker));
        console2.log("chain id:", block.chainid);
        console2.log("feeds registered:", checker.feedCount());
    }

    /// @notice The registry, exposed so the sanity script and the tests read the
    ///         same four pairs this script deploys rather than restating them.
    function feedConfigs() public pure returns (IOHC.FeedConfig[] memory configs) {
        configs = new IOHC.FeedConfig[](4);
        configs[0] = IOHC.FeedConfig(BTC_USD, FAST_FEED_MAX_AGE);
        configs[1] = IOHC.FeedConfig(ETH_USD, FAST_FEED_MAX_AGE);
        configs[2] = IOHC.FeedConfig(LINK_USD, FAST_FEED_MAX_AGE);
        configs[3] = IOHC.FeedConfig(USDC_USD, DAILY_FEED_MAX_AGE);
    }
}
