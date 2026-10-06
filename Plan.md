# LinkForge — Master Engineering Guide (v2: Distributed Systems)

**A URL shortener used as a vehicle for learning Rust backend and distributed-systems engineering.**
**Author:** Dhruv Charne · **Stack:** axum · tokio · tower · sqlx (Postgres) · Redis · nginx · tracing · OpenTelemetry · Prometheus · Docker

This guide has two halves:

- **Phases 0–5 (complete):** a single-node service, built and measured. Kept here as a record.
- **Phases 6–12 (this revision):** turning LinkForge into a distributed system. Each phase introduces **one** distributed-systems concept and ends with a **guarantee proven under failure**, not just a feature that works on the happy path.

Like v1, the guide is both a **spatial map** (where code lives) and a **temporal map** (when it gets built). When the code and this document disagree, update this document first.

---

## Table of contents

- [LinkForge — Master Engineering Guide (v2: Distributed Systems)](#linkforge--master-engineering-guide-v2-distributed-systems)
  - [Table of contents](#table-of-contents)
  - [1. How to read this guide](#1-how-to-read-this-guide)
  - [2. Guiding principles](#2-guiding-principles)
  - [3. What "distributed" means here](#3-what-distributed-means-here)
  - [4. Target architecture](#4-target-architecture)
  - [5. The guarantees](#5-the-guarantees)
  - [6. Layering and dependency rules](#6-layering-and-dependency-rules)
  - [7. Repository layout](#7-repository-layout)
  - [8. Phase → directory activation matrix](#8-phase--directory-activation-matrix)
  - [9. Completed phases (0–5)](#9-completed-phases-05)
  - [10. Distributed roadmap (6–12)](#10-distributed-roadmap-612)
    - [Phase 6 — Scale-out and distributed IDs (≈ 1 week)](#phase-6--scale-out-and-distributed-ids--1-week)
    - [Phase 7 — Shared cache and cross-node invalidation (≈ 1–1.5 weeks)](#phase-7--shared-cache-and-cross-node-invalidation--115-weeks)
    - [Phase 8 — Distributed rate limiting (≈ 0.5–1 week)](#phase-8--distributed-rate-limiting--051-week)
    - [Phase 9 — Durable event pipeline (≈ 1.5–2 weeks)](#phase-9--durable-event-pipeline--152-weeks)
    - [Phase 10 — Idempotency keys (≈ 3–5 days)](#phase-10--idempotency-keys--35-days)
    - [Phase 11 — Replication, consistency and leadership (≈ 1.5–2 weeks)](#phase-11--replication-consistency-and-leadership--152-weeks)
    - [Phase 12 — Distributed observability and chaos (≈ 1–1.5 weeks)](#phase-12--distributed-observability-and-chaos--115-weeks)
  - [11. Testing strategy](#11-testing-strategy)
  - [12. Benchmark and chaos methodology](#12-benchmark-and-chaos-methodology)
  - [13. Environment requirements](#13-environment-requirements)
  - [14. Milestones and definition of done](#14-milestones-and-definition-of-done)
  - [15. Explicit non-goals](#15-explicit-non-goals)
  - [16. Risks](#16-risks)
  - [17. Immediate next steps](#17-immediate-next-steps)

---

## 1. How to read this guide

| Question | Answered by |
|---|---|
| "Where does this code belong?" | §6 layering, §7 layout |
| "Should I be building this now?" | §8 matrix, §10 roadmap |
| "Is this phase actually done?" | §5 guarantees, §14 definition of done |

**Golden rule (unchanged):** dependencies point inward and downward: HTTP → services → domain → repositories → infrastructure. Never the reverse.

**New rule for Phases 6–12:** a feature isn't done when it works. It's done when the guarantee it provides **survives the failure it was designed for**, and a test proves it.

---

## 2. Guiding principles

The five v1 principles still apply. Three are added for distributed work.

1. **One concept per phase.** Anything that doesn't teach a new idea goes in `BACKLOG.md`.
2. **Measure before you optimize.** Every claimed win has a number and a methodology.
3. **Failure is a first-class feature.** No `.unwrap()` in request paths.
4. **Vertical slices.** Every phase ends with something you can `curl`.
5. **Idiomatic over clever.** Standard patterns over invented ones.
6. **State the guarantee before writing the code.** Each phase starts by writing down *what must stay true, and under which failure*.
7. **Prove it by breaking it.** Every guarantee has a chaos test that kills, delays or partitions the component it depends on.
8. **Prefer boring infrastructure.** Postgres and Redis over new systems. Never hand-roll consensus.

---

## 3. What "distributed" means here

Running several containers doesn't make a system distributed. For this project, LinkForge is distributed when:

- **More than one app instance** serves traffic, and any instance can serve any request.
- **No instance holds state that others need** to answer correctly.
- **Components fail independently**, and the system keeps its guarantees (or degrades in a documented way) when one does.
- **Every guarantee is tested** by killing, slowing or partitioning a component under load.

---

## 4. Target architecture

```text
                 oha / chaos suite (separate machine where possible)
                                │
                          ┌─────▼─────┐
                          │   nginx   │  load balancer, health-checked upstreams
                          └──┬──┬──┬──┘
                    ┌────────┘  │  └────────┐
               ┌────▼───┐  ┌────▼───┐  ┌────▼───┐
               │ app-1  │  │ app-2  │  │ app-3  │  stateless; L1 in-process cache
               └─┬───┬──┘  └─┬───┬──┘  └─┬───┬──┘
                 │   └───────┼───┼───────┘   │
                 │       ┌───▼───▼───┐       │
                 │       │   Redis   │  L2 cache · pub/sub invalidation ·
                 │       │           │  global rate limit · click stream
                 │       └─────┬─────┘
                 │       ┌─────▼──────┐
                 │       │ consumer×N │  stream consumer group →
                 │       └─────┬──────┘  idempotent batched inserts
               ┌─▼─────────────▼─┐        ┌──────────────┐
               │ Postgres primary │──WAL──►│ Postgres     │  read routing,
               │ (writes, IDs)    │        │ replica      │  replication lag
               └──────────────────┘        └──────────────┘

   Prometheus ◄── /metrics (all processes)      Jaeger ◄── OTLP traces
   Grafana    ◄── Prometheus                    toxiproxy between app ↔ Redis/Postgres
```

Each box lights up in a specific phase (§8).

---

## 5. The guarantees

These are the system's contract. Every one maps to a test in §11.

| ID | Guarantee | Introduced | Failure it must survive |
|---|---|---|---|
| **G1** | No two links ever get the same code | P6 | concurrent writes on N instances; instance restart |
| **G2** | A created link resolves from every instance | P6 | instance killed mid-load |
| **G3** | After a link changes, no instance serves the old value for longer than a bounded time | P7 | Redis pub/sub message lost; Redis restart |
| **G4** | Cache unavailability degrades latency, never correctness | P7 | Redis down |
| **G5** | A client's request rate is limited globally, within a stated error | P8 | requests spread across instances |
| **G6** | Every accepted click is persisted **exactly once** | P9 | `kill -9` of an app instance or consumer under load |
| **G7** | Retrying `POST /shorten` with the same key creates exactly one link | P10 | concurrent retries on different instances |
| **G8** | A client can read a link it just created (read-your-writes) | P11 | replica lagging behind the primary |
| **G9** | Exactly one node runs each singleton background job | P11 | the node holding the job dies |
| **G10** | Any request can be followed across every process it touched | P12 | — |

Phase 5's single-node guarantees (graceful drain, no lost clicks on SIGTERM, fail-fast config, bounded label cardinality) remain in force and stay in the test suite.

---

## 6. Layering and dependency rules

Unchanged from v1, plus two additions:

| Layer | Directory | Knows about | Must NOT contain |
|---|---|---|---|
| Transport | `handlers/`, `app/` | services, DTOs, errors | SQL, business rules |
| Business | `services/` | domain, repository and infrastructure **traits** | axum types, concrete Redis/sqlx types |
| Domain | `domain/` | nothing | axum, sqlx, tokio, redis |
| Data access | `repositories/` | domain, db | HTTP, business rules |
| Infrastructure | `db/`, `cache/`, `ids/`, `events/`, `coordination/`, `workers/` | domain types | handler logic |

**Additions:**

- **Every distributed dependency sits behind a trait** (`Cache`, `IdAllocator`, `ClickSink`, `RateLimiter`, `LeaderLease`). Services never import `redis` or a specific Postgres role. This keeps single-node mode working and makes fault injection in tests possible.
- **Each binary has one job.** `linkforge` (HTTP API) and `linkforge-consumer` (stream consumer) share the library crate but not their `main`.

---

## 7. Repository layout

New or changed items are marked **★**.

```text
linkforge/
├── Cargo.toml
├── Cargo.lock
├── justfile
├── .env.example
├── Dockerfile                    ★ builds both binaries
├── docker-compose.yml            single-node dev stack
├── docker-compose.cluster.yml    ★ nginx + 3 apps + consumers + replica + observability
├── README.md
├── BACKLOG.md
├── NOTES.md                      per-phase learning journal
│
├── .github/workflows/ci.yml      ★ fmt, clippy, tests, sqlx check, image build
├── migrations/
│   ├── 0001_init.sql
│   ├── 0002_add_clicks.sql
│   ├── 0003_link_id_sequence.sql      ★ P6
│   ├── 0004_click_event_ids.sql       ★ P9 (unique event_id)
│   └── 0005_idempotency_keys.sql      ★ P10
├── configs/
│   ├── default.toml
│   ├── development.toml
│   ├── production.toml
│   └── cluster.toml              ★ instance-aware settings
├── deploy/                       ★
│   ├── nginx/nginx.conf
│   ├── postgres/primary.conf, replica.conf, init-replica.sh
│   ├── prometheus/prometheus.yml
│   ├── grafana/dashboards/*.json
│   └── toxiproxy/proxies.json
├── scripts/
│   ├── load_test.sh
│   ├── behaviour_test.sh
│   ├── metrics_test.sh
│   ├── container_test.sh
│   └── cluster_test.sh           ★ multi-instance acceptance
├── chaos/                        ★ one script per guarantee
│   ├── g1_unique_codes.sh
│   ├── g3_invalidation.sh
│   ├── g6_click_exactly_once.sh
│   ├── g8_read_your_writes.sh
│   └── lib.sh
├── tests/
│   ├── api/
│   ├── integration/
│   ├── cluster/                  ★ spawns N in-process instances sharing Postgres/Redis
│   └── common/
├── benches/
│
└── src/
    ├── main.rs                   HTTP API binary
    ├── bin/consumer.rs           ★ P9 stream consumer binary
    ├── lib.rs
    ├── app/                      router, state, serve()
    ├── config/
    ├── handlers/
    ├── domain/
    ├── services/
    ├── repositories/
    ├── db/
    │   ├── pool.rs
    │   └── routing.rs            ★ P11 primary/replica selection
    ├── cache/
    │   ├── mod.rs                Cache trait
    │   ├── in_memory.rs          L1
    │   ├── redis_cache.rs        ★ P7 L2
    │   ├── tiered.rs             ★ P7 L1 + L2
    │   └── invalidation.rs       ★ P7 pub/sub listener
    ├── ids/                      ★ P6
    │   ├── mod.rs                IdAllocator trait
    │   └── block_allocator.rs    leased ranges from a Postgres sequence
    ├── events/                   ★ P9
    │   ├── mod.rs                ClickSink trait
    │   ├── channel_sink.rs       Phase 4 in-memory sink (single-node mode)
    │   └── redis_stream.rs       durable sink + consumer group
    ├── coordination/             ★ P8, P11
    │   ├── rate_limit_redis.rs   Lua token bucket
    │   └── leader.rs             Postgres advisory-lock lease
    ├── middleware/
    ├── workers/
    ├── observability/
    │   ├── tracing.rs
    │   ├── metrics.rs
    │   └── otel.rs               ★ P12 OTLP exporter + context propagation
    ├── errors/
    └── utils/
```

---

## 8. Phase → directory activation matrix

● primary work ○ touched

| Directory / file | P6 | P7 | P8 | P9 | P10 | P11 | P12 |
|---|---|---|---|---|---|---|---|
| `ids/`, migration 0003 | ● | | | | | | |
| `deploy/nginx`, cluster compose | ● | ○ | | ○ | | ○ | ○ |
| `services/shortener.rs` | ● | | | | ● | ○ | |
| `cache/redis_cache.rs`, `tiered.rs`, `invalidation.rs` | | ● | | | | ○ | |
| `coordination/rate_limit_redis.rs` | | | ● | | | | |
| `middleware/rate_limit.rs` | | | ○ | | | | |
| `events/`, `bin/consumer.rs`, migration 0004 | | | | ● | | | |
| `workers/analytics_writer.rs` | | | | ○ | | | |
| migration 0005, idempotency repo | | | | | ● | | |
| `db/routing.rs`, `deploy/postgres` | | | | | | ● | |
| `coordination/leader.rs`, `workers/bucket_sweeper.rs` | | | | | | ● | |
| `observability/otel.rs`, `deploy/grafana` | | | | | | | ● |
| `chaos/` | ● | ● | ● | ● | ● | ● | ● |
| `tests/cluster/` | ● | ● | ● | ● | ● | ● | ○ |

---

## 9. Completed phases (0–5)

All five core milestones are complete. Full write-ups live in `docs/progress/`.

| Phase | Concept | Milestone | Key measured result |
|---|---|---|---|
| 0 | Bootstrap | — | `GET /health` |
| 1 | In-memory core | M1: It works | 10,000 concurrent POSTs → 0 duplicate codes |
| 2 | Persistence + cache coherence | M2: It remembers | cache miss ≈ 2,050× a hit; negative cache 501 → 1 DB query; single-flight 100 → 1 |
| 3 | Middleware, rate limit, observability | M3: It's defensible | regression attributed (spans −23%, log emission −20%); debug → release 5,631 → 27,106 req/s |
| 4 | Background work, channels | M4: It's fast | async vs sync p99 −90.8% (191.8 → 17.7 ms) |
| 5 | Production hardening | M5: It ships | container SIGTERM under load: 112,273 served = 112,273 rows, exit 0 in 5.7 s; server-side p50 17 µs |

**What Phase 6 inherits, and why it breaks with more than one instance:**

| Phase 0–5 component | Single-node behaviour | With N instances |
|---|---|---|
| `AtomicU64` code counter | unique | **duplicates** across instances |
| In-process cache | coherent | each instance has a different view; stale reads |
| Negative cache | correct | can pin a 404 for a link another instance just created |
| Per-IP `DashMap` rate limiter | correct | effective limit = N × configured |
| In-memory click channel | lossless on graceful shutdown | **loses queued clicks on crash** |
| Bucket sweeper | one per process | harmless duplicates; real problem for future singleton jobs |

Each row is a phase in §10.

---

## 10. Distributed roadmap (6–12)

Estimates assume a few focused hours a day, at the pace of Phases 0–5. Every phase follows the same structure:

> **Concept → What breaks → Guarantee → Design → Files → Acceptance (under failure) → Metrics → Questions for NOTES.md**

### Phase 6 — Scale-out and distributed IDs (≈ 1 week)

**Concept:** stateless services; generating unique IDs without a single point of coordination per request.

**What breaks:** two instances each start their `AtomicU64` at `MAX(id) + 1` and issue the same codes.

**Guarantees:** G1, G2.

**Design:**
- `IdAllocator` trait with a `BlockAllocator`: each instance leases a block of IDs (for example 1,000) from a Postgres sequence via `SELECT nextval(...)` with an increment equal to the block size, and hands them out from memory. A new block is fetched before the current one runs out.
- Gaps in codes are expected (a crashed instance abandons its block) and documented.
- nginx round-robin across three instances, with passive health checks.
- Instance identity (`INSTANCE_ID`) in logs and metrics labels.
- **Prerequisite:** working Docker bridge DNS (see §13). Host networking can't run three instances on one port.

**Files:** `ids/`, migration 0003, `services/shortener.rs`, `deploy/nginx/`, `docker-compose.cluster.yml`, `tests/cluster/`.

**Acceptance (under failure):**
- 30,000 concurrent `POST /shorten` spread across 3 instances → **0 duplicate codes**.
- `docker kill` one instance mid-load → nginx routes around it; every link created anywhere resolves from every remaining instance.
- Restart all instances → no reused codes (IDs only move forward).

**Metrics:** `linkforge_id_blocks_leased_total`, `linkforge_id_block_remaining`.

**NOTES.md:** Why does a per-process counter break? What are the trade-offs between leased blocks, UUIDs and Snowflake-style IDs? Why are gaps acceptable here?

---

### Phase 7 — Shared cache and cross-node invalidation (≈ 1–1.5 weeks)

**Concept:** cache coherence across nodes; consistency vs latency.

**What breaks:** instance A updates or deletes a link; instances B and C keep serving their cached value. The negative cache makes this worse: a 404 cached on B survives after A creates the link.

**Guarantees:** G3, G4.

**Design:**
- Two-tier cache behind the existing `Cache` trait: **L1** in-process (short TTL) → **L2** Redis → Postgres.
- On write or delete, publish the code on a Redis pub/sub channel; every instance evicts it from L1.
- Pub/sub is fire-and-forget, so messages can be lost. L1 TTL is the **upper bound on staleness**, and that bound is the stated guarantee. Document it.
- Redis failure: circuit breaker → skip L2 and go to Postgres. Single-flight still protects Postgres.
- Add a minimal `DELETE /{code}` (or update) endpoint so invalidation has something to invalidate.

**Files:** `cache/redis_cache.rs`, `cache/tiered.rs`, `cache/invalidation.rs`, `services/redirect.rs`.

**Acceptance (under failure):**
- Delete on instance A → B and C return 404 within the L1 TTL. Measure the actual propagation time.
- Drop pub/sub messages (toxiproxy) → staleness never exceeds the L1 TTL.
- Stop Redis under load → **0 5xx**, latency rises, recovery after restart without manual action.
- Benchmark: L1 hit vs L2 (Redis) hit vs Postgres, compared with the 17 µs Phase 5 server-side p50.

**Metrics:** `linkforge_cache_lookups_total{tier,result}`, `linkforge_cache_invalidations_total{source}`, `linkforge_redis_errors_total`.

**NOTES.md:** Why can't pub/sub alone guarantee coherence? What staleness bound does the design give, and where does it come from? Is a network cache worth it against a 17 µs local hit?

---

### Phase 8 — Distributed rate limiting (≈ 0.5–1 week)

**Concept:** global coordination and its latency cost.

**What breaks:** each instance enforces the limit independently, so a client spread across three instances gets 3× the allowance.

**Guarantee:** G5.

**Design:**
- Token bucket in Redis, updated atomically by a **Lua script** (one round trip per request).
- `RateLimiter` trait: local (Phase 3), Redis (global), and a hybrid that keeps local buckets with periodic synchronisation, to compare accuracy against latency.
- Redis failure: fail open, with a metric and a log line. Documented as a deliberate choice.

**Files:** `coordination/rate_limit_redis.rs`, `middleware/rate_limit.rs`.

**Acceptance (under failure):**
- A client sending through all three instances is limited to the configured global rate within a stated error (for example ±5%).
- Redis down → requests are still served; `rate_limit_degraded` metric increases.
- Latency cost of the global limiter measured against the local one.

**NOTES.md:** Why does the check have to be atomic? Fail open or fail closed, and for whom? What does each `RateLimiter` implementation trade?

---

### Phase 9 — Durable event pipeline (≈ 1.5–2 weeks)

**Concept:** at-least-once delivery, idempotent consumers, effectively-once results.

**What breaks:** the Phase 4 in-memory channel loses every queued click when an instance is killed with SIGKILL or crashes. Graceful shutdown only covers SIGTERM.

**Guarantee:** G6.

**Design:**
- `ClickSink` trait. The redirect path appends to a **Redis Stream** (`XADD`) instead of a local channel. The Phase 4 channel stays as the single-node implementation.
- Each click gets a unique `event_id` at creation time.
- `linkforge-consumer` binary: a **consumer group** reads batches, inserts with `ON CONFLICT (event_id) DO NOTHING`, then acknowledges. Unacknowledged entries from a dead consumer are reclaimed with `XAUTOCLAIM`.
- Redelivery is expected; the unique constraint makes it harmless. That's the core lesson: **at-least-once delivery + idempotent writes = exactly-once results**.
- Backpressure: stream length capped (`MAXLEN ~`), drops counted, consistent with the Phase 4 policy.
- Decide and document what happens when Redis is down: drop and count, or fall back to the local channel.

**Files:** `events/`, `bin/consumer.rs`, migration 0004, `workers/analytics_writer.rs` (moved or retired).

**Acceptance (under failure):**
- `kill -9` an **app instance** mid-load → every click it acknowledged to Redis reaches Postgres.
- `kill -9` a **consumer** mid-batch → its pending entries are reclaimed by another consumer; **0 lost, 0 duplicated**.
- Conservation check: clicks accepted = rows in Postgres + counted drops, exactly.
- Throughput and redirect p99 compared with the Phase 4 in-memory pipeline.

**Metrics:** stream length, consumer lag, pending entries, redeliveries, duplicate inserts suppressed.

**NOTES.md:** Why is "exactly-once delivery" the wrong goal? Where can a duplicate come from, and what removes it? What does durability cost on the redirect path?

---

### Phase 10 — Idempotency keys (≈ 3–5 days)

**Concept:** exactly-once effects for client retries.

**What breaks:** a client times out and retries `POST /shorten`; the retry lands on a different instance and creates a second link.

**Guarantee:** G7.

**Design:**
- `Idempotency-Key` header. A table `idempotency_keys(key, request_hash, response, created_at)` with a unique key.
- First request inserts the key with status `in_progress`; concurrent duplicates wait or get `409`; completed keys return the stored response.
- Same key with a different body → `422`.
- Keys expire (TTL job, run by one leader once Phase 11 lands).

**Files:** migration 0005, `repositories/idempotency_repository.rs`, `services/shortener.rs`, middleware or extractor.

**Acceptance (under failure):**
- 50 concurrent requests with the same key across three instances → exactly one link, all 50 responses identical.
- Instance killed between creating the link and storing the response → the retry still returns one link.

**NOTES.md:** Why must the key and the link be written in one transaction? What's the difference between this and Phase 9's dedup?

---

### Phase 11 — Replication, consistency and leadership (≈ 1.5–2 weeks)

**Concept:** replication lag, read-your-writes consistency, leader election via leases.

**What breaks:**
- Reads routed to a lagging replica return 404 for a link just created, and **the negative cache stores that 404**, so the link stays broken until the TTL expires even after the replica catches up.
- Every instance runs the bucket sweeper and future cleanup jobs.

**Guarantees:** G8, G9.

**Design:**
- Postgres streaming replication: primary + one replica. `db::routing` sends writes to the primary and cache-miss reads to the replica.
- **Read-your-writes:** after a write, return the primary's WAL position (LSN) to the client in a header or token; reads carrying it go to the primary (or wait for the replica to reach it). Simpler option: route reads to the primary for a short window after the client's write.
- **Never negative-cache a miss served by a replica** without checking the primary. This is the fix for the bug above.
- **Leadership:** singleton jobs acquire a Postgres advisory lock (`pg_try_advisory_lock`) held on a dedicated connection; losing the connection releases it.

**Files:** `db/routing.rs`, `deploy/postgres/`, `coordination/leader.rs`, `services/redirect.rs`, `workers/`.

**Acceptance (under failure):**
- Inject replica lag (toxiproxy delay, or pause WAL replay) → create then immediately redirect → **never 404** for the creating client.
- Reproduce the negative-cache-poisoning bug first (a failing test), then fix it.
- Kill the leader → another instance takes over the job within a bounded time; the job never runs on two nodes at once.

**Metrics:** replication lag, reads by target (`primary|replica`), leader status per instance.

**NOTES.md:** Which consistency guarantee does each read path give? Why is the negative cache dangerous with replicas? Why is a lease safer than "the first instance to start"?

---

### Phase 12 — Distributed observability and chaos (≈ 1–1.5 weeks)

**Concept:** following a request across processes; continuous fault injection.

**What breaks:** a slow redirect could be nginx, any app instance, Redis, a consumer or Postgres, and logs from five processes can't be correlated by hand.

**Guarantee:** G10, and the whole chaos suite running together.

**Design:**
- OpenTelemetry tracing with W3C `traceparent` propagated through nginx, app instances, Redis stream entries and the consumer. Jaeger for viewing traces.
- Prometheus scrapes every process; Grafana dashboards committed as JSON: request rate and latency by instance, cache tiers, rate-limit decisions, stream lag, replication lag, leader status.
- Alert rules for each guarantee (for example consumer lag growing, replication lag above the read-your-writes window).
- `chaos/` suite: one script per guarantee, using `docker kill`, `docker pause` and toxiproxy (latency, bandwidth limits, connection resets, partitions).
- Use the dashboards to find and optimise one measured hot path, closing the observe → optimise loop.

**Files:** `observability/otel.rs`, `deploy/prometheus/`, `deploy/grafana/`, `deploy/toxiproxy/`, `chaos/`.

**Acceptance:**
- One click traced from nginx → app → Redis stream → consumer → Postgres as a single trace.
- Full chaos suite passes: every guarantee G1–G9 holds under its failure.
- One optimisation, found from the dashboards, with before/after numbers.

**NOTES.md:** What does tracing show that metrics don't? Which failure surprised you most?

---

## 11. Testing strategy

| Level | Location | What it proves |
|---|---|---|
| Unit | inline `#[cfg(test)]` | domain rules, ID block arithmetic, Lua bucket logic, config validation |
| Integration | `tests/api`, `tests/integration` | one instance against real Postgres/Redis |
| **Cluster** | `tests/cluster/` | N in-process instances sharing Postgres and Redis: unique codes, cross-node invalidation, global limits, idempotency races |
| Load | `scripts/load_test.sh` | throughput and latency, single node and cluster |
| Container | `scripts/container_test.sh`, `scripts/cluster_test.sh` | images, compose stack, shutdown, nginx routing |
| **Chaos** | `chaos/g*.sh` | each guarantee under its specific failure |

Rules carried over from Phases 0–5:

- Every probe asserts that it did real work. A guarantee test that never triggered its failure is a failed test.
- Count-based assertions (conservation, duplicates) poll with a timeout; never fixed sleeps.
- Tests clear inherited environment variables (`figment::Jail::clear_env`).
- The process-global metrics recorder is installed once per test binary.

---

## 12. Benchmark and chaos methodology

**Performance comparisons are valid only if:**

1. Release builds.
2. Fresh database (`docker compose down -v`).
3. Bench-mode rate limits, or the limiter under test configured explicitly.
4. Load generator on a separate machine where possible; otherwise dialup < 7 ms in the oha report.
5. The expected processes are serving (check logs for `listening` and instance IDs).
6. Results saved per phase (`.loadtest/phaseN_*.env`), never overwritten.

**Every chaos test reports:**

- the failure injected and when,
- the guarantee checked and the measured outcome (counts, durations),
- whether the failure actually took effect (for example the killed container really exited).

**Correctness under failure is the primary acceptance criterion from Phase 6 onward.** Throughput is reported, but a small host can't produce meaningful cluster throughput (§13).

---

## 13. Environment requirements

| Need | Why | Options |
|---|---|---|
| **Working Docker bridge DNS** | nginx and instances find each other by service name; three instances can't share host port 3000 | rebuild the Codespace; Docker on a local machine; a VM |
| **4–8 vCPUs** for cluster benchmarks | 3 apps + nginx + Redis + consumers + 2 Postgres + observability on 2 vCPUs measures contention, not the design | larger Codespace, local machine, cloud VM |
| Separate load-generator host | removes the co-located-load-generator caveat from all earlier phases | second VM or local machine against a remote stack |
| CI | multi-process tests are where flakiness appears first | GitHub Actions with Postgres and Redis service containers |

Correctness and chaos tests are valid on a small machine. Throughput numbers are not.

---

## 14. Milestones and definition of done

| Milestone | Phases | "Done" signal |
|---|---|---|
| M1–M5 | 0–5 | ✅ complete |
| **M6: It scales out** | 6 | 3 instances behind nginx; G1, G2 proven |
| **M7: It agrees** | 7, 8 | shared cache and global limits; G3, G4, G5 proven |
| **M8: It doesn't lose things** | 9, 10 | durable events and idempotent writes; G6, G7 proven under `kill -9` |
| **M9: It's consistent** | 11 | replicas and leadership; G8, G9 proven under lag and leader loss |
| **M10: It's observable under failure** | 12 | one trace across all processes; full chaos suite green |

**A phase is done when:**

- [ ] its guarantee is written in §5 before implementation starts
- [ ] a chaos test injects the failure and the guarantee holds
- [ ] single-node mode still works and all earlier tests still pass in CI
- [ ] new metrics are documented and visible in `/metrics`
- [ ] README Progress row and `docs/progress/phaseN.md` updated with measured results
- [ ] NOTES.md answers the phase's questions
- [ ] tagged `v0.N.0`

**Mastery criteria (additions to v1)** — by the end, without reference you can:

- Explain why per-process state breaks under scale-out, with three examples from this codebase.
- Choose between leased blocks, UUIDs and Snowflake IDs for a given constraint.
- Explain at-least-once delivery + idempotent consumers, and why exactly-once delivery isn't the goal.
- State the staleness bound of a cache design and where it comes from.
- Explain read-your-writes, and how replication lag interacts with caching.
- Explain why a lease-based leader needs a liveness signal, and what happens when it's lost.

---

## 15. Explicit non-goals

To stay one concept per phase, these are out of scope and live in `BACKLOG.md`:

- **Writing a consensus algorithm** (Raft/Paxos). Use Postgres and Redis for coordination.
- **Sharding Postgres by hand.** Worth a separate project.
- **Kafka.** Redis Streams covers consumer groups, acknowledgements and redelivery.
- **Kubernetes.** Optional deployment target after Phase 12, not a learning phase here.
- **Multi-region or geo-replication.**
- **Multi-tenant JWT / API-key auth** (old Phase 7). A middleware concern, not a distributed one; revisit after Phase 12.
- **Redis Cluster / Sentinel high availability.** Redis failure is handled by degradation (G4, Phase 8 fail-open, Phase 9 policy), not by making Redis itself highly available.

---

## 16. Risks

| Risk | Symptom | Mitigation |
|---|---|---|
| Environment can't host the cluster | DNS failures, meaningless benchmarks | fix §13 before Phase 6 |
| Flaky multi-process tests | intermittent CI failures | poll with timeouts; isolate test databases and Redis key prefixes per test |
| Scope creep into infrastructure | weeks on nginx/Postgres config, no new concept learned | keep `deploy/` minimal; config copied from docs is fine |
| Chaos tests that don't actually inject | guarantees "pass" because nothing failed | each chaos test verifies the failure took effect |
| Losing the single-node path | `docker compose up` stops working | trait-based implementations; CI runs both single-node and cluster suites |
| Phase 9/11 taking far longer | stalled progress | ship the simpler variant first (read-from-primary window before LSN tokens; drop-on-Redis-down before fallback sinks) |

---

## 17. Immediate next steps

1. **CI** (0.5–1 day): fmt, clippy, unit + integration tests against Postgres and Redis service containers, `sqlx prepare --check`, Docker build. Badge in README.
2. **Fix the environment** (§13): working bridge DNS and, for benchmarks, a larger host.
3. **Close the two Phase 5 open questions** (1–2 days): host vs container (the −16%), and the click-path cost (discard-sink writer).
4. **Write G1 and G2 tests first**, then start Phase 6 by reproducing duplicate codes with two instances.
5. Create `docs/progress/` and move the detailed Phase 1–5 write-ups there.

**Estimated total for Phases 6–12:** about 8–12 weeks at a few focused hours a day. Phases 9 and 11 are the longest; testing them reliably will take longer than writing them.

---

_Keep this document in sync with the tree. When a phase adds a directory, add it to §7 and §8 first. When a guarantee changes, update §5 and its chaos test together. The guarantees are the contract._
