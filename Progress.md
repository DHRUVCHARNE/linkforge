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
## Phase 4 — Background work & channels  ✅ M4: It's fast

Env: GitHub Codespaces, 2 vCPU · Postgres + Redis co-located · **release build** · fresh database
Hot read path `GET /:code`, oha 10s @ c=100, keepalive on
Server in BENCH MODE (`RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1`)

Each redirect now records a click. `CLICK_MODE` selects how:

- `sync`: the redirect awaits `INSERT INTO clicks` before responding
- `async` (default): the redirect calls `try_send` on a bounded `mpsc` channel; a background worker batches the inserts

### Acceptance — redirect p99, async vs sync

| Mode        | req/s  | p50      | p99           | p99.9     | DNS+dialup |
| ----------- | ------ | -------- | ------------- | --------- | ---------- |
| sync        | 1,532  | 56.82 ms | **191.80 ms** | 268.26 ms | 4.45 ms    |
| async run A | 15,146 | 5.85 ms  | 18.99 ms      | 30.53 ms  | 4.10 ms    |
| async run B | 15,979 | 5.65 ms  | **17.74 ms**  | 27.10 ms  | 5.74 ms    |

**p99 improvement: 90.8%** (threshold ≥ 20%). **Throughput: 10.4×.**
The two async runs agree to within ~5%, and every run had DNS+dialup below 7 ms (no host contention).

### Why sync is slow

Each redirect holds a pool connection until its INSERT commits, so 100 clients queue
for 20 connections. Little's Law: 1,532 × 0.0654 s ≈ 100. The system is saturated, and
requests spend most of their time waiting for a connection rather than running SQL.

### Writer behaviour (async run B)

| Metric                                         | Value   |
| ---------------------------------------------- | ------- |
| Clicks enqueued                                | 162,262 |
| Batches                                        | 329     |
| Avg rows per INSERT                            | 493.2   |
| Failed batches                                 | 0       |
| Queue depth after load                         | 0       |
| Conservation gap (enqueued − written − queued) | 0       |

Batching leaves Postgres doing about 33 INSERTs/s to persist about 16k clicks/s.

### Click accounting

2,000 redirects → **exactly 2,000 rows**, visible through `/stats` in 22–27 ms. 0 dropped.

### Backpressure: drop on full

| Run     | req/s  | Dropped      |
| ------- | ------ | ------------ |
| async A | 15,146 | 9,867 (6.5%) |
| async B | 15,979 | 0 (0%)       |

At ~15–16k req/s the writer runs close to the arrival rate, so whether the channel fills
depends on timing. Report drops as a range: **0–6.5% at ~15–16k req/s**.

Dropping is deliberate. `try_send` never waits, so a slow database can't slow a redirect,
and the bounded channel caps memory use. The cost is an undercount; the alternative costs
~10× in p99. Dropped clicks are counted, so the loss is visible.

### Carried forward (still passing)

| Probe                   | Result                                                      |
| ----------------------- | ----------------------------------------------------------- |
| 10,000 concurrent POSTs | 10,000 unique codes, 0 duplicates, 0 failures               |
| Negative caching        | 500 repeat 404s → **0 DB queries**                          |
| 404s record clicks      | **none** (stops scanners from filling the analytics table)  |
| Single-flight           | 30 concurrent misses → **1 DB query**                       |
| Request ID              | echoed · generated · distinct · present on 404 and `/stats` |
| Hit ratio               | 99.98% → expected ~358 ns/lookup                            |

### `GET /:code/stats` contract

| Case                    | Result                        |
| ----------------------- | ----------------------------- |
| Existing, never clicked | `200 {"code":"…","clicks":0}` |
| Unknown code            | `404` (not `clicks: 0`)       |
| Malformed code          | `404`                         |
| Reading `/stats`        | records no clicks             |
| Content-Type            | `application/json`            |

### Application-level (criterion, HTTP excluded)

| Path                     | Phase 2   | Phase 4   | Verdict                          |
| ------------------------ | --------- | --------- | -------------------------------- |
| `InMemoryCache::get` hit | 219.38 ns | 265.25 ns | no significant change (p = 0.06) |
| `find_by_code` (DB)      | 450.01 µs | 628.72 µs | no significant change (p = 0.27) |

⚠️ `find_by_code` keeps rising from phase to phase. The likely cause is that `docker compose down`
without `-v` keeps the volume, so `links` and `clicks` grow across runs.

### ⚠️ Cost of analytics on the hot path

| Config              | req/s  | p50     | p99      |
| ------------------- | ------ | ------- | -------- |
| Phase 3 (no clicks) | 27,106 | 3.35 ms | 9.78 ms  |
| Phase 4 async       | 15,979 | 5.65 ms | 17.74 ms |

