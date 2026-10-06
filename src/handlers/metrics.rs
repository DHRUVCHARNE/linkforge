use axum::{extract::State, http::HeaderValue, response::IntoResponse};
use reqwest::header;

use crate::app::state::AppState;

// handlers/metrics.rs
pub async fn metrics(State(st): State<AppState>) -> impl IntoResponse {
    use crate::observability::metrics::*;
    metrics::gauge!(CLICK_QUEUE_DEPTH).set(st.clicks.queue_depth() as f64);
    metrics::gauge!(RATE_LIMIT_BUCKETS).set(st.rate_limiter.bucket_count() as f64);

    (
        [(header::CONTENT_TYPE, HeaderValue::from_static("text/plain; version=0.0.4; charset=utf-8"))],
        st.metrics.render(),
    )
}