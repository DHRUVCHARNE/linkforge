# LinkForge

A rate-limited URL shortener in Rust, built phase by phase to learn backend
systems engineering: concurrency, persistence, caching, middleware, background
work, observability and deployment. Every phase ends with a measured result, and
every claim below comes from a run in this repository.

**Stack:** axum · tokio · tower · sqlx (Postgres) · tracing · metrics + Prometheus · Docker

| | |
|---|---|
| **Throughput** | **13,415 req/s** on 2 shared vCPUs (container, load generator on the same host) |
| **Server-side latency** | **p50 17 µs · p99 176 µs** (Prometheus `histogram_quantile`) |
| **Async click pipeline** | redirect **p99 −88 to −91%** vs synchronous writes |
| **Graceful shutdown** | SIGTERM under load: **112,273 redirects, 112,273 rows, 0 errors**, exit in 5.7 s |

---

## Contents

- [LinkForge](#linkforge)
  - [Contents](#contents)
  - [Architecture](#architecture)
  - [Quick start](#quick-start)
  - [API](#api)
  - [Configuration](#configuration)
  - [Testing](#testing)
  - [Progress](#progress)
    - [Phase 1 — Core service, in-memory ✅](#phase-1--core-service-in-memory-)
    - [Phase 2 — Persistence + cache coherence ✅](#phase-2--persistence--cache-coherence-)
    - [Phase 3 — Middleware, rate limiting, observability ✅](#phase-3--middleware-rate-limiting-observability-)
    - [Phase 4 — Background work and channels ✅](#phase-4--background-work-and-channels-)
    - [Phase 5 — Production hardening ✅](#phase-5--production-hardening-)
  - [Benchmark methodology](#benchmark-methodology)
  - [What I learned](#what-i-learned)
  - [Roadmap](#roadmap)
    - [Known limitations](#known-limitations)

---

## Architecture

```text
                    ┌──────────────────────────────────────────────┐
  HTTP client ────► │ axum Router                                  │
                    │  ├─ /health/live, /health/ready  (no layers) │
                    │  └─ tower stack:                             │
                    │       request-id → trace → metrics →         │
                    │       timeout → per-IP rate limit            │
                    │                                              │
                    │  POST /shorten   GET /{code}   GET /{code}/stats
                    └───────┬───────────────────────┬──────────────┘
                            │                       │ try_send (never awaits)
                 ┌──────────▼──────────┐   ┌────────▼─────────┐
                 │ read-through cache  │   │ bounded mpsc     │
                 │ + negative cache    │   │ click events     │
                 │ + single-flight     │   └────────┬─────────┘
                 └──────────┬──────────┘            │ batches of ~490
                 ┌──────────▼───────────────────────▼──────────┐
                 │ Postgres (sqlx pool, statement timeout)      │
                 └──────────────────────────────────────────────┘
```

Layering: `handlers → services → domain ← repositories → db`. Handlers never
touch SQL, services never touch axum types, and `domain/` imports nothing from
the project.

---

## Quick start

**Prerequisites:** Docker, and for local development Rust (stable),
[`just`](https://github.com/casey/just), `sqlx-cli` and [`oha`](https://github.com/hatoo/oha).

```bash
cp .env.example .env          # set POSTGRES_PASSWORD and ANALYTICS_IP_SALT
docker compose up -d --build app
curl localhost:3000/health/ready              # {"status":"ready"}

curl -s -X POST localhost:3000/shorten \
  -H 'content-type: application/json' -d '{"url":"https://example.com"}'
curl -i localhost:3000/<code>                 # 307 → https://example.com
curl -s localhost:3000/<code>/stats           # {"code":"…","clicks":1}

docker compose stop app                       # graceful: drains and flushes
```

Local development without the app container:

```bash
just up            # Postgres + Redis
just run           # cargo run --release
just test          # unit + integration tests
```

---

## API

| Method | Path | Description |
|---|---|---|
| `POST` | `/shorten` | `{"url": "..."}` → `{"code", "short_url"}`. Rejects non-HTTP(S) schemes and private/loopback targets |
| `GET` | `/{code}` | `307` redirect; `404` for unknown or malformed codes |
| `GET` | `/{code}/stats` | `{"code", "clicks"}`; `404` if the link doesn't exist |
| `GET` | `/health/live` | liveness: `200` while the process runs |
| `GET` | `/health/ready` | readiness: `200`, or `503` when draining or the DB is unreachable |
| `GET` | `/metrics` | Prometheus exposition |
| `GET` | `/debug/*` | cache and analytics internals — development only |

---

## Configuration

Layered with [figment](https://docs.rs/figment); later layers override earlier ones:

```text
configs/default.toml → configs/{APP_ENV}.toml → LINKFORGE__SECTION__KEY env vars
```

Secrets come only from the environment: `DATABASE_URL`, `ANALYTICS_IP_SALT`,
`JWT_SECRET`. Example override: `LINKFORGE__RATE_LIMIT__REQUESTS=500`.

`Settings::validate()` refuses to start on unsafe combinations, including:
timeouts not ordered statement < acquire < request, a rate-limit bucket TTL
shorter than its window, and — in production — a missing IP salt, debug routes
enabled, or synchronous click writes.

---

## Testing

| Layer | What it covers |
|---|---|
| Unit tests | domain invariants, base62, token bucket math, config validation (`figment::Jail`) |
| Integration tests | real server + throwaway Postgres DB per test: redirects, cache coherence, restart survival, rate limiting, click accounting, health probes |
| `scripts/load_test.sh` | throughput, correctness under concurrency, negative caching, single-flight, click conservation, sync vs async |
| `scripts/behaviour_test.sh` | error contracts, response hygiene, SSRF inputs, cache churn, hostile clients, per-IP isolation |
| `scripts/metrics_test.sh` | exposition validity, exact counters, histogram consistency, cardinality, real Prometheus scrape |
| `scripts/container_test.sh` | image hygiene, end-to-end flow, SIGTERM under load, restart persistence, fail-fast config |

Every probe asserts that it did real work: a test that passes for the wrong
reason is treated as worse than one that fails.

---

## Progress

| Phase | Concept | Milestone | Status |
|---|---|---|---|
| 0 | Bootstrap | — | ✅ |
| 1 | Core service, in-memory | M1: It works | ✅ |
| 2 | Persistence + cache coherence | M2: It remembers | ✅ |
| 3 | Middleware, rate limiting, observability | M3: It's defensible | ✅ |
| 4 | Background work and channels | M4: It's fast | ✅ |
| 5 | Production hardening | M5: It ships | ✅ |
| 6 | Redis cache | — | next |

> Env for all numbers: GitHub Codespaces, 2 vCPU, Postgres co-located, `oha`
> load generator on the same host, hot read path `GET /{code}` at c=100 unless noted.
> Phases 1–3 were measured on a **debug build** (see Phase 3); compare those
> only with each other.

### Phase 1 — Core service, in-memory ✅

Shorten → redirect over HTTP with `Arc<RwLock<HashMap>>`, base62 codes from an
`AtomicU64`, and a typed `AppError` implementing `IntoResponse`.

| c | req/s | p50 | p99 |
|---|---|---|---|
| 50 | 10,394 | 4.57 ms | 11.66 ms |
| 100 | 9,763 | 9.82 ms | 23.04 ms |

- 10,000 concurrent POSTs → 0 duplicate codes.
- Cache lookup (criterion): 39.75 ns.
- `DashMap` vs `RwLock<HashMap>` and 2 vs 10 worker threads made no measurable
  difference at this load.

### Phase 2 — Persistence + cache coherence ✅

Postgres via sqlx with migrations, a read-through cache behind a `Cache` trait,
negative caching for unknown codes, and single-flight to collapse concurrent misses.

| Probe | Result |
|---|---|
| Hot read path @ c=100 | 9,783 req/s · p50 9.55 ms · p99 25.13 ms |
| Negative caching | 501 requests for one unknown code → **1 DB query** |
| Single-flight | 100 concurrent misses → **1 DB query** |
| Restart | links resolve after the process restarts |

Criterion: cache hit 219 ns vs DB lookup 450 µs — **a miss costs ~2,050× a hit**,
which is the measured justification for the cache.

### Phase 3 — Middleware, rate limiting, observability ✅

Structured tracing with per-request spans, `x-request-id` propagation, and a
hand-written `tower::Layer` token bucket per IP in a `DashMap`.

- Exceeding the bucket returns `429` with `retry-after`.
- Request IDs are echoed, generated when absent, and present on errors.

**Regression isolated.** Throughput fell from 9,783 to 5,583 req/s. Removing
pieces one at a time attributed it:

| Config | req/s |
|---|---|
| Middleware removed, logging off | 9,090 |
| Middleware on, log output off | 6,973 |
| Full stack | 5,583 |

Span construction cost about 23% and log emission about 20% more; the rate
limiter cost nothing measurable. Compile-time log filtering
(`release_max_level_info`) and a non-blocking writer were added in response.

**Build-profile correction.** All benchmarks up to this point were debug builds.
The same code built with `--release`:

| Build | req/s | p50 | p99 |
|---|---|---|---|
| debug | 5,631 | 16.97 ms | 39.12 ms |
| release | **27,106** | **3.35 ms** | **9.78 ms** |

The "~10k req/s environment ceiling" from Phase 1 was a debug-build ceiling.
All later numbers are release builds.

### Phase 4 — Background work and channels ✅

Every redirect records a click. In async mode the redirect calls `try_send` on a
bounded channel and returns; a worker batches inserts. `click_mode = "sync"` is
kept as a baseline that awaits the `INSERT` on every redirect.

| Mode | req/s | p50 | p99 |
|---|---|---|---|
| sync | 1,532 | 56.82 ms | 191.80 ms |
| async | **15,979** | **5.65 ms** | **17.74 ms** |

**p99 −90.8%, throughput 10.4×** (reproduced across two runs). Sync is
pool-bound: 100 clients queue for 20 connections (Little's Law: 1,532 × 0.065 s ≈ 100).

- Writer: ~493 rows per `INSERT`, 0 failed batches, conservation gap 0.
- 2,000 redirects → exactly 2,000 rows, visible via `/stats` in ~25 ms.
- **Backpressure is drop-on-full**, by design: a slow database must not slow
  redirects. Drops were 0–6.5% at ~15–16k req/s; one run with a 2.06 s
  Postgres write stall dropped 20% while redirect latency stayed flat.
- A sweeper evicts idle rate-limit buckets so the per-IP map can't grow forever.

### Phase 5 — Production hardening ✅

Graceful shutdown, liveness/readiness probes, Prometheus metrics, layered
config with startup validation, request and DB statement timeouts, and a
multi-stage distroless Docker image running as non-root.

**Hot path in the container**

| Run | req/s | p50 | p99 |
|---|---|---|---|
| Phase 4 async (host) | 15,979 | 5.65 ms | 17.74 ms |
| Phase 5 async (container) | 13,415 | 6.31 ms | 22.93 ms |

The −16% is not yet attributed: the move into a container, the metrics
middleware and the timeout layer all landed together. Drops in the container
were 14–15% across two runs.

**Server-side vs client-side latency**

| | p50 | p99 |
|---|---|---|
| Server (Prometheus `histogram_quantile`) | 17 µs | 176 µs |
| Client (oha, c=100) | 6.31 ms | 22.93 ms |

Over 99% of client-observed latency is outside the handler — TCP, scheduling and
queueing on 2 vCPUs. Prometheus rate (13,330 req/s) agrees with oha (13,415 req/s).

**Graceful shutdown under load**

| Environment | Redirects | Rows in DB | Dropped | 5xx | Exit |
|---|---|---|---|---|---|
| Host | 105,780 | 105,780 | 0 | 0 | clean |
| Host, 2.06 s DB stall | 76,733 | 60,991 | 15,742 | 0 | clean |
| **Container** | **112,273** | **112,273** | **0** | **0** | **0 in 5.7 s** |

Shutdown sequence: SIGTERM → readiness 503 (337 ms later) → delay → stop
accepting → drain in-flight requests → click channel closes → writer flushes →
sweeper stops → exit. Every accepted click reached Postgres.

**Metrics:** exposition passes `promtool`; counters are exact (500 redirects →
+500 requests, latency samples, clicks and rows); 61 distinct paths created 0 new
series because labels use route templates.

---

## Benchmark methodology

A comparison is only valid if both runs meet all of these:

1. **Release build.**
2. **Fresh database** (`docker compose down -v`): write cost grows with table size.
3. **Bench-mode rate limit** (`LINKFORGE__RATE_LIMIT__REQUESTS=100000000`): the
   load generator is one IP and would otherwise measure the limiter.
4. **DNS+dialup under ~7 ms** in the oha report: above that, the host was
   contended and the run is discarded.
5. **Nothing else on port 3000**, and the expected server confirmed in the logs.

```bash
just load-test async     # fresh DB, bench-mode container, full harness
just metrics-test
./scripts/container_test.sh
```

---

## What I learned

- **Measure, then attribute.** Two "regressions" disappeared on a rerun, and one
  was entirely the debug build. Any number from a single run is a hypothesis.
- **Check the probe, not just the result.** Several failures were instrumentation:
  a counter read from the wrong field, a gauge set from two tasks, a test that
  hit the domain validator instead of the cache, a container that never bound its
  port while an old server answered every check.
- **Backpressure is a product decision.** Dropping clicks keeps redirects fast;
  blocking would turn a slow database into a slow service.
- **Shutdown is an ordering problem.** Stop HTTP, then close the channel, then the
  pool — each stage depends on the previous one having finished.
- **Observability has a price.** Per-request spans and logs cost ~40% throughput
  in debug builds; that cost is now measured and partly compiled out.

---

## Roadmap

- **CI** — GitHub Actions: fmt, clippy, tests against a Postgres service,
  `sqlx prepare --check`, Docker build.
- **Open experiments** — attribute the −16% container drop (host run of the same
  code) and the Phase 3 → 4 click-path cost (discard-sink writer).
- **Phase 6** — Redis cache behind the existing `Cache` trait; measure a network
  hop against the 17 µs server-side p50.
- **Phase 7** — multi-tenant JWT / API-key auth as a tower layer.
- **Phase 9** — idempotency keys on `POST /shorten`.
- **Phase 10** — Grafana dashboards from the existing metrics.

### Known limitations

- Single instance: the in-process rate limiter and ID counter are per-process.
- In this Codespace Docker's bridge DNS is broken, so the app container uses
  `network_mode: host` and reaches Postgres at `localhost:5432`. On a normal
  Docker host, use the bridge network and `postgres:5432`.
