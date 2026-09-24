use crate::common::TestApp;

#[tokio::test]
async fn exceeding_the_bucket_returns_429() {
    let app = TestApp::spawn_with_rate_limit(5, 60).await;

    let mut statuses = Vec::new();
    for _ in 0..10 {
        statuses.push(app.get_code("nope").await.status().as_u16());
    }

    assert!(statuses.contains(&429), "no request was rate-limited; statuses: {statuses:?}");

    app.cleanup().await;
}
