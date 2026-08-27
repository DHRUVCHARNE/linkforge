# LinkForge — Master Engineering Guide

> **A rate-limited, multi-tenant URL shortener built to master Rust + backend systems engineering.**
>
> **Author:** Dhruv Charne · **Stack:** `axum` · `tokio` · `tower` · `sqlx` (SQLite → Postgres) · `tracing` · `redis`
>
> This document **reconciles two source docs into one**:
> - **ARCHITECTURE** — the *spatial* map: **where** every piece of code lives and what may/may not leak into it.
> - **ROADMAP** — the *temporal* map: **when** each piece is built, one systems concept per phase.
>
> The synthesis binds them together: **every phase names the exact directories it activates, and every directory names the phase that brings it to life.** Build the tree top-down, but *fill* it phase-by-phase.

---

## Table of contents

1. [How to read this guide](#1-how-to-read-this-guide)
2. [Guiding principles (the constitution)](#2-guiding-principles-the-constitution)
3. [Target architecture (end-state)](#3-target-architecture-end-state)
4. [The layering model & dependency rules](#4-the-layering-model--dependency-rules)
5. [Full repository layout (reconciled with your tree)](#5-full-repository-layout-reconciled-with-your-tree)
6. [Phase → directory activation matrix](#6-phase--directory-activation-matrix)
7. [The phased roadmap, mapped to files](#7-the-phased-roadmap-mapped-to-files)
8. [Directory reference (the source of truth)](#8-directory-reference-the-source-of-truth)
9. [Cross-cutting concerns](#9-cross-cutting-concerns)
10. [Request lifecycle, end-to-end](#10-request-lifecycle-end-to-end)
11. [Testing strategy](#11-testing-strategy)
12. [Milestones & definition of done](#12-milestones--definition-of-done)
13. [Discrepancies found in your current tree](#13-discrepancies-found-in-your-current-tree)
14. [Conventions, anti-patterns & risks](#14-conventions-anti-patterns--risks)
15. [Immediate next steps](#15-immediate-next-steps)

---

## 1. How to read this guide

Two questions govern every line of code you'll write:

| Question | Answered by | Section |
|----------|-------------|---------|
| **"Where does this code belong?"** | Architecture (layers, directories) | §4, §8 |
| **"Should I be building this *now*?"** | Roadmap (phases, one concept each) | §6, §7 |

The **golden rule** binds both:

> **Dependencies point inward and downward: HTTP → Services → Domain → Repositories → Infrastructure. Never the reverse.** And you never build a layer before the phase that teaches its concept.

If you can delete `handlers/` and `app/` and the rest still compiles, your layering is correct. If a phase forces you to reason about a *new* systems idea (concurrency, IO, failure), it earns its place; if it doesn't, defer it.

---

## 2. Guiding principles (the constitution)

These five rules override any local convenience. When in doubt, re-read them.

1. **One concept per phase.** Never add a feature that doesn't teach a distinct systems idea. If a change doesn't force you to reason about concurrency, IO, or failure, park it in `BACKLOG.md`.
2. **Measure before you optimize.** Load testing arrives in Phase 3 *before* any optimization, so every "win" is grounded in a real number, not a guess.
3. **Failure is a first-class feature.** Every phase handles its own error paths explicitly (`Result`, `IntoResponse`, timeouts). **No `.unwrap()` in request paths past Phase 1.**
4. **Vertical slices.** Each phase ends with something you can `curl`. You always have a running server.
5. **Idiomatic over clever.** Prefer clear ownership and standard patterns over premature abstraction.

---

## 3. Target architecture (end-state)

This is what LinkForge looks like when all 5 core phases are complete:

```text
                    ┌────────────────────────────────────────────┐
   HTTP client ───► │  axum Router                                │
                    │   ├─ tower middleware stack                 │
                    │   │    • TraceLayer   (request IDs, tracing) │  ← Phase 3
                    │   │    • RateLimitLayer(token bucket)        │  ← Phase 3
                    │   │    • AuthLayer    (JWT / API key)        │  ← Phase 7
                    │   ├─ POST /shorten     (write path)          │  ← Phase 1
                    │   ├─ GET  /:code       (hot read path)       │  ← Phase 1
                    │   ├─ GET  /:code/stats (analytics)           │  ← Phase 4
                    │   └─ GET  /health, /metrics                  │  ← Phase 0 / 5
                    └───────┬───────────────────────┬─────────────┘
                            │                        │
                   ┌────────▼────────┐      ┌────────▼─────────┐
                   │  Read cache     │      │  mpsc channel    │  ← Phase 4
                   │  (DashMap→Redis)│      │  click events    │
                   └────────┬────────┘      └────────┬─────────┘
                     Phase 2│→ Phase 6               │ (batched)
                   ┌────────▼────────────────────────▼─────────┐
                   │  Persistence: sqlx pool (SQLite→Postgres)  │  ← Phase 2 → Phase 8
                   └────────────────────────────────────────────┘
```

Notice the arrows: the *shape* is fixed from the start, but individual boxes light up at different phases. That is the entire point of merging the two docs.

---

## 4. The layering model & dependency rules

LinkForge is a **layered (hexagonal-lite) architecture**. Each layer has one responsibility and knows only about the layer beneath it.

```text
        ┌─────────────────────────────────────────────┐
        │  Transport / HTTP     (handlers, app)        │  ← axum, extractors, status codes
        ├─────────────────────────────────────────────┤
        │  Business logic       (services)             │  ← orchestration, rules, quotas
        ├─────────────────────────────────────────────┤
        │  Domain model         (domain)               │  ← types, invariants, value objects
        ├─────────────────────────────────────────────┤
        │  Data access          (repositories)         │  ← SQL, mapping rows ↔ domain
        ├─────────────────────────────────────────────┤
        │  Infrastructure (db, cache, workers, auth)   │  ← pools, Redis, channels, JWT
        └─────────────────────────────────────────────┘

  Cross-cutting (touch every layer): config, errors, observability, middleware, utils
```

| Layer | Directory | Knows about | Must **NOT** contain |
|-------|-----------|-------------|----------------------|
| Transport | `handlers/`, `app/` | services, DTOs, errors | SQL, business rules |
| Business | `services/` | domain, repositories, cache | axum types, `Json`, `StatusCode` |
| Domain | `domain/` | *nothing* (pure) | axum, sqlx, tokio |
| Data access | `repositories/` | domain, db | HTTP, business rules |
| Infrastructure | `db/`, `cache/`, `workers/`, `auth/` | domain (for types) | handler logic |

**The three rules that keep the codebase from rotting:**

1. **`domain/` imports nothing from the project.** Pure Rust (`String`, `Url`, `chrono`, newtypes). If domain ever needs `sqlx` or `axum`, the abstraction is wrong.
2. **Handlers never touch SQL.** A handler containing `sqlx::query!` is a bug — that belongs in a repository, called via a service.
3. **Services never touch axum.** A service returning `Json<T>` or `StatusCode` couples business logic to the web framework. Services return **domain types or `AppError`**; handlers do the HTTP translation.

---

## 5. Full repository layout (reconciled with your tree)

Your `tree` output showed only `src/`. The complete production repo needs the root scaffolding too. Here is the reconciled whole — **✅ = present in your tree, ⚠️ = needs creating / renaming**:

```text
linkforge/
├── Cargo.toml              ⚠️  crate manifest, deps grouped by concern
├── Cargo.lock              ⚠️  COMMIT IT (this is an application, not a library)
├── justfile                ⚠️  task runner (run/test/lint/migrate/load-test)
├── .env                    ⚠️  local secrets — GIT-IGNORED
├── .env.example            ⚠️  committed template documenting every variable
├── Dockerfile              ⚠️  multi-stage build → slim/distroless runtime
├── docker-compose.yml      ⚠️  local stack: app + Postgres + Redis
├── README.md               ⚠️  front door; link back to this guide
├── BACKLOG.md              ⚠️  park scope-creep ideas here
│
├── migrations/             ⚠️  sqlx migrations (Phase 2)
│   └── 0001_init.sql
├── configs/                ⚠️  non-secret env config (Phase 5)
│   ├── development.toml
│   └── production.toml
├── scripts/                ⚠️  ops shell scripts
│   ├── load_test.sh        #   Phase 3 benchmark harness
│   └── setup_db.sh
├── tests/                  ⚠️  integration tests (black-box via lib.rs)
│   ├── integration/
│   ├── api/
│   └── common/
├── benches/                ⚠️  criterion benchmarks (Phase 3+)
│   └── redirect_bench.rs
│
└── src/
    ├── main.rs             ✅  runtime bootstrap ONLY ("wires, doesn't decide")
    ├── lib.rs              ✅  library root — re-exports every module
    │
    ├── app/                ✅  composition root
    │   ├── mod.rs          #   serve() + graceful shutdown
    │   ├── router.rs       #   create(state) -> Router, middleware order
    │   └── state.rs        #   AppState { Arc<Service> handles }
    ├── config/             ✅  load() -> Settings (once, typed)
    │   ├── mod.rs
    │   └── settings.rs
    ├── handlers/           ✅  thin HTTP adapters
    │   ├── mod.rs
    │   ├── health.rs
    │   ├── shorten.rs
    │   ├── redirect.rs
    │   └── analytics.rs
    ├── domain/             ✅  pure core (types + invariants)
    │   ├── mod.rs
    │   ├── link.rs
    │   ├── short_code.rs
    │   └── click.rs
    ├── services/           ✅  business logic / orchestration
    │   ├── mod.rs
    │   ├── shortener.rs
    │   ├── redirect.rs
    │   └── analytics.rs
    ├── repositories/       ✅  all SQL, behind traits
    │   ├── mod.rs
    │   ├── link_repository.rs
    │   └── click_repository.rs
    ├── db/                 ✅  pool + migration plumbing
    │   ├── mod.rs
    │   ├── pool.rs
    │   └── migrations.rs
    ├── cache/              ✅  Cache trait + Redis impl
    │   ├── mod.rs
    │   └── redis_cache.rs
    ├── middleware/         ✅  tower layers
    │   ├── mod.rs
    │   ├── auth.rs
    │   ├── rate_limit.rs
    │   ├── request_id.rs
    │   └── tracing.rs
    ├── workers/            ✅  background tasks
    │   ├── mod.rs
    │   └── analytics_writer.rs   ⚠️  YOU HAVE analytical_writer.rs — rename (see §13)
    ├── observability/      ✅  logs + metrics
    │   ├── mod.rs
    │   ├── tracing.rs
    │   └── metrics.rs
    ├── auth/               ✅  JWT / API-key primitives
    │   ├── mod.rs
    │   ├── jwt.rs
    │   └── api_key.rs
    ├── errors/             ✅  AppError + IntoResponse
    │   ├── mod.rs
    │   └── app_error.rs
    └── utils/              ✅  small pure helpers
        ├── mod.rs
        ├── base62.rs
        └── time.rs
```

Your `src/` skeleton is **already correct and complete** — 15 directories, all in the right place. What remains is (a) the root scaffolding above the `src/` line, (b) one filename fix, and (c) *filling* each file phase-by-phase.

---

## 6. Phase → directory activation matrix

This is the heart of the synthesis: read it **left-to-right** to plan a phase, or **top-to-bottom** to see when a directory comes alive.

| Directory / file | P0 | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 |
|------------------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `main.rs`, `lib.rs` | ● | | | | | | | | |
| `app/` (router, serve) | ● | ○ | ○ | ○ | | ○ | | ○ | |
| `app/state.rs` | | ● | ○ | | ○ | | ○ | | |
| `handlers/health.rs` | ● | | | | | ○ | | | |
| `handlers/shorten.rs` `redirect.rs` | | ● | ○ | | | | | | |
| `handlers/analytics.rs` | | | | | ● | | | | |
| `domain/` | | ● | ○ | | ○ | | | ○ | |
| `services/shortener` `redirect` | | ● | ○ | | ○ | | ○ | | |
| `services/analytics.rs` | | | | | ● | | | | |
| `errors/` | | ● | ○ | ○ | | | | ○ | |
| `utils/base62.rs` | | ● | | | | | | | |
| `utils/time.rs` | | ○ | ● | | ○ | | | | |
| `repositories/link_repository.rs` | | | ● | | | | | ○ | ● |
| `repositories/click_repository.rs` | | | | | ● | | | | |
| `db/` (pool, migrations) | | | ● | | | ○ | | | ● |
| `migrations/` | | | ● | | ● | | | ● | |
| `cache/` | | | ● | | | | ● | | |
| `middleware/tracing.rs` `request_id.rs` | | | | ● | | | | | |
| `middleware/rate_limit.rs` | | | | ● | | | | ○ | |
| `middleware/auth.rs`, `auth/` | | | | | | | | ● | |
| `workers/analytics_writer.rs` | | | | | ● | | | | |
| `observability/tracing.rs` | | | | ● | | ○ | | | |
| `observability/metrics.rs` | | | | | | ● | | | ● |
| `config/`, `configs/` | | | ○ | | | ● | | | |
| `scripts/load_test.sh`, `benches/` | | | | ● | ○ | | | | ○ |
| `Dockerfile`, `compose` | | | | | | ● | ● | ● | ● |

**● = primary work this phase   ○ = touched/extended this phase**

---

## 7. The phased roadmap, mapped to files

Suggested cadence: **~1 week per phase** at a few focused hours/day. The phases — not the calendar — are the unit of learning.

### Phase 0 — Bootstrap
**Objective:** a running server and clean scaffolding.
**Files:** `main.rs`, `lib.rs`, `app/mod.rs`, `app/router.rs`, `handlers/health.rs`, `justfile`, `Cargo.toml`.
**Tasks:** `cargo new`; `GET /health` → `200 OK`; wire `clippy`/`rustfmt`/`justfile`.
**Deliverable:** `curl localhost:3000/health` → `ok`.
**You learn:** the `#[tokio::main]` runtime, the `Router` + `serve` shape.

### Phase 1 — Core service, in-memory
**Objective:** working shortener, no database.
**Files:** `app/state.rs`, `handlers/shorten.rs` + `redirect.rs`, `domain/link.rs` + `short_code.rs`, `services/shortener.rs` + `redirect.rs`, `errors/app_error.rs`, `utils/base62.rs`.
**Tasks:** `Arc<RwLock<HashMap>>` via `State`; base62 of an `AtomicU64`; `POST /shorten` (validate → code); `GET /:code` → 302/308, 404 on miss; `AppError: IntoResponse`.
**Deliverable:** full shorten→redirect loop over HTTP.
**You learn:** extractors (`Path`, `Json`, `State`), shared mutable state, `RwLock` vs `Mutex` for read-heavy loads, typed errors.
**Acceptance:** concurrent `POST`s never produce a duplicate code.
**⚑ From here on: no `.unwrap()` in request paths.**

### Phase 2 — Persistence + cache coherence
**Objective:** survive restarts; meet your first cache/DB consistency problem.
**Files:** `db/pool.rs` + `migrations.rs`, `repositories/link_repository.rs`, `cache/mod.rs` (in-memory impl first), `migrations/0001_init.sql`, `services/*` (extended), `config/` (DB URL).
**Tasks:** add `sqlx` (SQLite, compile-time-checked queries); `SqlitePool` in state; write path = DB insert then cache populate; read path = cache hit → serve, miss → DB → backfill; `links(id, code, url, created_at)`.
**Deliverable:** data persists across restarts; reads served from cache.
**You learn:** async DB access, connection pooling, migrations, cache invalidation, read-through caching.
**Acceptance:** kill & restart the process — links still resolve.

### Phase 3 — Middleware, rate limiting & observability
**Objective:** make it defensible and observable. **Introduce load testing here.**
**Files:** `middleware/tracing.rs` + `request_id.rs` + `rate_limit.rs`, `observability/tracing.rs`, `app/router.rs` (layer ordering), `scripts/load_test.sh`, `benches/redirect_bench.rs`.
**Tasks:** structured logs + `tracing-subscriber`, per-request spans; propagate `x-request-id`; custom `tower::Layer` token bucket in `DashMap<IpAddr, Bucket>`; baseline throughput/latency with `oha`/`wrk`.
**Deliverable:** per-IP `429`; structured logs with request IDs; a baseline benchmark number in the README.
**You learn:** the `tower::Service` abstraction, middleware ordering, `DashMap` concurrency, observability, how to *measure*.
**Acceptance:** exceeding the rate returns `429`; logs correlate a request across middleware and handler.

### Phase 4 — Background work & channels
**Objective:** get IO off the hot path.
**Files:** `workers/analytics_writer.rs`, `repositories/click_repository.rs`, `services/analytics.rs`, `handlers/analytics.rs`, `domain/click.rs`, `migrations/0002_add_clicks.sql`.
**Tasks:** each redirect sends an event over a **bounded** `mpsc`; a dedicated `tokio::spawn` consumer batches inserts; `clicks(code, ts, ip_hash)` + `GET /:code/stats`; decide + **document** the full-channel policy (drop vs. block).
**Deliverable:** redirects stay fast under load; click counts persist via batched writes.
**You learn:** decoupling hot paths from IO, batching, bounded channels & backpressure, the actor pattern, CPU- vs IO-bound work (`spawn_blocking`).
**Acceptance:** redirect p99 under load is materially better than synchronous writes — prove it with the Phase 3 harness.

### Phase 5 — Production hardening
**Objective:** make it shippable.
**Files:** `app/mod.rs` (`with_graceful_shutdown`), `config/settings.rs` + `configs/*.toml`, `observability/metrics.rs`, `Dockerfile`, request-timeout layer.
**Tasks:** `tokio::signal` + drain in-flight requests; env/file config via `figment`/`envy`; Prometheus `/metrics`; multi-stage Docker image; request + DB statement timeouts.
**Deliverable:** a container that starts, serves, exposes metrics, and shuts down cleanly.
**You learn:** signal handling, request draining, config management, containerization.
**Acceptance:** `SIGTERM` completes in-flight requests before exit; container runs end-to-end.

### Stretch phases (post-core mastery)

| Phase | Upgrade | New concept | Primary files |
|-------|---------|-------------|---------------|
| 6 | In-memory cache → **Redis** (`fred`/`redis-rs`) | caching as a real network hop, serialization, TTLs | `cache/redis_cache.rs` |
| 7 | **Multi-tenant JWT / API-key auth** as a tower layer | middleware composition, per-tenant quotas | `auth/*`, `middleware/auth.rs` |
| 8 | Migrate SQLite → **Postgres**, read replicas conceptually | dialect differences, pooling at scale | `db/pool.rs`, `repositories/*` |
| 9 | **Idempotency keys** on `POST /shorten` | exactly-once semantics, dedup | `services/shortener.rs`, `migrations/` |
| 10 | **Prometheus + Grafana** dashboard; optimize the measured hot path | closing the observe→optimize loop | `observability/`, `benches/` |

The **trait boundaries** in `repositories/` and `cache/` are precisely what make Phases 6 and 8 *drop-in* swaps: you change an implementation, not a single service.

---

## 8. Directory reference (the source of truth)

### `main.rs` — binary entry point
Runtime bootstrap **only**. Short and boring:

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = linkforge::config::load()?;
    linkforge::observability::init(&config);
    let state = linkforge::app::state::build(&config).await?;
    let app   = linkforge::app::router::create(state);
    linkforge::app::serve(app, &config).await   // includes graceful shutdown
}
```

Rule: *`main.rs` wires, it doesn't decide.* Logic growth moves into `app/`.

### `lib.rs` — library root
Re-exports every module so the crate is **usable as a library** (critical for `tests/` and `benches/`):

```rust
pub mod app;    pub mod auth;   pub mod cache;  pub mod config;
pub mod db;     pub mod domain; pub mod errors; pub mod handlers;
pub mod middleware; pub mod observability; pub mod repositories;
pub mod services; pub mod utils; pub mod workers;
```

### `config/`
| File | Contents |
|------|----------|
| `mod.rs` | `load() -> Result<Settings>`; merges `configs/*.toml` + `.env` via `figment`/`envy`. |
| `settings.rs` | Typed `Settings`: `server`, `database`, `redis`, `rate_limit`, `auth`. Parsed **once**, read-only. |

**Rule:** no `std::env::var` scattered across the codebase.

### `app/`
| File | Contents |
|------|----------|
| `mod.rs` | `serve()` — binds `TcpListener`, `axum::serve(...).with_graceful_shutdown(...)`. |
| `router.rs` | `create(state) -> Router` — routes + middleware stack **in order**: trace → request-id → rate-limit → auth. |
| `state.rs` | `AppState` — holds `Arc<Service>` handles, **not raw pools**. |

```rust
#[derive(Clone)]
pub struct AppState {
    pub shortener:  Arc<ShortenerService>,
    pub redirect:   Arc<RedirectService>,
    pub analytics:  Arc<AnalyticsService>,
}
```

Handlers see *services*, never `SqlitePool`/`DashMap` directly. This is dependency injection.

### `handlers/` — thin HTTP adapters
One file per resource; each fn = extract → call service → map result. No logic.

| File | Endpoint(s) |
|------|-------------|
| `health.rs` | `GET /health` (+ `/metrics` liveness) |
| `shorten.rs` | `POST /shorten` |
| `redirect.rs` | `GET /:code` → 302/308 |
| `analytics.rs` | `GET /:code/stats` |

```rust
pub async fn shorten(
    State(st): State<AppState>,
    Json(req): Json<CreateLinkRequest>,
) -> Result<Json<CreateLinkResponse>, AppError> {
    let link = st.shortener.create(req.url).await?;
    Ok(Json(link.into()))
}
```

### `domain/` — the pure core
| File | Contents |
|------|----------|
| `link.rs` | `Link` aggregate: `code`, `target_url`, `created_at`. |
| `short_code.rs` | `ShortCode` newtype — validates length/charset in its constructor. |
| `click.rs` | `Click` event: `code`, `ts`, `ip_hash`. |

```rust
pub struct ShortCode(String);
impl ShortCode {
    pub fn parse(s: &str) -> Result<Self, DomainError> {
        // enforce base62, length 6..=10, etc.
    }
}
```

Invalid states become **unrepresentable**. Easiest, most valuable place for unit tests.

### `services/` — business logic
| File | Responsibility |
|------|----------------|
| `shortener.rs` | Validate URL, generate code, persist, warm cache. |
| `redirect.rs` | Resolve: cache → repo → backfill; emit click event to worker channel. |
| `analytics.rs` | Aggregate click stats for `/stats`. |

```rust
pub struct ShortenerService {
    links: Arc<dyn LinkRepository>,
    cache: Arc<dyn Cache>,
}
```

**Rule:** services return **domain types or `AppError`** — never `Json`/`StatusCode`.

### `repositories/` — data access (all SQL)
| File | Contents |
|------|----------|
| `mod.rs` | `LinkRepository` / `ClickRepository` **traits**. |
| `link_repository.rs` | `SqlxLinkRepository`: `create`, `find_by_code`. Maps rows ↔ `domain::Link`. |
| `click_repository.rs` | Batched inserts for click events. |

```rust
#[async_trait]
pub trait LinkRepository: Send + Sync {
    async fn create(&self, link: &Link) -> Result<(), RepoError>;
    async fn find_by_code(&self, code: &ShortCode) -> Result<Option<Link>, RepoError>;
}
```

The trait boundary is what makes the SQLite→Postgres migration (Phase 8) a drop-in.

### `db/`, `cache/`, `middleware/`, `workers/`, `observability/`, `auth/`, `errors/`, `utils/`

| Dir | Files | Job |
|-----|-------|-----|
| `db/` | `pool.rs`, `migrations.rs` | Build/configure the pool; run `sqlx::migrate!()`. **Plumbing**, not queries. |
| `cache/` | `mod.rs` (`Cache` trait), `redis_cache.rs` | Interchangeable in-memory ↔ Redis via a trait; TTLs, serialization. |
| `middleware/` | `tracing`, `request_id`, `rate_limit`, `auth` | tower layers; **ordering declared in `app/router.rs`**. |
| `workers/` | `analytics_writer.rs` | Consumes bounded `mpsc` click channel, batches inserts. Document backpressure in the header. |
| `observability/` | `tracing.rs`, `metrics.rs` | `init()` subscriber + Prometheus exporter, once at boot. |
| `auth/` | `jwt.rs`, `api_key.rs` | Identity **primitives**; `middleware/auth.rs` *applies* them. |
| `errors/` | `app_error.rs` | `AppError` enum + `IntoResponse`; `From<RepoError/DomainError/sqlx::Error>`. The **only** place status codes meet business errors. |
| `utils/` | `base62.rs`, `time.rs` | Small pure helpers. **Last resort** — promote to `domain/` if it gains meaning. |

```rust
pub enum AppError {
    NotFound, InvalidUrl, RateLimited, Unauthorized, Internal(anyhow::Error),
}
```

---

## 9. Cross-cutting concerns

These five directories touch **every** layer and don't belong to any single one:

- **`config/`** — read once at boot, injected as typed structs.
- **`errors/`** — the `?` operator bubbles domain/repo errors up; `IntoResponse` renders them at the edge.
- **`observability/`** — spans and metrics wrap the whole request; initialized once.
- **`middleware/`** — tower layers wrapping the router; order is load-bearing.
- **`utils/`** — stateless helpers with no domain meaning.

**`mod.rs` convention** (applies everywhere): declare submodules, re-export the public surface, so consumers write `use crate::services::ShortenerService;` not the full path. Pick the `mod.rs` style (which this repo uses) and stay consistent.

---

## 10. Request lifecycle, end-to-end

`POST /shorten`, traced through the layers:

```text
1.  middleware/        → trace span opened, request-id set, rate-limit checked, auth verified
2.  handlers/shorten   → extract Json<CreateLinkRequest>
3.  services/shortener → validate URL, generate ShortCode, orchestrate
4.  domain/short_code  → ShortCode::parse enforces invariants
5.  repositories/link  → INSERT via sqlx
6.  db/pool            → connection handed from pool
7.  cache/             → new link warmed into cache
8.  services returns   → domain::Link
9.  handlers/shorten   → map Link → CreateLinkResponse (Json)
10. errors/app_error   → any ? failure becomes a proper HTTP status + JSON
```

`GET /:code` additionally emits a `Click` onto the `workers/analytics_writer` channel — keeping the redirect path fast (Phase 4's whole point).

---

## 11. Testing strategy

| Test type | Location | Runs against |
|-----------|----------|--------------|
| Unit | inline `#[cfg(test)] mod tests` per file | that module in isolation |
| Domain | inline in `domain/*.rs` | pure types (fast, no IO) |
| Integration | `tests/integration/` | the whole crate via `lib.rs` |
| API/contract | `tests/api/` | a spawned server (status/headers/JSON) |
| Shared harness | `tests/common/` | reusable test DB + app builder |
| Benchmarks | `benches/redirect_bench.rs` | the hot path |

**Why `lib.rs` matters again:** integration tests can only import your app if the logic lives in the library crate, not `main.rs`.

---

## 12. Milestones & definition of done

| Milestone | Marker | "Done" signal |
|-----------|--------|---------------|
| **M1: It works** | End of Phase 1 | shorten→redirect over HTTP |
| **M2: It remembers** | End of Phase 2 | survives restart, cache-backed |
| **M3: It's defensible** | End of Phase 3 | rate-limited, observable, benchmarked |
| **M4: It's fast** | End of Phase 4 | IO off hot path, measured win |
| **M5: It ships** | End of Phase 5 | containerized, graceful shutdown |

**Success criteria (definition of "mastered")** — by the end, without reference you can:

- [ ] Explain why `Arc<RwLock<T>>`, `DashMap`, and an `mpsc`-actor each fit different concurrency shapes.
- [ ] Write an axum handler with custom extractors and a typed error enum implementing `IntoResponse`.
- [ ] Author a `tower::Layer`/`Service` from scratch (rate limiter) and reason about middleware ordering.
- [ ] Decouple a hot path from IO using a bounded channel + background writer, and explain backpressure.
- [ ] Implement graceful shutdown that drains in-flight requests.
- [ ] Justify every dependency and every `.await` point in the codebase.

---

## 13. Discrepancies found in your current tree

Reconciling your actual `tree` output against the architecture doc surfaced these — fix them now so the doc stays the contract:

1. **⚠️ `workers/analytical_writer.rs` → `workers/analytics_writer.rs`.**
   Your file is spelled `analytical_writer.rs`; the architecture and roadmap both call it `analytics_writer.rs`. Rename for consistency (the service, table, and worker should all read *analytics*):
   ```bash
   git mv src/workers/analytical_writer.rs src/workers/analytics_writer.rs
   ```

2. **⚠️ Root scaffolding not yet present.** Your tree shows only `src/`. Before Phase 2 you'll need `Cargo.toml`, `Cargo.lock` (commit it), `justfile`, `.env` + `.env.example`, and `migrations/`. Before Phase 5: `configs/`, `Dockerfile`, `docker-compose.yml`. Add `tests/`, `benches/`, `scripts/`, and `BACKLOG.md` as their phases arrive (§6).

3. **ℹ️ `/metrics` ownership.** `handlers/health.rs` is documented as serving both `/health` and `/metrics`, while `observability/metrics.rs` owns the Prometheus exporter. Keep the *exposition logic* in `observability/` and let the handler be a thin pass-through, so you don't split metric state across two layers.

Everything else in your `src/` tree matches the intended architecture exactly — 15 directories, all correctly placed.

---

## 14. Conventions, anti-patterns & risks

**Do**
- Keep handlers under ~15 lines — extract → call service → map.
- Return `Result<T, AppError>` from anything fallible.
- Put every SQL string behind a repository method.
- Keep a `NOTES.md` per phase: *what concept did this teach, what surprised me?*

**Don't**
- ❌ `sqlx::query!` inside a handler.
- ❌ `Json<T>` / `StatusCode` returned from a service.
- ❌ `axum` / `sqlx` imports inside `domain/`.
- ❌ `.unwrap()` / `.expect()` in a request path (past Phase 1) — lint for it.
- ❌ Raw `SqlitePool` stored in `AppState` — store service handles.
- ❌ Editing a merged migration — always add a new one.
- ❌ Using `utils/` as a dumping ground for logic with domain meaning.

**Risks & how to defuse them**

| Risk | Symptom | Mitigation |
|------|---------|-----------|
| Async lifetime rabbit holes | Fighting the borrow checker across `.await` | Clone/`Arc` deliberately early; refactor to ownership clarity once it compiles |
| Scope creep | Adding auth/UI before core is solid | Enforce "one concept per phase"; park ideas in `BACKLOG.md` |
| Optimizing blind | Tuning without numbers | No optimization before the Phase 3 benchmark exists |
| `unwrap()` creep | Panics under load | Ban `unwrap`/`expect` in request paths after Phase 1; lint for it |
| Cache incoherence | Stale redirects | Make invalidation explicit and tested in Phase 2 |

---

## 15. Immediate next steps

1. **Fix the filename** (`git mv analytical_writer.rs analytics_writer.rs`) so the tree matches this contract.
2. **Complete Phase 0 today** — `GET /health` + `clippy`/`rustfmt`/`justfile`.
3. **Sketch the `AppError` enum before writing handlers** — designing failure first pays off.
4. **Create `BACKLOG.md` and `NOTES.md`** — one for scope-creep parking, one for the per-phase learning journal where mastery actually consolidates.

---

*Keep this document in sync with the tree. When you add a directory, add a row to §6 and §8 first — the doc is the contract, and the phase matrix is what makes it a plan rather than just a map.*
