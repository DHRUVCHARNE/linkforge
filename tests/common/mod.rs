//! Shared test harness for LinkForge integration & API tests (Phase 3).
//!
//! Per §11 of the architecture guide, integration tests are *black-box*: they
//! talk to a real, spawned axum server over TCP, exactly the way a client would.
//!
//! WHAT CHANGED IN PHASE 3
//! -----------------------
//! The router now carries a rate limiter. Every test client connects from
//! 127.0.0.1, so all requests share ONE token bucket — a test firing 200
//! concurrent requests will throttle itself and fail with 429s that have
//! nothing to do with what it was testing.
//!
//! The harness therefore boots with an effectively unlimited bucket by
//! default, and exposes `spawn_with_rate_limit()` so the 429 test can opt
//! into a deliberately tight one. The limit becomes a PARAMETER OF THE TEST
//! rather than a global that silently breaks unrelated suites.
//!
//! Key design choices:
//!   * One throwaway database per `TestApp` (`linkforge_test_<uuid>`), so
//!     tests are isolated and parallel-safe.
//!   * Migrations run against that fresh database, so the schema under test
//!     is exactly the schema in `migrations/`.
//!   * `restart()` boots a SECOND server on the SAME database with a COLD
//!     cache — a process restart simulated without killing a process.
//!   * The client does NOT auto-follow redirects, so tests can assert on the
//!     raw 3xx status + `Location` header.
//!   * `into_make_service_with_connect_info` is required, or the rate limiter
//!     sees every peer as 0.0.0.0 and buckets them together.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use sqlx::postgres::{PgPool, PgPoolOptions};
use sqlx::{Connection, Executor, PgConnection};
use uuid::Uuid;

use linkforge::app::router;
use linkforge::app::state::AppState;
use linkforge::cache::{Cache, InMemoryCache};
use linkforge::config::RateLimitConfig;
use linkforge::domain::short_code::ShortCode;
use linkforge::repositories::LinkRepository;
use linkforge::repositories::link_repository::SqlxLinkRepository;
use linkforge::services::{redirect::RedirectService, shortener::ShortenerService};

/// Negative-cache TTL used by the harness. Short enough that a test can wait
/// it out if it needs to, long enough not to expire mid-assertion.
const TEST_NEGATIVE_TTL: Duration = Duration::from_secs(30);

/// Effectively unlimited. Tests exercise handlers, not the limiter.
fn permissive_rate_limit() -> RateLimitConfig {
    RateLimitConfig { requests: 1_000_000, window_secs: 1 }
}