Building a click on every redirect (a `String` allocation, SHA-256 of the IP, and `try_send`)
costs **~41% throughput**. **Not yet measured.** The most likely main cost is SHA-256.
Benchmark `hash_ip` before optimising.

### Rate-limit bucket sweeper

`workers/bucket_sweeper.rs` evicts idle buckets from the limiter's `DashMap`, using the same
map as the middleware via `RateLimitState`. It is started from `AppState::build()`.

Verified with `RATE_LIMIT_SWEEP_INTERVAL=2 RATE_LIMIT_IDLE_TTL=3`:

    INFO linkforge::workers::bucket_sweeper: swept idle rate-limiting buckets, evicted: 1

Evicting a bucket created by a real request shows the sweeper shares the limiter's map.
Eviction long before the 300 s / 3600 s defaults could fire shows both overrides were read.

### ⚠️ Methodology

Both runs must meet all four of these, or the comparison is invalid:

1. **Release build:** `cargo run --release`
2. **Fresh database:** `docker compose down -v && docker compose up -d`
3. **Bench-mode rate limit:** otherwise the limiter throttles the harness
4. **Matching `CLICK_MODE`** on server and script (the script aborts on a mismatch)

```bash
CLICK_MODE=sync  RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1 cargo run --release
CLICK_MODE=sync  ./scripts/load_test.sh

CLICK_MODE=async RATE_LIMIT_REQUESTS=100000000 RATE_LIMIT_WINDOW_SECS=1 cargo run --release
CLICK_MODE=async ./scripts/load_test.sh     # probe 10 prints the verdict
```

Raw results: `.loadtest/phase4_{sync,async}.env` and `.loadtest/phase4_{sync,async}_oha.txt`.

`CLICK_MODE=sync` is kept as a supported mode: exact counts at ~10× lower throughput, and the
regression baseline for later phases. The default is `async`.
### Rate-limit bucket sweeper

**Problem.** The Phase 3 rate limiter stores one token bucket per client IP in an
in-process `DashMap<IpAddr, Bucket>`. Nothing ever removed entries, so the map grew by
one entry (~60 B) for every distinct client, forever. A scanner rotating through IPv6
addresses could grow it quickly.

