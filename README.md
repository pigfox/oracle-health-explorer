# Oracle Health Explorer

[![CI](https://github.com/pigfox/oracle-health-explorer/actions/workflows/ci.yml/badge.svg)](https://github.com/pigfox/oracle-health-explorer/actions/workflows/ci.yml)

**A contract that reads live Chainlink Data Feeds and says what is wrong with
them, if anything.**

Live on Base Sepolia (84532), verified, read-only:
[`0x67F74D6dF6c08F090069EBEeC37a07035eF1Bd40`](https://sepolia.basescan.org/address/0x67F74D6dF6c08F090069EBEeC37a07035eF1Bd40#code)

---

## The problem this is about

Protocols do not usually lose money because an oracle was attacked. They lose it
because the consuming contract called `latestRoundData()`, took `answer`, and
used it — and the answer was old, or negative, or came from a round that never
finished.

Each of those is a one-line check that a lot of production code does not do. This
contract does them and names the result.

| Verdict | Condition | Why it has mattered |
| --- | --- | --- |
| `HEALTHY` | complete, positive, within this feed's max age | — |
| `STALE` | `age > maxAge` | The commonest failure and the quietest. The feed still answers, the data is perfectly well-formed, and nobody has updated it. A consumer that only checks for a revert sees nothing wrong. |
| `NON_POSITIVE_ANSWER` | `answer <= 0` | `answer` is an `int256` and negative values are representable — a production feed has printed one. A consumer that casts to `uint256` without checking turns a small negative price into a number near `2**256`, and any collateral valuation built on it is then arbitrarily wrong in an attacker's favour. |
| `FUTURE_TIMESTAMP` | `updatedAt > block.timestamp` | Breaks naive consumers two ways from one line. `block.timestamp - updatedAt` reverts under checked arithmetic, taking down whatever was pricing; unchecked, it underflows to a near-`2**256` age. |
| `INCOMPLETE_ROUND` | `updatedAt == 0` | The round was started and never answered, so there is no timestamp to measure age from at all. Distinct from `STALE` because the consumer's choice differs: wait for the next round, or stop trusting the feed. |
| `UNAVAILABLE` | the feed reverted, has no code, or answered with the wrong ABI shape | An explorer whose job is reporting broken feeds must not itself break on one. |

The enum's ordinal **is** a severity ranking, declared least to most severe. When
more than one thing is wrong the verdict is the worst of them, not whichever
condition happened to be tested first.

## Staleness semantics, stated exactly once

**`maxAge` is inclusive.** An age of exactly `maxAge` is `HEALTHY`. `STALE`
begins one second later. The comparison is `age > maxAge`, never `>=`.

Off-by-one on that line is the entire bug class, and it is invisible to testing
that samples the interior of a range — both wrong versions agree with the right
one everywhere except on a single value. So the boundary is **constructed on
every fuzz draw** rather than waited for, from both sides, and there is a
companion test showing that an interior draw does *not* catch a `>=` for `>`
substitution. That is why the boundary property exists separately from the
freshness property.

## Max age is per feed, and that is a measurement

The four feeds were measured on chain before any of this was written — each was
called for `decimals()`, `description()` and `latestRoundData()`, and its
heartbeat was derived by reading the previous round and differencing `updatedAt`.

| Pair | Aggregator | Decimals | Observed interval | Max age used |
| --- | --- | --- | --- | --- |
| BTC / USD | [`0x0FB9…4298`](https://sepolia.basescan.org/address/0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298) | 8 | ~166 s | 4,500 s |
| ETH / USD | [`0x4aDC…7cb1`](https://sepolia.basescan.org/address/0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1) | 8 | ~154 s | 4,500 s |
| LINK / USD | [`0xb113…5A61`](https://sepolia.basescan.org/address/0xb113F5A928BCfF189C998ab20d753a47F9dE5A61) | 8 | ~230 s | 4,500 s |
| USDC / USD | [`0xd30e…5165`](https://sepolia.basescan.org/address/0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165) | 8 | **~86,420 s** | 90,000 s |

That last row is the point. USDC/USD moves on a **~24-hour heartbeat** —
confirmed across two consecutive intervals at 86,424 s and 86,416 s — while the
three crypto feeds republish every two to four minutes.

A single estate-wide threshold cannot describe both. Tight enough for BTC, and
USDC reads stale for almost all of every day. Loose enough for USDC, and a BTC
feed frozen for twenty hours reads healthy. Neither is a staleness check. The
heartbeat is a property of the feed, so the threshold has to be too — which is
why the registry is per-feed, and why each max age is **immutable and
constructor-set with no owner, no setter and no upgrade path**.

### On `answeredInRound`

Older Chainlink documentation suggested guarding staleness with
`answeredInRound < roundId`, and that check is still copied into consumer code
today.

It is **still exposed** by all four of these aggregators — and on every one of
them it came back **equal to `roundId`**. So the guard cannot fire. Implementing
it would produce a check that always passes, which is worse than no check: it
reads as though staleness is covered when the only thing actually covering it is
the `updatedAt` comparison. The contract says so in a comment instead of
implementing it. (`startedAt` was likewise equal to `updatedAt` on all four.)

## Measured verdicts at deploy time

Read off the deployed contract at chain timestamp `1785424246`, by
`script/SanityRun.s.sol`:

| Pair | Answer | Age | Max age | Verdict |
| --- | --- | --- | --- | --- |
| BTC / USD | 64,735.00 | 84 s | 4,500 s | `HEALTHY` |
| ETH / USD | 1,916.54 | 462 s | 4,500 s | `HEALTHY` |
| LINK / USD | 8.48 | 708 s | 4,500 s | `HEALTHY` |
| USDC / USD | 0.9998 | 15,062 s | 90,000 s | `HEALTHY` |

USDC's round is **over four hours old and correctly healthy**. Against BTC's
4,500-second threshold that same round would read `STALE`. The argument for a
per-feed max age, in one row.

The sanity script does not merely print these. It reads the raw round data
straight off each aggregator, derives the expected verdict with an independent
restatement of the rule, and **reverts on any disagreement** — so a green run
means two implementations agreed about four live feeds. It also requires each
aggregator's `description()` to match the pair claimed above, because a registry
pointing at a healthy, correctly-answering feed for the *wrong asset* is a
failure no health check would notice.

## Design

**The verdict logic is pure.** `evaluate(answer, updatedAt, observedAt, maxAge)`
reads neither state nor clock. That is what makes it exhaustively testable: a
live aggregator cannot be made stale, negative or incomplete on request, so a
design reachable only through a real feed could not be verified at all.
`check(index)` is a thin wrapper that supplies `block.timestamp`.

**It cannot be bricked by a bad feed.** Every external read is a low-level
`staticcall` with the returndata length checked before decoding.

`try/catch` is *not* sufficient here, and this is verified rather than asserted:
a `catch` clause does not catch a failure to **decode** the returndata, so
`try aggregator.latestRoundData()` still reverts the caller when the address has
no code or answers with the wrong shape.
`test_tryCatchDoesNotSurviveAWrongShapedFeedButTheCheckerDoes` reads one such
feed both ways — the naive consumer reverts, this contract returns
`UNAVAILABLE`. If a future compiler changes that, the test fails and the design
note gets revisited deliberately instead of silently.

**There is no batch read on chain.** An earlier draft had `checkAll()` and
`worstHealth()`. Both are gone. A protocol adopting this check calls it for the
*one* feed it is about to price something with, inside its own borrow or
liquidate transaction — it has no use for the health of feeds it is not reading.
`check(index)` is the integration surface; a batch read was only ever convenience
for a web page, and a page can batch at the RPC layer where a slow feed costs a
round trip rather than a block's gas.

**Decimals is presentational.** No verdict depends on it, so a feed that answers
round data but not `decimals()` still gets a real verdict, with decimals reported
as a zero sentinel. The health verdict comes from `latestRoundData` alone.

## Integrating it

```solidity
IOracleHealthChecker.Report memory r = checker.check(FEED_INDEX);
if (r.health != IOracleHealthChecker.Health.HEALTHY) revert FeedNotUsable(r.health);
// r.answer is safe to use, scaled by r.decimals
```

The report carries **every input the verdict was derived from** — `answer`,
`decimals`, `roundId`, `updatedAt`, `checkedAt`, `secondsSinceUpdate`, `maxAge` —
so a caller can redo the arithmetic instead of trusting the answer.

## Verification

Every contract in every pigfox repo passes **PIGFOX SOLIDITY PIPELINE v1** before
it is deployed or demoed. The pipeline is consumed as a reusable workflow and
vendored as a submodule at `lib/solidity-pipeline`, never copied — so a fix lands
once, and a local run and a CI run are the same bytes.

| Stage | Result |
| --- | --- |
| `forge fmt --check` | clean |
| `forge build --sizes` | 2,075 B runtime |
| `forge test` | 63 passing |
| Coverage on `src/` | **100%** lines, statements, branches and functions — **no exclusions** |
| Slither, `fail-on: low` | 0 findings |
| Echidna | 9/9 over 100,096 calls |
| Medusa | 9/9 over 101,437 calls |

### The nine properties

1. A verdict is always the **most severe** applicable state.
2. Time passing never makes a verdict **healthier**.
3. A complete, positive, in-date round **is** `HEALTHY`. *(The only property that
   can fail toward false alarm — a checker returning `STALE` unconditionally
   would satisfy every "never healthy when X" claim perfectly.)*
4. A non-positive answer is **never** `HEALTHY`, at any age.
5. `updatedAt == 0` is reported as `INCOMPLETE_ROUND`.
6. A future `updatedAt` is reported as `FUTURE_TIMESTAMP`.
7. The staleness boundary is **exact in both directions**.
8. A feed that cannot be read yields `UNAVAILABLE` and **never reverts the
   caller** — proven against four distinct failure shapes: a revert with a
   reason, a revert with empty returndata, a successful call with the wrong ABI
   shape, and an address with no code.
9. Reading a real feed **agrees with the pure logic** on the same numbers.

The count is **declared, not counted**: the Solidity literal in
`pigfoxPropertyCount()`, the static count of `echidna_*` predicates, and what
Echidna and Medusa each registered at runtime must all agree, or the build fails.
A stale artifact once shrank a sibling repo's five-property set to four and the
job passed. Green on four is not green.

### Every detector is proven able to fire

Nine predicates that have never been contradicted are indistinguishable from nine
that *cannot* be contradicted, and only one of those is worth running. So
`test/Invariants.t.sol` installs a checker built to break each property on
purpose and requires the matching predicate to go false — each self-test driving
**only** the entry point that feeds its predicate, so a detector that went red
because a neighbour went red has not been shown to work.

A control requires a faithful checker to trip nothing, and it earned its place
immediately: it caught the harness rebuilding a probe over the wrong mock
aggregators, so the wrapper property was failing against correct code.

### Mocks, and where the real chain is

The failure states are reached with mock aggregators built from source inside the
in-process EVM that `forge test`, Echidna and Medusa each construct. They reach
no network and stand in for nothing — a live feed cannot be made stale on demand,
so without them five of the six verdicts would be untestable.

Everything else is **direct-chain only**: the deployment, the sanity read-back
and the web page all talk to Base Sepolia 84532 itself.

## Running it

```bash
git clone --recurse-submodules https://github.com/pigfox/oracle-health-explorer
cd oracle-health-explorer

forge test
lib/solidity-pipeline/scripts/coverage.sh
rm -rf crytic-export && forge build --force      # never fuzz coverage artifacts
echidna . --contract Properties --config echidna.yaml
medusa fuzz --config medusa.json
```

Reading the live contract needs no key and sends no transaction:

```bash
cast call --rpc-url https://sepolia.base.org \
  0x67F74D6dF6c08F090069EBEeC37a07035eF1Bd40 \
  "check(uint256)((uint8,address,uint8,uint80,int256,uint256,uint256,uint256,uint256))" 3
```

Deploying does need a key, read from a repo-local `.env` via `vm.envUint` — never
echoed, never in argv, never in a tracked file.

## Layout

```
src/OracleHealthChecker.sol    the checker: pure verdict logic + a thin feed reader
src/IOracleHealthChecker.sol   verdict states, severity ranking, report shape
src/IAggregatorV3.sol          the read surface of a Chainlink feed
test/Properties.sol            the nine properties, driven by all three engines
test/Invariants.t.sol          Foundry's runner + a self-test for every detector
test/OracleHealthChecker.t.sol the cases stated by name, including the boundary
script/Deploy.s.sol            deployment, Base Sepolia only
script/SanityRun.s.sol         read the live contract, recompute, revert on drift
deployments/base-sepolia.json  addresses, tx, gas, feeds, measured verdicts
```

## Licence

MIT.
