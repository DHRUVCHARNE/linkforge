//! THE Phase 1 acceptance test: concurrent POSTs never produce a duplicate code.
//!
//! This is the hard requirement from the roadmap (§7, Phase 1 Acceptance).
//! It is the empirical proof that the `AtomicU64::fetch_add` counter is a true
//! anti-duplication guarantee: no matter how many requests race, every code is
//! unique.
//!
//! Strategy: fire N concurrent /shorten requests through the real server, then
//! assert the set of returned codes has exactly N distinct members.

use std::collections::HashSet;

use crate::common::TestApp;

#[derive(serde::Deserialize)]
struct CreateLinkResponse {
    code: String,
    #[allow(dead_code)]
    short_url: String,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_shortens_never_collide() {
    let app = TestApp::spawn().await;
    const N: usize = 500;

    // Launch N concurrent shorten requests.
    let mut handles = Vec::with_capacity(N);
    for i in 0..N {
        let addr = app.address.clone();
        let client = app.client.clone();
        handles.push(tokio::spawn(async move {
            let resp = client
                .post(format!("{addr}/shorten"))
                .json(&serde_json::json!({ "url": format!("https://example.com/{i}") }))
                .send()
                .await
                .expect("request failed");
            assert_eq!(resp.status(), reqwest::StatusCode::OK);
            let body: CreateLinkResponse = resp.json().await.expect("json");
            body.code
        }));
    }

    // Collect all generated codes.
    let mut codes = HashSet::with_capacity(N);
    for h in handles {
        let code = h.await.expect("task panicked");
        codes.insert(code);
    }

    // The acceptance criterion: every one of the N codes is unique.
    assert_eq!(
        codes.len(),
        N,
        "found duplicate codes under concurrency: {} unique of {} requests",
        codes.len(),
        N
    );
}
