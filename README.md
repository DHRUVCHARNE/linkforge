## Baseline — Phase 1 (in-memory)

Env: GitHub Codespaces, 2 vCPU · load generator co-located (see caveat)
Hot read path `GET /:code`, oha 10s, keepalive on

| c   | req/s  | p50     | p99      |
| --- | ------ | ------- | -------- |
| 50  | 10,394 | 4.57 ms | 11.66 ms |
| 100 | 9,763  | 9.82 ms | 23.04 ms |

Correctness: 10,000 concurrent POSTs → 0 duplicate codes.

⚠️ Caveat: throughput is environment-bound at ~10k req/s. DashMap vs
RwLock<HashMap> and worker_threads 2 vs 10 produced no measurable
difference — the ceiling is CPU contention with the co-located load
generator, not application code. Treat p99 @ c=50 as the comparison
point for Phase 4, and only compare runs taken on identical hardware.
### Application-level benchmark (criterion, HTTP excluded)

`ShortenerService::lookup` (cache hit): **39.75 ns** [37.9, 41.7]

→ Application logic is 0.0004% of the 9.82 ms observed p50.
→ Theoretical single-core ceiling: ~25M lookups/sec vs ~10K req/s measured.
→ Conclusion: Phase 1 is entirely transport- and environment-bound.
   No further in-memory optimization is justified.
## Baseline — Phase 2 (Postgres + read-through cache)

Env: GitHub Codespaces, 2 vCPU · Postgres + Redis containers co-located
Hot read path `GET /:code`, oha 10s, keepalive on

| c   | req/s  | p50      | p99      |
| --- | ------ | -------- | -------- |
| 50  | 10,144 | 4.56 ms  | 13.34 ms |
| 100 | 5,539  | 16.49 ms | 47.59 ms |

Correctness: 10,000 concurrent POSTs → 0 duplicate codes, all persisted.

### Application-level (criterion, HTTP excluded)

| Path                     | Time      |
| ------------------------ | --------- |
| `InMemoryCache::get` hit | 219.38 ns |
| `find_by_code` (DB)      | 450.01 µs |

→ **Cache miss costs ~2,051× a hit.** This is the measured justification
  for the read-through cache.
→ p50 unchanged vs Phase 1 (4.57 → 4.56 ms): adding persistence cost the
  hot path nothing, because hits never reach Postgres.

⚠️ Caveats: cache_hit is not comparable to Phase 1's 39.75 ns — the bench
  now goes through an async trait + rt.block_on. The c=100 regression
  (9,763 → 5,539) is CPU contention from co-located containers, not
  application code; DNS+dialup rose 1.70 → 8.62 ms. 15% outliers.
 ## Phase 2 — Final (Postgres + read-through cache + negative caching + single-flight)

Env: GitHub Codespaces, 2 vCPU · Postgres co-located · fresh database

| Probe                   | Result                                                   |
| ----------------------- | -------------------------------------------------------- |
| 10,000 concurrent POSTs | 10,000 unique codes, 0 duplicates, 0 failures            |
| Hot read path @ c=100   | 9,783 req/s · p50 9.55ms · p99 25.13ms                   |
| Negative caching        | 501 requests, 1 nonexistent code → **1 DB query**        |
| Single-flight           | 100 concurrent misses → **1 DB query** (100× coalescing) |
| Hit ratio               | 99.89% → expected ~714 ns/lookup                         |

Parity with Phase 1 in-memory (9,763 req/s @ c=100): persistence, caching,
and coalescing cost the hot path nothing measurable.

⚠️ Write throughput degrades as `links` grows — a table with ~40k rows
produced 8% write failures at c=100 (unique-index insert cost exceeding
the 3s pool acquire_timeout). The load test must run against a fresh
database to be comparable.
## Baseline — Phase 3 (tracing + request IDs + per-IP rate limiting)

Env: GitHub Codespaces, 2 vCPU · Postgres + Redis co-located · fresh database
Hot read path `GET /:code`, oha 10s, keepalive on
Server started in BENCH MODE (`RATE_LIMIT_REQUESTS=100000000`) so the
limiter cannot throttle the benchmark.

| c   | req/s | p50      | p99      |
| --- | ----- | -------- | -------- |
| 100 | 5,404 | 17.15 ms | 47.32 ms |

Correctness: 10,000 concurrent POSTs → 10,000 unique codes, 0 duplicates,
0 failures (429: 0, 500: 0).

### Phase 3 acceptance

| Criterion                                  | Result                            |
| ------------------------------------------ | --------------------------------- |
| Client `x-request-id` echoed unchanged     | ✅                                 |
| `x-request-id` generated when absent       | ✅ (UUID v4)                       |
| Generated IDs distinct across requests     | ✅                                 |
| Exceeding the rate returns 429             | ⚠️ verified separately — see below |
| Logs correlate across middleware + handler | ⚠️ manual grep — see below         |

### Carried forward from Phase 2 (still passing)

| Probe              | Result                                                   |
| ------------------ | -------------------------------------------------------- |
| Negative caching   | 501 requests, 1 nonexistent code → **1 DB query**        |
| Single-flight      | 129 concurrent misses → **1 DB query** (129× coalescing) |
| Hit ratio          | 99.76% → expected ~1,298 ns/lookup                       |
| Overall coalescing | 22.33 cache misses per DB query                          |

### ⚠️ Throughput regression: 9,783 → 5,404 req/s (−45%)

