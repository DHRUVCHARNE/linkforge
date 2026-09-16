// tests/integration/cache_coherence.rs
use crate::common::TestApp;
use linkforge::domain::short_code::ShortCode;
use linkforge::utils::base62;

#[derive(serde::Deserialize)]
struct CreateLinkResponse {
    code: String,
    #[allow(dead_code)]
    short_url: String,
}
#[tokio::test]
async fn invalidate_forces_a_reread_from_the_database() {
    let app = TestApp::spawn().await;
    let target = "https://www.rust-lang.org/";

    let created: CreateLinkResponse = app.post_shorten(target).await.json().await.expect("json");

    // Delete the row behind the service's back. The cache still serves it.
    app.delete_link_row(&created.code).await;
    assert!(
        app.get_code(&created.code).await.status().is_redirection(),
        "cache should still be serving the stale value"
    );

    // Invalidate, then the same instance must fall through to the DB and 404.
    app.invalidate_cache(&created.code).await;
    assert_eq!(
        app.get_code(&created.code).await.status(),
        reqwest::StatusCode::NOT_FOUND,
        "invalidate() did not force a re-read"
    );

    app.cleanup().await;
}

#[tokio::test]
async fn creating_a_code_clears_its_negative_entry() {
    let app = TestApp::spawn().await;

    // On a fresh DB the counter starts at 1, so the next issued code is
    // base62(1). Poison the cache with a negative entry for exactly that code.
    let next_code = base62::encode(1);
    let poisoned = ShortCode::parse(&next_code).expect("valid code");
    app.cache.set_missing(poisoned).await;

    // Create a link — it should land on that code and OVERWRITE the negative
    // entry via the write-through in ShortenerService::create.
    let created: CreateLinkResponse =
        app.post_shorten("https://www.rust-lang.org/").await.json().await.expect("json");

    assert_eq!(created.code, next_code, "test assumption broken: counter did not start at 1");

    // If the negative entry survived, this would 404.
    let resp = app.get_code(&created.code).await;
    assert!(
        resp.status().is_redirection(),
        "stale negative cache entry was not cleared by create() — got {}",
        resp.status()
    );

    app.cleanup().await;
}
