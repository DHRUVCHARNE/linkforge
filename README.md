## Baseline — Phase 1 (in-memory)

Env: GitHub Codespaces, 2 vCPU · load generator co-located (see caveat)
Hot read path `GET /:code`, oha 10s, keepalive on

| c   | req/s  | p50     | p99      |
|-----|--------|---------|----------|
| 50  | 10,394 | 4.57 ms | 11.66 ms |
| 100 |  9,763 | 9.82 ms | 23.04 ms |

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
|-----|--------|----------|----------|
| 50  | 10,144 |  4.56 ms | 13.34 ms |
| 100 |  5,539 | 16.49 ms | 47.59 ms |

Correctness: 10,000 concurrent POSTs → 0 duplicate codes, all persisted.

### Application-level (criterion, HTTP excluded)

| Path                    | Time      |
|-------------------------|-----------|
| `InMemoryCache::get` hit| 219.38 ns |
| `find_by_code` (DB)     | 450.01 µs |

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

| Probe | Result |
|---|---|
| 10,000 concurrent POSTs | 10,000 unique codes, 0 duplicates, 0 failures |
| Hot read path @ c=100 | 9,783 req/s · p50 9.55ms · p99 25.13ms |
| Negative caching | 501 requests, 1 nonexistent code → **1 DB query** |
| Single-flight | 100 concurrent misses → **1 DB query** (100× coalescing) |
| Hit ratio | 99.89% → expected ~714 ns/lookup |

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
|-----|-------|----------|----------|
| 100 | 5,404 | 17.15 ms | 47.32 ms |

Correctness: 10,000 concurrent POSTs → 10,000 unique codes, 0 duplicates,
0 failures (429: 0, 500: 0).

### Phase 3 acceptance

| Criterion | Result |
|---|---|
| Client `x-request-id` echoed unchanged | ✅ |
| `x-request-id` generated when absent | ✅ (UUID v4) |
| Generated IDs distinct across requests | ✅ |
| Exceeding the rate returns 429 | ⚠️ verified separately — see below |
| Logs correlate across middleware + handler | ⚠️ manual grep — see below |

### Carried forward from Phase 2 (still passing)

| Probe | Result |
|---|---|
| Negative caching | 501 requests, 1 nonexistent code → **1 DB query** |
| Single-flight | 129 concurrent misses → **1 DB query** (129× coalescing) |
| Hit ratio | 99.76% → expected ~1,298 ns/lookup |
| Overall coalescing | 22.33 cache misses per DB query |

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