/// Connection string for the Postgres *server*. Falls back to the local
/// docker-compose default.
fn base_url() -> String {
    std::env::var("TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap_or_else(|_| "postgres://linkforge:linkforge@localhost:5432/linkforge".into())
}

/// Rewrite a connection string to point at a different database name.
fn with_db_name(url: &str, db: &str) -> String {
    match url.rfind('/') {
        Some(idx) => format!("{}/{}", &url[..idx], db),
        None => format!("{url}/{db}"),
    }
}

/// A running LinkForge instance, its isolated database, and a client.
#[allow(dead_code)]
pub struct TestApp {
    /// e.g. "http://127.0.0.1:54123" — no trailing slash.
    pub address: String,
    /// Pre-configured client: does NOT auto-follow redirects.
    pub client: reqwest::Client,
    /// Direct pool access, so tests can assert on / mutate rows behind the
    /// service's back (essential for proving cache behaviour).
    pub pool: PgPool,
    /// The SAME `Arc` the services hold — invalidation here affects the server.
    pub cache: Arc<dyn Cache>,
    /// Name of the throwaway database, kept for teardown.
    db_name: String,
}

#[allow(dead_code)]
impl TestApp {
    /// Boot a fresh server with an effectively unlimited rate limit.
    pub async fn spawn() -> Self {
        Self::spawn_with_config(permissive_rate_limit()).await
    }

    /// Boot with a deliberately tight bucket — for 429 / retry-after tests.
    ///
    /// Example: `TestApp::spawn_with_rate_limit(5, 60)` allows 5 requests
    /// before rejecting.
    pub async fn spawn_with_rate_limit(requests: u32, window_secs: u64) -> Self {
        Self::spawn_with_config(RateLimitConfig { requests, window_secs }).await
    }

    async fn spawn_with_config(rate_limit: RateLimitConfig) -> Self {
        let db_name = format!("linkforge_test_{}", Uuid::new_v4().simple());
        let admin_url = base_url();
        let mut conn = PgConnection::connect(&admin_url).await.expect("failed to connect");

        // --- 1. Create an isolated database for this test ---
        //
        // NOTE: sqlx 0.9's Executor requires a 'static query string, so we leak.
        // A few bytes per test is harmless in a test binary.
        // Identifiers cannot be bind parameters in Postgres, so raw interpolation
        // is unavoidable here — safe because db_name is a UUID we generated.
        let create_sql: &'static str =
            Box::leak(format!(r#"CREATE DATABASE "{db_name}""#).into_boxed_str());
        conn.execute(create_sql).await.expect("failed to create test database");

        let db_url = with_db_name(&admin_url, &db_name);

        // --- 2. Connect + migrate ---
        let pool = PgPoolOptions::new()
            .max_connections(5)
            .connect(&db_url)
            .await
            .expect("failed to connect to test database");

        sqlx::migrate!("./migrations")
            .run(&pool)
            .await
            .expect("failed to run migrations on test database");

        // --- 3. Boot the server; take ITS cache so invalidation targets the
        //        same Arc the services are using.
        let (address, client, cache) = spawn_server(pool.clone(), rate_limit).await;

        Self { address, client, pool, cache, db_name }
    }

    /// Boot a SECOND server against the same database with a **cold cache**.
    ///
    /// The restart simulation: the process-local cache is empty, so any link
    /// that still resolves must have come from Postgres. Always permissive —
    /// a restart test should never inherit a tight bucket.
    pub async fn restart(&self) -> RestartedApp {
        let (address, client, _) = spawn_server(self.pool.clone(), permissive_rate_limit()).await;
        RestartedApp { address, client }
    }

    /// POST /shorten with a JSON `{ "url": ... }` body.
    pub async fn post_shorten(&self, url: &str) -> reqwest::Response {
        self.client
            .post(format!("{}/shorten", self.address))
            .json(&serde_json::json!({ "url": url }))
            .send()
            .await
            .expect("request to /shorten failed")
    }

    /// GET /:code without following the redirect.
    pub async fn get_code(&self, code: &str) -> reqwest::Response {
        self.client
            .get(format!("{}/{}", self.address, code))
            .send()
            .await
            .expect("request to /:code failed")
    }

    /// Count rows in `links` — lets tests assert persistence directly.
    pub async fn link_count(&self) -> i64 {
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM links")
            .fetch_one(&self.pool)
            .await
            .expect("count query failed")
    }

    /// Delete a row *behind the service's back*. Used to prove that a
    /// subsequent successful resolve was served from cache, not the DB.
    pub async fn delete_link_row(&self, code: &str) {
        sqlx::query("DELETE FROM links WHERE code = $1")
            .bind(code)
            .execute(&self.pool)
            .await
            .expect("delete failed");
    }

    /// Evict a code from the server's cache.
    pub async fn invalidate_cache(&self, code: &str) {
        // Guards the wiring: if this Arc were a separate allocation from the
        // services', invalidation would be a silent no-op and cache tests
        // would pass vacuously.
        debug_assert!(
            Arc::strong_count(&self.cache) >= 3,
            "TestApp.cache is not the server's cache — check spawn_server wiring"
        );
        let c = ShortCode::parse(code).expect("valid code");
        self.cache.invalidate(&c).await;
    }

    /// Best-effort teardown. Call at the end of a test to drop the database.
    /// (Not automatic: `Drop` can't await, and leaking a few test DBs is
    /// harmless locally — `just db-clean` can sweep them.)
    pub async fn cleanup(self) {
        let admin_url = base_url();
        let drop_sql: &'static str = Box::leak(
            format!(r#"DROP DATABASE IF EXISTS "{}" WITH (FORCE)"#, self.db_name).into_boxed_str(),
        );
        self.pool.close().await;
        if let Ok(mut conn) = PgConnection::connect(&admin_url).await {
            let _ = conn.execute(drop_sql).await;
        }
    }
}

/// A second server instance sharing a database — see `TestApp::restart`.
#[allow(dead_code)]
pub struct RestartedApp {
    pub address: String,
    pub client: reqwest::Client,
}

#[allow(dead_code)]
impl RestartedApp {
    pub async fn get_code(&self, code: &str) -> reqwest::Response {
        self.client
            .get(format!("{}/{}", self.address, code))
            .send()
            .await
            .expect("request to /:code failed")
    }

    pub async fn post_shorten(&self, url: &str) -> reqwest::Response {
        self.client
            .post(format!("{}/shorten", self.address))
            .json(&serde_json::json!({ "url": url }))
            .send()
            .await
            .expect("request to /shorten failed")
    }
}

/// Wire up services over a pool, bind an ephemeral port, and serve.
///
/// Mirrors `AppState::build` but takes a pool and rate limit directly, so
/// tests never depend on config/env loading. If `AppState` gains fields, add
/// them here too.
async fn spawn_server(
    pool: PgPool,
    rate_limit: RateLimitConfig,
) -> (String, reqwest::Client, Arc<dyn Cache>) {
    // Resume the counter past the highest existing id, exactly as production
    // does — otherwise a restarted instance reissues codes that already exist.
    let start_id: i64 = sqlx::query_scalar("SELECT COALESCE(MAX(id), 0) FROM links")
        .fetch_one(&pool)
        .await
        .expect("failed to read max id");

    let links: Arc<dyn LinkRepository> = Arc::new(SqlxLinkRepository::new(pool));
    let cache: Arc<dyn Cache> = Arc::new(InMemoryCache::new(TEST_NEGATIVE_TTL));

    let shortener =
        Arc::new(ShortenerService::new(links.clone(), cache.clone(), start_id as u64 + 1));
    let redirect = Arc::new(RedirectService::new(links.clone(), cache.clone()));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("failed to bind ephemeral test port");
    let addr: SocketAddr = listener.local_addr().expect("listener has no local addr");

    let state = AppState {
        shortener,
        redirect,
        base_url: Arc::from(format!("http://{addr}").as_str()),
        cache: cache.clone(),
        links,
        debug_routes: true,
        rate_limit,
    };

    let app = router::create(state);

    tokio::spawn(async move {
        // ConnectInfo is REQUIRED: without it the rate limiter cannot read a
        // peer address, falls back to 0.0.0.0, and buckets every client
        // together — a limiter that appears to work while being wrong.
        axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
            .await
            .expect("test server crashed");
    });

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("failed to build reqwest client");

    (format!("http://{addr}"), client, cache)
}
