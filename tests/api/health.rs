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

use reqwest::StatusCode;

async fn get(app: &TestApp, path: &str) -> reqwest::Response {
    app.client
        .get(format!("{}{}", app.address, path))
        .send()
        .await
        .expect("request failed")
}

#[tokio::test]
async fn live_returns_200() {
    let app = TestApp::spawn().await;
    assert_eq!(get(&app, "/health/live").await.status(), StatusCode::OK);
    app.cleanup().await;
}

#[tokio::test]
async fn ready_returns_200_when_database_is_up() {
    let app = TestApp::spawn().await;
    let resp = get(&app, "/health/ready").await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(resp.text().await.unwrap().contains("ready"));
    app.cleanup().await;
}

#[tokio::test]
async fn ready_returns_503_while_draining_but_live_stays_200() {
    let app = TestApp::spawn().await;
    app.readiness.start_draining();

    let ready = get(&app, "/health/ready").await;
    assert_eq!(ready.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert!(ready.text().await.unwrap().contains("draining"));

    // Draining isn't a liveness failure: the process must not be restarted.
    assert_eq!(get(&app, "/health/live").await.status(), StatusCode::OK);

    // And it still serves normal traffic during the delay window.
    let code: serde_json::Value = app.post_shorten("https://example.com").await.json().await.unwrap();
    let code = code["code"].as_str().unwrap();
    assert!(app.get_code(code).await.status().is_redirection());

    app.cleanup().await;
}

#[tokio::test]
async fn ready_returns_503_when_database_is_unreachable() {
    let app = TestApp::spawn().await;
    app.pool.close().await; // the server shares this pool

    let ready = get(&app, "/health/ready").await;
    assert_eq!(ready.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert!(ready.text().await.unwrap().contains("database_unavailable"));

    // Liveness doesn't depend on the database.
    assert_eq!(get(&app, "/health/live").await.status(), StatusCode::OK);

    app.cleanup().await;
}

#[tokio::test]
async fn probes_bypass_the_rate_limiter() {
    let app = TestApp::spawn_with_rate_limit(2, 60).await;

    for _ in 0..10 {
        assert_eq!(get(&app, "/health/ready").await.status(), StatusCode::OK);
    }

    // Prove the limiter is active for normal routes. Otherwise the loop
    // above would pass even with no limiter at all.
    let mut statuses = Vec::new();
    for _ in 0..5 {
        statuses.push(app.get_code("aZ09xY").await.status().as_u16());
    }
    assert!(statuses.contains(&429), "limiter never engaged: {statuses:?}");

    app.cleanup().await;
}