**Why Redis TTLs don't fix this.** Phase 6 moves the *link cache* to Redis behind the
`Cache` trait. The limiter's map is a separate structure that stays in-process, so it
needs its own cleanup. (Moving rate limiting into Redis was considered and rejected:
it would add a network round trip to every request in exchange for multi-instance
correctness this project doesn't need yet.)

**Design.**

| Concern | Location | Why |
| --- | --- | --- |
| Eviction rule | `RateLimitState::sweep(idle)` | `Bucket` fields are private to `rate_limit.rs` |
| Timer loop | `workers/bucket_sweeper.rs` | background tasks live in `workers/`, next to the analytics writer |
| Startup | `AppState::build()` | one place starts every background task; Phase 5 shutdown stops them there |
| Shared map | `RateLimitLayer::from_state(state.rate_limiter.clone())` | the middleware and the sweeper must use the **same** `Arc<DashMap>` |

`last_refill` doubles as a "last seen" timestamp, because it's updated on every
request, including rejected ones. A bucket idle longer than `idle_ttl` is evicted:

```rust
pub fn sweep(&self, idle: Duration) -> usize {
    let before = self.buckets.len();
    self.buckets.retain(|_, b| b.last_refill.elapsed() < idle);
    before - self.buckets.len()
}
```

**Rejected alternative: spawning inside `RateLimitState::from_config()`.** That
would hide a side effect in a constructor, start one sweeper per router (and so one
per test, never stopped), and leave Phase 5's graceful shutdown no single place to
stop it.

**Configuration.**

| Variable | Default | Meaning |
| --- | --- | --- |
| `RATE_LIMIT_SWEEP_INTERVAL` | 300 | seconds between sweeps |
| `RATE_LIMIT_IDLE_TTL` | 3600 | seconds of inactivity before a bucket is evicted |

⚠️ Invariant: `RATE_LIMIT_IDLE_TTL ≥ RATE_LIMIT_WINDOW_SECS`. If a bucket is evicted
before its window ends, that client gets a fresh, full bucket on its next request,
raising its effective rate limit.

**Cost.** `DashMap::retain` is synchronous and write-locks each shard in turn. At a
300 s interval over thousands of entries this takes microseconds, but it briefly
blocks requests touching the shard being swept. Keep this in mind before lowering the
interval.

**Verification.** Run with `RATE_LIMIT_SWEEP_INTERVAL=2 RATE_LIMIT_IDLE_TTL=3`:

    INFO linkforge::workers::bucket_sweeper: swept idle rate-limiting buckets, evicted: 1

| Property | Evidence |
| --- | --- |
| Spawned and running | an entry was evicted |
| Shares the limiter's map | it evicted a bucket created by a real request; a separate map would always be empty |
| Interval override read | it swept long before the 300 s default could fire |
| TTL override read | it evicted long before the 3600 s default could expire the bucket |

The sweeper logs only when it evicts something, so the timestamp shows when the bucket
expired, not when the first sweep ran.

**Follow-ups.**
- Rename to `RATE_LIMIT_SWEEP_INTERVAL_SECS` / `RATE_LIMIT_IDLE_TTL_SECS` to match `RATE_LIMIT_WINDOW_SECS`
- Check `idle_ttl ≥ window_secs` at startup and fail fast if it doesn't hold
- Log the interval and TTL when the sweeper starts
- The test harness builds `RateLimitState` without a sweeper, so tests leave no background tasks running
## Phase 5 — Production hardening  ✅ M5: It ships

Env: GitHub Codespaces, 2 vCPU · **Docker container** (release build, distroless,
non-root, `network_mode: host`) · Postgres co-located · fresh DB ·
bench-mode rate limit · oha 10s @ c=100, keepalive on

### What was added

| Area | Implementation |
|---|---|
| Graceful shutdown | SIGTERM → readiness 503 → `shutdown_delay_secs` → stop accepting → drain in-flight requests → click writer flushes → sweeper stops → exit 0 |
| Health probes | `/health/live` (no dependencies) and `/health/ready` (DB ping + draining flag), mounted outside the middleware stack so they are never rate-limited or timed out |
| Metrics | Prometheus `/metrics`: request count + latency by **route template**, cache lookups, click pipeline (enqueued, dropped, rows written, batches, failures, queue depth), rate-limit rejections and bucket count |
| Config | `configs/default.toml` → `configs/{APP_ENV}.toml` → `LINKFORGE__SECTION__KEY` env vars; secrets (`DATABASE_URL`, `ANALYTICS_IP_SALT`, `JWT_SECRET`) from the environment only |
| Fail-fast validation | startup rejects: statement ≥ acquire ≥ request timeout, `idle_ttl_secs < window_secs`, `max_batch` outside 1..=10000, and in production a missing salt, debug routes or `click_mode = sync` |
| Timeouts | request timeout (408), DB statement timeout via connection options; ordered statement < acquire < request |
| Container | multi-stage build: `rust:1-bookworm` → `distroless/cc-debian12:nonroot`; exec-form `ENTRYPOINT` so SIGTERM reaches the binary; `SQLX_OFFLINE` with committed `.sqlx/` |

### Hot path in the container

| Run | req/s | p50 | p99 | p99.9 | DNS+dialup |
|---|---|---|---|---|---|
| Phase 4 async (host) | 15,979 | 5.65 ms | 17.74 ms | 27.10 ms | 5.74 ms |
| **Phase 5 async, run A (container)** | **13,415** | **6.31 ms** | **22.93 ms** | 39.46 ms | 5.76 ms |

**−16% throughput, +5.2 ms p99 vs Phase 4.**

⚠️ **Not yet attributed.** Three things changed at once: the server moved into a
container, the metrics middleware was added, and a timeout layer was added. A host
run of the same code is needed to separate container cost from middleware cost.

A second run (B: 12,421 req/s, p99 22.51 ms) had DNS+dialup 13.2 ms (host contention)
and is excluded. Its p99 and drop rate matched run A.

### Click pipeline under load (run A)

| Metric | Value |
|---|---|
| Redirects served | 134,241 |
| Click attempts | 134,329 (every redirect emitted one) |
| Dropped | 20,313 (15.1%) |
| Avg rows per INSERT | 490.4 |
| Failed batches | 0 |
| Conservation gap | 0 |
| Queue depth after load | 0 |

Drops are higher than on the host (0–6.5% in Phase 4) and consistent across both
container runs (15.1%, 13.8%). The writer is healthy, so this is the drop-on-full
policy responding to less CPU headroom, not a defect. Under normal load nothing is
lost: 2,000 redirects → exactly 2,000 rows, visible in 23–39 ms.

### Graceful shutdown under load

| Environment | Redirects served | Persisted | Dropped | 5xx |
|---|---|---|---|---|
| Host, run 1 | 105,780 | 105,780 | 0 | 0 |
| Host, run 2 (2.06 s DB stall) | 76,733 | 60,991 | 15,742 | 0 |
| Container | _pending: `scripts/container_test.sh`_ | | | |

In both host runs, written + dropped = redirects served: no click was lost
silently. The writer flushed its final batch 22–32 ms after HTTP stopped.

### Phase 5 acceptance

| Criterion | Status |
|---|---|
| SIGTERM completes in-flight requests before exit (host) | ✅ |
| SIGTERM under load in the container, exit 0 within grace period | ⏳ `container_test.sh` |
| Readiness returns 503 before the listener closes | ⏳ `container_test.sh` |
| Container runs end to end (shorten → redirect → stats → metrics) | ✅ |
| `/metrics` valid, counters exact, labels bounded | ⏳ `metrics_test.sh` |
| Invalid config refuses to start | ✅ unit tests (`figment::Jail`) |
| Health probes (live, ready, draining, DB down, not rate-limited) | ✅ integration tests |

### Carried forward (all passing in the container)

10k concurrent writes, 0 duplicates · negative caching (500 repeats → 0 DB queries) ·
single-flight (200 concurrent misses → 1 DB query) · request IDs on 2xx/404/`/stats` ·
`/stats` contract · 404s record no clicks

### Application-level (criterion, HTTP excluded)

| Path | Phase 2 | Phase 4 | Phase 5 |
|---|---|---|---|
| `InMemoryCache::get` hit | 219 ns | 265 ns | 280 ns |
| `find_by_code` (DB) | 450 µs | 629 µs | 597 µs |

The cache hit is unchanged within noise. The DB lookup fell back below Phase 4 on a
fresh database, which is consistent with table growth explaining the earlier drift.

### ⚠️ Environment notes

- **Bridge DNS is broken in this Codespace.** Docker's embedded resolver
  (`127.0.0.11`) times out, so containers can't resolve `postgres`. The app uses
  `network_mode: host` and connects to `localhost:5432`. On a normal Docker host,
  use the bridge network and `postgres:5432`.
- **Port conflicts are silent with host networking.** A leftover `cargo run` on
  port 3000 made the container's bind fail while the old server answered every
  probe — including readiness — with the default bucket of 100. `just load-test`
  now checks that port 3000 is free and that the container is still running.
- **`just` loads `.env` (`set dotenv-load`).** Config tests clear the environment
  inside `figment::Jail` so they pass the same way under `just test` and `cargo test`.

### Run it

```bash
docker compose up -d --build app
curl localhost:3000/health/ready      # {"status":"ready"}
docker compose stop app               # graceful: drains and flushes
```

Bench mode:

```bash
just load-test async                  # fresh DB, bench-mode container, full harness
```
### Metrics (scripts/metrics_test.sh)

| Check | Result |
|---|---|
| Exposition | valid; `promtool check metrics` clean |
| Counters | exact: 500 redirects → +500 requests, +500 latency samples, +500 clicks, +500 rows |
| Histogram | monotone buckets, `+Inf == _count` |
| Cardinality | 61 distinct paths → 0 new series (route templates only) |
| Real Prometheus scrape | `up == 1`, 80 series ingested |
| Scrape cost | ~7 ms, ~7.7 KB |

| Latency | p50 | p99 |
|---|---|---|
| Server-side (`histogram_quantile`) | 17 µs | 176 µs |
| Client-side (oha, c=100) | 6.31 ms | 22.93 ms |

Over 99% of client-observed latency is outside the handler (TCP, scheduling,
queueing on 2 vCPUs). Prometheus rate (13,330 req/s) matches oha (13,415 req/s).
### Graceful shutdown under load

| Environment | Redirects served | Persisted | Dropped | 5xx | Exit |
|---|---|---|---|---|---|
| Host, run 1 | 105,780 | 105,780 | 0 | 0 | clean |
| Host, run 2 (2.06 s DB stall) | 76,733 | 60,991 | 15,742 | 0 | clean |
| **Container** | **112,273** | **112,273** | **0** | **0** | **0, in 5.7 s** |

In the container, readiness returned 503 337 ms after SIGTERM, before the listener
closed. Shutdown completed in 5.7 s against a 30 s grace period, so the process was
never SIGKILLed. Every accepted click reached Postgres.

### Phase 5 acceptance  ✅

| Criterion | Status |
|---|---|
| SIGTERM completes in-flight requests before exit (container) | ✅ 112,273 redirects, 0 5xx, exit 0 |
| Readiness returns 503 before the listener closes | ✅ 337 ms after SIGTERM |
| No click lost on shutdown | ✅ written = served = rows in Postgres |
| Container runs end to end (shorten → redirect → stats → metrics) | ✅ |
| Non-root, exec-form entrypoint, no `/debug/*` in production | ✅ |
| Links survive a container restart | ✅ |
| Invalid config refuses to start | ✅ (unit tests + container) |
| `/metrics` valid, counters exact, labels bounded, real Prometheus scrape | ✅ |
| Health probes (live, ready, draining, DB down, not rate-limited) | ✅ integration tests |
