//! Contract tests: GET /:code
//!
//! Asserts the hot read-path contract: a known code returns a redirect
//! (3xx) whose `Location` header points at the original URL, and an unknown
//! code returns `404` (proving `AppError::NotFound` maps correctly).

use crate::common::TestApp;

#[derive(serde::Deserialize)]
struct CreateLinkResponse {
    code: String,
    #[allow(dead_code)]
    short_url: String,
}

#[tokio::test]
async fn known_code_redirects_to_target() {
    let app = TestApp::spawn().await;
    let target = "https://www.rust-lang.org/";

    // create a link first
    let created: CreateLinkResponse =
        app.post_shorten(target).await.json().await.expect("shorten response json");

    // follow it (client does NOT auto-follow — we inspect the redirect itself)
    let resp = app.get_code(&created.code).await;

    assert!(resp.status().is_redirection(), "expected a 3xx redirect, got {}", resp.status());

    let location = resp
        .headers()
        .get(reqwest::header::LOCATION)
        .expect("redirect must carry a Location header")
        .to_str()
        .expect("Location header was not valid UTF-8");

    assert_eq!(location, target, "Location must equal the original URL");
}

#[tokio::test]
async fn unknown_code_returns_404() {
    let app = TestApp::spawn().await;

    let resp = app.get_code("doesnotexist").await;
    assert_eq!(resp.status(), reqwest::StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn full_round_trip_shorten_then_redirect() {
    let app = TestApp::spawn().await;
    let target = "https://tokio.rs/";

    let created: CreateLinkResponse =
        app.post_shorten(target).await.json().await.expect("shorten json");

    let redirect = app.get_code(&created.code).await;
    assert!(redirect.status().is_redirection());
    assert_eq!(
        redirect.headers().get(reqwest::header::LOCATION).and_then(|h| h.to_str().ok()),
        Some(target)
    );
}
