//! Shared test harness for LinkForge integration & API tests.
//!
//! Per §11 of the architecture guide, integration tests are *black-box*:
//! they talk to a **real, spawned axum server** over TCP, exactly the way a
//! client would. This module owns the one piece of machinery every test
//! needs — `TestApp::spawn()` — so no test file repeats server bootstrapping.
//!
//! Key design choices:
//!   * We bind to `127.0.0.1:0` — the OS hands us a *free* random port. This
//!     lets tests run in parallel without port collisions.
//!   * The server runs on a detached `tokio::spawn`; it dies when the test
//!     process exits (no manual teardown needed for Phase 1's in-memory state).
//!   * We hand back a `reqwest::Client` configured to **NOT** follow redirects,
//!     so tests can assert on the raw `302`/`308` + `Location` header.

use std::net::SocketAddr;
use std::sync::Arc;

use linkforge::app::state::AppState;
use linkforge::app::router;
use linkforge::services::{redirect::RedirectService, shortener::ShortenerService};

/// A running LinkForge instance plus a client wired to talk to it.
pub struct TestApp {
    /// e.g. "http://127.0.0.1:54123" — no trailing slash.
    pub address: String,
    /// Pre-configured client: does NOT auto-follow redirects.
    pub client: reqwest::Client,
}

impl TestApp {
    /// Boot a fresh server on a random port and return a handle to it.
    pub async fn spawn() -> Self {
        // --- 1. Build application state (Phase 1: pure in-memory, no config/db) ---
        //
        // NOTE: adjust these three lines if your AppState constructor differs.
        // If you use `AppState::build(&settings)`, swap this block for that call
        // with a test Settings. We construct services directly here to keep the
        // harness free of any config/env coupling.
        let shortener = Arc::new(ShortenerService::new());
        let redirect = Arc::new(RedirectService::new(shortener.clone()));
        let state = AppState {
            shortener,
            redirect,
            base_url: Arc::from("http://127.0.0.1"), // value irrelevant to these tests
        };

        // --- 2. Bind to an OS-assigned free port ---
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("failed to bind ephemeral test port");
        let addr: SocketAddr = listener.local_addr().expect("listener has no local addr");

        // --- 3. Assemble the real router and serve it in the background ---
        let app = router::create(state);
        tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("test server crashed");
        });

        // --- 4. A client that surfaces redirects instead of chasing them ---
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("failed to build reqwest client");

        Self {
            address: format!("http://{addr}"),
            client,
        }
    }

    /// Convenience: POST /shorten with a JSON `{ "url": ... }` body.
    pub async fn post_shorten(&self, url: &str) -> reqwest::Response {
        self.client
            .post(format!("{}/shorten", self.address))
            .json(&serde_json::json!({ "url": url }))
            .send()
            .await
            .expect("request to /shorten failed")
    }

    /// Convenience: GET /:code without following the redirect.
    pub async fn get_code(&self, code: &str) -> reqwest::Response {
        self.client
            .get(format!("{}/{}", self.address, code))
            .send()
            .await
            .expect("request to /:code failed")
    }
}
