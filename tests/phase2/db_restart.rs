//! THE Phase 2 acceptance test: data survives a restart.
//!
//! Roadmap acceptance criterion: "kill & restart the process — links still
//! resolve." We simulate the restart with `TestApp::restart()`, which boots a
//! second server against the same database but with a COLD, EMPTY cache.
//!
//! That cold cache is what makes this a real test: if the link still resolves,
//! the value can only have come from Postgres.

use crate::common::TestApp;

#[derive(serde::Deserialize)]
struct CreateLinkResponse {
    code: String,
    #[allow(dead_code)]
    short_url: String,
}

#[tokio::test]
async fn links_survive_a_restart() {
    let app = TestApp::spawn().await;
    let target = "https://www.rust-lang.org/";

    // 1. Create a link on the original instance.
    let created: CreateLinkResponse =
        app.post_shorten(target).await.json().await.expect("shorten json");

    // 2. "Restart": new server, same DB, empty cache.
    let restarted = app.restart().await;

    // 3. It must still resolve — proof it came from Postgres.
    let resp = restarted.get_code(&created.code).await;
    assert!(resp.status().is_redirection(), "link did not survive restart: got {}", resp.status());
    assert_eq!(
        resp.headers().get(reqwest::header::LOCATION).and_then(|h| h.to_str().ok()),
        Some(target)
    );

    app.cleanup().await;
}

#[tokio::test]
async fn write_path_actually_persists_a_row() {
    let app = TestApp::spawn().await;

    assert_eq!(app.link_count().await, 0, "fresh DB should be empty");

    app.post_shorten("https://tokio.rs/").await;
    app.post_shorten("https://docs.rs/").await;

    assert_eq!(app.link_count().await, 2, "both links should be persisted");

    app.cleanup().await;
}

#[tokio::test]
async fn counter_resumes_after_restart_no_duplicate_key_error() {
    let app = TestApp::spawn().await;

    // Seed a few links so MAX(id) > 0.
    for i in 0..5 {
        let resp = app.post_shorten(&format!("https://example.com/{i}")).await;
        assert_eq!(resp.status(), reqwest::StatusCode::OK);
    }

    // A restarted instance must resume the counter past MAX(id). If it reset
    // to 1, this next insert would violate the UNIQUE constraint on `code`.
    let restarted = app.restart().await;
    let resp = restarted
        .client
        .post(format!("{}/shorten", restarted.address))
        .json(&serde_json::json!({ "url": "https://after-restart.example/" }))
        .send()
        .await
        .expect("request failed");

    assert_eq!(
        resp.status(),
        reqwest::StatusCode::OK,
        "restarted instance reissued an existing code (counter did not resume)"
    );

    assert_eq!(app.link_count().await, 6);

    app.cleanup().await;
}
