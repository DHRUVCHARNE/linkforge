//! Cache-coherence tests — the risk the guide names explicitly for Phase 2
//! ("stale redirects"; make invalidation explicit and tested).
//!
//! These tests prove the read-through cache is REAL, not just a pass-through
//! to Postgres. The technique: mutate the database *behind the service's back*
//! and observe whether the service still serves the old value.
//!
//! That divergence is not a bug here — it is the definition of a cache. The
//! point is to make the behaviour deliberate, observed, and documented.

use crate::common::TestApp;

#[derive(serde::Deserialize)]
struct CreateLinkResponse {
    code: String,
    #[allow(dead_code)]
    short_url: String,
}

#[tokio::test]
async fn write_path_warms_the_cache() {
    let app = TestApp::spawn().await;
    let target = "https://www.rust-lang.org/";

    let created: CreateLinkResponse =
        app.post_shorten(target).await.json().await.expect("shorten json");

    // Delete the row directly. If the write path warmed the cache, the service
    // can still resolve it without touching Postgres.
    app.delete_link_row(&created.code).await;

    let resp = app.get_code(&created.code).await;
    assert!(
        resp.status().is_redirection(),
        "expected a cache hit after the DB row was removed — \
         the write path did not warm the cache"
    );

    app.cleanup().await;
}

#[tokio::test]
async fn read_path_backfills_the_cache_on_miss() {
    let app = TestApp::spawn().await;
    let target = "https://tokio.rs/";

    let created: CreateLinkResponse =
        app.post_shorten(target).await.json().await.expect("shorten json");

    // Restart => cold cache. First read must MISS and hit Postgres.
    let restarted = app.restart().await;

    let first = restarted.get_code(&created.code).await;
    assert!(first.status().is_redirection(), "cold read should hit the DB");

    // Now remove the row. If the first read backfilled the cache, the second
    // read still succeeds despite the DB no longer holding the link.
    app.delete_link_row(&created.code).await;

    let second = restarted.get_code(&created.code).await;
    assert!(
        second.status().is_redirection(),
        "expected a cache hit — the read path did not backfill on miss"
    );

    app.cleanup().await;
}

#[tokio::test]
async fn cold_instance_does_not_see_a_deleted_link() {
    let app = TestApp::spawn().await;

    let created: CreateLinkResponse =
        app.post_shorten("https://docs.rs/").await.json().await.expect("shorten json");

    app.delete_link_row(&created.code).await;

    // A COLD instance has nothing cached, so it must 404 — proving the earlier
    // successful resolves really were cache hits and not DB reads.
    let restarted = app.restart().await;
    let resp = restarted.get_code(&created.code).await;

    assert_eq!(
        resp.status(),
        reqwest::StatusCode::NOT_FOUND,
        "a cold instance should not resolve a link that no longer exists in the DB"
    );

    app.cleanup().await;
}

#[tokio::test]
async fn unknown_code_is_404_not_a_cache_error() {
    let app = TestApp::spawn().await;

    let resp = app.get_code("doesnotexist").await;
    assert_eq!(resp.status(), reqwest::StatusCode::NOT_FOUND);

    app.cleanup().await;
}
