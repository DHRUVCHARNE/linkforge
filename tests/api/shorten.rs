//! Contract tests: POST /shorten
//!
//! Asserts the write-path HTTP contract: valid URLs produce a JSON body with a
//! non-empty `code`, and malformed input is rejected at the edge with `400`
//! (proving `AppError::InvalidUrl` maps correctly through `IntoResponse`).

use crate::common::TestApp;

#[derive(serde::Deserialize)]
struct CreateLinkResponse {
    code: String,
    short_url: String,
}

#[tokio::test]
async fn shorten_valid_url_returns_200_with_code() {
    let app = TestApp::spawn().await;

    let resp = app.post_shorten("https://www.rust-lang.org").await;
    assert_eq!(resp.status(), reqwest::StatusCode::OK);

    let body: CreateLinkResponse = resp.json().await.expect("body was not valid JSON");
    assert!(!body.code.is_empty(), "code must not be empty");
    assert!(
        body.short_url.ends_with(&body.code),
        "short_url should end with the generated code"
    );
}

#[tokio::test]
async fn shorten_rejects_non_http_scheme() {
    let app = TestApp::spawn().await;

    let resp = app.post_shorten("ftp://not-allowed.example").await;
    assert_eq!(
        resp.status(),
        reqwest::StatusCode::BAD_REQUEST,
        "non-http(s) URLs must be rejected as 400"
    );
}

#[tokio::test]
async fn shorten_rejects_garbage_input() {
    let app = TestApp::spawn().await;

    let resp = app.post_shorten("definitely not a url").await;
    assert_eq!(resp.status(), reqwest::StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn two_shortens_produce_distinct_codes() {
    let app = TestApp::spawn().await;

    let a: CreateLinkResponse = app
        .post_shorten("https://example.com/a")
        .await
        .json()
        .await
        .expect("json a");
    let b: CreateLinkResponse = app
        .post_shorten("https://example.com/b")
        .await
        .json()
        .await
        .expect("json b");

    assert_ne!(a.code, b.code, "sequential shortens must yield unique codes");
}
