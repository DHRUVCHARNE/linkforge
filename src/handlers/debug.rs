use std::sync::atomic::Ordering;

use crate::app::state::AppState;
use crate::domain::short_code::ShortCode;
use crate::errors::app_error::AppError;
use axum::{
    Json,
    extract::{Path, State},
};
use serde_json::{Value, json};

pub async fn cache_stats(State(st): State<AppState>) -> Json<Value> {
    let s = st.cache.stats();
    Json(json!({
        "hits":s.hits,
        "negative_hits":s.negative_hits,
        "misses":s.misses,
        "ratio":s.hit_ratio(),
        "db_queries":st.links.query_count()
    }))
}

pub async fn invalidate(
    State(st): State<AppState>,
    Path(code): Path<String>,
) -> Result<Json<Value>, AppError> {
    let c = ShortCode::parse(&code).map_err(|_| AppError::NotFound)?;
    st.cache.invalidate(&c).await;
    Ok(Json(json!({
        "invalidated":code
    })))
}

pub async fn analytics_stats(State(st): State<AppState>) -> Json<Value> {
    let s = st.clicks.stats();
    Json(json!({
        "mode": st.click_mode.as_str(),
        "enqueued":s.enqueued.load(Ordering::Relaxed),
        "dropped":s.dropped.load(Ordering::Relaxed),
        "batches":s.batches.load(Ordering::Relaxed),
        "rows_written":s.rows_written.load(Ordering::Relaxed),
        "failed_batches":&s.failed_batches.load(Ordering::Relaxed),
        "queue_depth":st.clicks.queue_depth(),
        "max_batch":st.clicks.max_batch()
    }))
}