p50 rose 9.55 → 17.15 ms; p99 rose 25.13 → 47.32 ms. This is a real delta,
far outside the ~2% run-to-run noise floor.

**Cause not yet isolated.** Three candidates, untested:

1. Per-request tracing spans (CPU cost of `TraceLayer` + subscriber)
2. The rate limiter — all load originates from one IP, so every request
   contends on a single `DashMap` shard: the pathological case for sharding
3. Environment noise — `DNS+dialup` rose 4.5 → 13.87 ms, which is scheduler
   contention, not application code

To isolate, rerun with `RUST_LOG=off`, then with the `RateLimitLayer`
removed, comparing each against this figure.

⚠️ A previous phase attributed a similar one-off regression (9,763 → 5,539)
to container CPU contention; it did not reproduce across two subsequent
runs. **Do not accept this number from a single run.**

### ⚠️ Benchmark methodology change

From Phase 3 the server must be started in BENCH MODE or the rate limiter
throttles the harness itself. An earlier run recorded 192/10,000 successful
writes — 9,808 of them 429s — which under the Phase 2 script would have
appeared as silent write failures and been misdiagnosed as pool timeouts.

    RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1 just run
    ### Phase 3 regression — ISOLATED

| Config                   | tracing | limiter | req/s     | p50      | DNS+dialup   |
| ------------------------ | ------- | ------- | --------- | -------- | ------------ |
| Phase 2 final            | —       | —       | 9,783     | 9.55 ms  | ~4.5 ms      |
| Phase 3 full (mean of 2) | on      | on      | 5,583     | 16.85 ms | 4.9–13.9 ms  |
| `RUST_LOG=off`           | off     | on      | **6,973** | 13.49 ms | 6.71 ms      |
| limiter removed          | on      | off     | 4,717     | 18.98 ms | **10.81 ms** |

**Finding: tracing costs ~20% throughput** (6,973 → 5,583) and ~3.4 ms p50.
This is the measured price of observability, accepted deliberately.

**Finding: the rate limiter costs nothing measurable.** Removing it produced
a *lower* number, which is impossible as a causal effect — that run had the
worst DNS+dialup of the three (10.81 ms) and is treated as contaminated.
Contrary to the earlier hypothesis, single-IP DashMap shard contention is
not a bottleneck at this load.

⚠️ ~2,800 req/s of the Phase 2 → Phase 3 gap remains unexplained even with
tracing off. Untested candidates: per-request UUID generation in
SetRequestIdLayer, span *construction* cost in TraceLayer (RUST_LOG=off
silences output but spans are still built), or environment drift.
### Phase 3 regression — FULLY ISOLATED

| Config               | middleware | logging | req/s     | p50      |
| -------------------- | ---------- | ------- | --------- | -------- |
| Phase 2 reference    | —          | —       | 9,783     | 9.55 ms  |
| Stack removed        | none       | off     | **9,090** | 10.33 ms |
| Stack on, output off | on         | off     | 6,973     | 13.49 ms |
| Full Phase 3         | on         | on      | 5,583     | 16.85 ms |

**Attribution:**
- Middleware *construction* (spans + UUID generation): **−23%**
- Log *emission* (formatting + stdout): **−20% further**
- Rate limiter: **no measurable cost**
- Application code: **unchanged** (criterion p > 0.05 across all phases)

Phase 2's baseline reproduces (9,090 vs 9,783, ~7% session drift), so the
entire Phase 2 → Phase 3 delta is the observability stack. Total cost of
observability: **~39% throughput, ~6.5 ms p50.**

⚠️ Surprising result: span CONSTRUCTION costs more than log EMISSION.
`RUST_LOG=off` silences output but `info_span!` still allocates its fields.
Mitigations: `release_max_level_info` feature, or fewer/cheaper span fields.
### ⚠️ BUILD PROFILE CORRECTION

Every benchmark prior to this point was taken against a **debug build**.
`just run` used `cargo run` without `--release`, so:

- `release_max_level_info` (compile-time log filtering) was inert
- all optimisations were disabled

Release build, same code, same settings:

| Build   | req/s      | p50         | p99         | DNS+dialup |
| ------- | ---------- | ----------- | ----------- | ---------- |
| debug   | 5,631      | 16.97 ms    | 39.12 ms    | 10.12 ms   |
| release | **27,106** | **3.35 ms** | **9.78 ms** | 4.32 ms    |

**4.8× throughput, 5× lower p50.**

This invalidates the "~10k req/s environment ceiling" documented from
Phase 1 onward — that was a debug-build ceiling, not a hardware one.
The Phase 1 conclusion that the service was "entirely transport-bound"
was reasoning from a number ~3× below actual capacity.

Phase-over-phase comparisons remain valid (consistent profile), but all
absolute figures before this point understate the service substantially.

⚠️ The release build and the logging-config change landed together, so
the 39% observability cost measured in debug is not yet confirmed for
release. Re-measure by reverting the logging config on a release build.
| Logs correlate across middleware + handler | ✅ conditional |

Spans carry `request_id`, but the production filter
(`release_max_level_info` + `on_response` at DEBUG) emits no per-request
event on the success path — so there is nothing to print it on. Correlation
is available on error paths, and on demand by building without
`release_max_level_info`.

This is a deliberate trade: per-request events cost ~20% throughput
(measured). A redirect service needs correlation on failures, not successes.