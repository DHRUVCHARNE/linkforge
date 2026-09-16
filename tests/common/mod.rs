//! Shared test harness for LinkForge integration & API tests (Phase 2).
//!
//! Per §11 of the architecture guide, integration tests are *black-box*: they
//! talk to a real, spawned axum server over TCP, exactly the way a client would.
//!
//! WHAT CHANGED IN PHASE 2
//! -----------------------
//! Phase 1's harness could build services from thin air (`ShortenerService::new()`).
//! Now the services require an `Arc<dyn LinkRepository>` and an `Arc<dyn Cache>`,
//! which means every test needs a **real Postgres database**.
//!
//! The central problem that creates: tests run in parallel, so they must not
//! see each other's rows. The solution here is **one throwaway database per
//! TestApp** — created from a template, migrated, and dropped on `Drop`.
//!
//! Key design choices:
//!   * Each `TestApp::spawn()` creates a uniquely-named database
//!     (`linkforge_test_<uuid>`), so tests are fully isolated and parallel-safe.
//!   * Migrations run against that fresh database, so the schema under test is
//!     exactly the schema in `migrations/`.
//!   * `spawn_sharing_db()` boots a SECOND server against the SAME database but
//!     with a COLD cache — this is how we simulate a process restart without
//!     actually killing a process.
//!   * The client does NOT auto-follow redirects, so tests can assert on the
//!     raw 3xx status + `Location` header.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use linkforge::domain::short_code::ShortCode;
use sqlx::postgres::{PgPool, PgPoolOptions};
use sqlx::{Connection, Executor, PgConnection};
use uuid::Uuid;

use linkforge::app::router;
use linkforge::app::state::AppState;
use linkforge::cache::{Cache, InMemoryCache};
use linkforge::repositories::LinkRepository;
use linkforge::repositories::link_repository::SqlxLinkRepository;
use linkforge::services::{redirect::RedirectService, shortener::ShortenerService};

/// Connection string for the Postgres *server* (no specific database).
/// Falls back to the local docker-compose default.
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
pub struct TestApp {
    /// e.g. "http://127.0.0.1:54123" — no trailing slash.
    pub address: String,
    /// Pre-configured client: does NOT auto-follow redirects.
    pub client: reqwest::Client,
    /// Direct pool access, so tests can assert on / mutate rows behind the
    /// service's back (essential for proving cache behaviour).
    pub pool: PgPool,
    /// Name of the throwaway database, kept for teardown.
    db_name: String,
    pub cache:Arc<dyn Cache>
}

impl TestApp {
    /// Boot a fresh server backed by a brand-new, migrated database.
    pub async fn spawn() -> Self {
    let db_name = format!("linkforge_test_{}", Uuid::new_v4().simple());
    let admin_url = base_url();

    // --- 1. Create an isolated database for this test ---
    let query = Box::leak(format!(r#"CREATE DATABASE "{db_name}""#).into_boxed_str()) as &str;
    let mut conn = PgConnection::connect(&admin_url)
        .await
        .expect("failed to connect to Postgres — is `just up` running?");
    conn.execute(query)
        .await
        .expect("failed to create test database");

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
    let (address, client, cache) = spawn_server(pool.clone()).await;

    Self { address, client, pool, db_name, cache }
}

    /// Boot a SECOND server against the same database with a **cold cache**.
    ///
    /// This is the restart simulation: the process-local cache is empty, so any
    /// link that still resolves must have come from Postgres. Proving M2
    /// ("it remembers") without actually killing a process.
    pub async fn restart(&self) -> RestartedApp {
        let (address, client,cache) = spawn_server(self.pool.clone()).await;
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

    /// Best-effort teardown. Call at the end of a test to drop the database.
    /// (Not automatic: `Drop` can't await, and leaking a few test DBs is
    /// harmless locally — `just db-clean` can sweep them.)
    pub async fn cleanup(self) {
        let admin_url = base_url();
        let query: &'static str = Box::leak(
            format!(r#"DROP DATABASE IF EXISTS "{}" WITH (FORCE)"#, self.db_name).into_boxed_str(),
        );
        self.pool.close().await;
        if let Ok(mut conn) = PgConnection::connect(&admin_url).await {
            let _ = conn.execute(query).await;
        }
    }
    pub async fn invalidate_cache(&self, code: &str) {
        let c = ShortCode::parse(code).expect("valid code");
        self.cache.invalidate(&c).await;
    }
}

/// A second server instance sharing a database — see `TestApp::restart`.
pub struct RestartedApp {
    pub address: String,
    pub client: reqwest::Client,
}

impl RestartedApp {
    pub async fn get_code(&self, code: &str) -> reqwest::Response {
        self.client
            .get(format!("{}/{}", self.address, code))
            .send()
            .await
            .expect("request to /:code failed")
    }
}

/// Wire up services over a pool, bind an ephemeral port, and serve.
///
/// NOTE: this mirrors `AppState::build` but takes a pool directly, so tests
/// never depend on config/env loading. If your `AppState` gains fields, add
/// them here too.
async fn spawn_server(pool: PgPool) -> (String, reqwest::Client,Arc<dyn Cache>) {
    // Resume the counter past the highest existing id, exactly as production
    // does — otherwise a restarted instance reissues codes that already exist.
    let start_id: i64 = sqlx::query_scalar("SELECT COALESCE(MAX(id), 0) FROM links")
        .fetch_one(&pool)
        .await
        .expect("failed to read max id");

    let links: Arc<dyn LinkRepository> = Arc::new(SqlxLinkRepository::new(pool));
    let cache: Arc<dyn Cache> = Arc::new(InMemoryCache::new(Duration::from_secs(30)));

    let shortener =
        Arc::new(ShortenerService::new(links.clone(), cache.clone(), start_id as u64 + 1));
    let redirect = Arc::new(RedirectService::new(links.clone(), cache.clone()));

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("failed to bind ephemeral test port");
    let addr: SocketAddr = listener.local_addr().expect("listener has no local addr");

    let state =
        AppState { shortener, redirect, base_url: Arc::from(format!("http://{addr}").as_str()),cache:cache.clone(),links:links.clone(),debug_routes:true };

    let app = router::create(state);
    tokio::spawn(async move {
        axum::serve(listener, app).await.expect("test server crashed");
    });

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("failed to build reqwest client");

    (format!("http://{addr}"), client,Arc::clone(&cache))
}
