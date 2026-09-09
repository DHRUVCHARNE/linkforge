//! Whole-crate integration: exercise the shorten -> redirect loop end to end,
//! and confirm the same code resolves consistently across repeated reads
//! (read-heavy path stability — the reason we chose RwLock over Mutex).

use crate::common::TestApp;

#[derive(serde::Deserialize)]
struct CreateLinkResponse {
    code: String,
    #[allow(dead_code)]
    short_url: String,
}

#[tokio::test]
async fn same_code_resolves_repeatedly() {
    let app = TestApp::spawn().await;
    let target = "https://doc.rust-lang.org/book/";

    let created: CreateLinkResponse = app
        .post_shorten(target)
        .await
        .json()
        .await
        .expect("shorten json");

    // Hammer the read path a few times; every read must resolve identically.
    for _ in 0..25 {
        let resp = app.get_code(&created.code).await;
        assert!(resp.status().is_redirection());
        assert_eq!(
            resp.headers()
                .get(reqwest::header::LOCATION)
                .and_then(|h| h.to_str().ok()),
            Some(target)
        );
    }
}

#[tokio::test]
async fn distinct_urls_get_distinct_codes_and_resolve_independently() {
    let app = TestApp::spawn().await;

    let first: CreateLinkResponse = app
        .post_shorten("https://a.example/")
        .await
        .json()
        .await
        .expect("json a");
    let second: CreateLinkResponse = app
        .post_shorten("https://b.example/")
        .await
        .json()
        .await
        .expect("json b");

    assert_ne!(first.code, second.code);

    let r1 = app.get_code(&first.code).await;
    let r2 = app.get_code(&second.code).await;

    assert_eq!(
        r1.headers()
            .get(reqwest::header::LOCATION)
            .and_then(|h| h.to_str().ok()),
        Some("https://a.example/")
    );
    assert_eq!(
        r2.headers()
            .get(reqwest::header::LOCATION)
            .and_then(|h| h.to_str().ok()),
        Some("https://b.example/")
    );
}
