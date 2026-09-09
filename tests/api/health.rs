//! Contract test: GET /health (Phase 0 endpoint, still part of the surface).

use crate::common::TestApp;

#[tokio::test]
async fn health_returns_200() {
    let app = TestApp::spawn().await;

    let resp = app
        .client
        .get(format!("{}/health", app.address))
        .send()
        .await
        .expect("health request failed");

    assert_eq!(resp.status(), reqwest::StatusCode::OK);
}
