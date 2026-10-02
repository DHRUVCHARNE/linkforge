//! Phase 4 integration tests — the click pipeline.
//!
//! Place at tests/integration/analytics.rs and declare it in
//! tests/integration.rs:
//!
//!     #[path = "integration/analytics.rs"]
//!     mod analytics;
//!
//! These complement the shell harness: the harness proves behaviour under
//! real load; these prove exact semantics where timing is controllable.
//!
//! Never assert on a fixed sleep. The writer flushes asynchronously, so every
//! count assertion polls with a timeout (see `wait_for_clicks`).

use std::time::Duration;

use crate::common::TestApp;

#[derive(serde::Deserialize)]
struct CreateLinkResponse {
    code: String,
    #[allow(dead_code)]
    short_url: String,
}

#[derive(serde::Deserialize, Debug)]
struct StatsResponse {
    code: String,
    clicks: i64,
}

async fn create(app: &TestApp, url: &str) -> String {
    let r: CreateLinkResponse = app.post_shorten(url).await.json().await.expect("json");
    r.code
}

async fn stats(app: &TestApp, code: &str) -> reqwest::Response {
    app.client
        .get(format!("{}/{}/stats", app.address, code))
        .send()
        .await
        .expect("stats request failed")
}

async fn db_clicks(app: &TestApp, code: &str) -> i64 {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM clicks WHERE code = $1")
        .bind(code)
        .fetch_one(&app.pool)
        .await
        .expect("count query failed")
}

/// Poll the database until `expected` clicks exist, or panic after a timeout.
async fn wait_for_clicks(app: &TestApp, code: &str, expected: i64) -> i64 {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let n = db_clicks(app, code).await;
        if n >= expected {
            return n;
        }
        if tokio::time::Instant::now() >= deadline {
            panic!("clicks for {code} reached {n}, never {expected}");
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

// ---------------------------------------------------------------------------
// Accounting
// ---------------------------------------------------------------------------

#[tokio::test]
async fn each_redirect_records_exactly_one_click() {
    let app = TestApp::spawn().await;
    let code = create(&app, "https://example.com/one").await;

    for _ in 0..25 {
        assert!(app.get_code(&code).await.status().is_redirection());
    }

    assert_eq!(wait_for_clicks(&app, &code, 25).await, 25);

    // Give the writer a further chance to over-write; the count must not grow.
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(db_clicks(&app, &code).await, 25, "clicks overcounted");

    app.cleanup().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_redirects_lose_no_clicks_below_capacity() {
    let app = TestApp::spawn().await;
    let code = create(&app, "https://example.com/concurrent").await;
    const N: usize = 300; // well below the test channel capacity

    let mut handles = Vec::with_capacity(N);
    for _ in 0..N {
        let client = app.client.clone();
        let url = format!("{}/{}", app.address, code);
        handles.push(tokio::spawn(async move {
            client.get(url).send().await.expect("request").status()
        }));
    }
    for h in handles {
        assert!(h.await.expect("task").is_redirection());
    }

    assert_eq!(wait_for_clicks(&app, &code, N as i64).await, N as i64);
    app.cleanup().await;
}

#[tokio::test]
async fn clicks_are_recorded_on_the_cold_path_too() {
    // The leader/waiter (single-flight) paths return through different
    // branches than the cache-hit path. Each must record a click.
    let app = TestApp::spawn().await;
    let code = create(&app, "https://example.com/cold").await;

    app.invalidate_cache(&code).await; // force a cache miss
    assert!(app.get_code(&code).await.status().is_redirection());

    assert_eq!(wait_for_clicks(&app, &code, 1).await, 1);
    app.cleanup().await;
}

#[tokio::test]
async fn not_found_records_no_click() {
    let app = TestApp::spawn().await;

    for _ in 0..10 {
        assert_eq!(app.get_code("zzNope12").await.status(), reqwest::StatusCode::NOT_FOUND);
    }
    tokio::time::sleep(Duration::from_millis(200)).await;

    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM clicks")
        .fetch_one(&app.pool)
        .await
        .expect("count");
    assert_eq!(total, 0, "404s must not produce analytics rows");

    app.cleanup().await;
}

#[tokio::test]
async fn ip_is_stored_hashed_never_raw() {
    let app = TestApp::spawn().await;
    let code = create(&app, "https://example.com/privacy").await;
    app.get_code(&code).await;
    wait_for_clicks(&app, &code, 1).await;

    let hash: Option<String> =
        sqlx::query_scalar("SELECT ip_hash FROM clicks WHERE code = $1 LIMIT 1")
            .bind(&code)
            .fetch_one(&app.pool)
            .await
            .expect("select");

    let hash = hash.expect("ip_hash should be populated when ConnectInfo is present");
    assert!(!hash.contains("127.0.0.1"), "raw IP stored: {hash}");
    assert!(hash.chars().all(|c| c.is_ascii_hexdigit()), "not a hex digest: {hash}");

    app.cleanup().await;
}

// ---------------------------------------------------------------------------
// Stats endpoint contract
// ---------------------------------------------------------------------------

#[tokio::test]
async fn stats_reports_zero_for_existing_unclicked_link() {
    let app = TestApp::spawn().await;
    let code = create(&app, "https://example.com/zero").await;

    let resp = stats(&app, &code).await;
    assert_eq!(resp.status(), reqwest::StatusCode::OK);
    let body: StatsResponse = resp.json().await.expect("json");
    assert_eq!(body.code, code);
    assert_eq!(body.clicks, 0);

    app.cleanup().await;
}

#[tokio::test]
async fn stats_matches_recorded_clicks() {
    let app = TestApp::spawn().await;
    let code = create(&app, "https://example.com/match").await;

    for _ in 0..7 {
        app.get_code(&code).await;
    }
    wait_for_clicks(&app, &code, 7).await;

    let body: StatsResponse = stats(&app, &code).await.json().await.expect("json");
    assert_eq!(body.clicks, 7);

    app.cleanup().await;
}

#[tokio::test]
async fn stats_for_unknown_code_is_404_not_zero() {
    let app = TestApp::spawn().await;
    assert_eq!(stats(&app, "aZ09xY").await.status(), reqwest::StatusCode::NOT_FOUND);
    app.cleanup().await;
}

#[tokio::test]
async fn reading_stats_does_not_record_clicks() {
    let app = TestApp::spawn().await;
    let code = create(&app, "https://example.com/readonly").await;

    for _ in 0..20 {
        stats(&app, &code).await;
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(db_clicks(&app, &code).await, 0);

    app.cleanup().await;
}
