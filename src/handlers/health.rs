use axum::{Json, extract::State};
use reqwest::StatusCode;
use serde_json::{Value, json};

use crate::{app::state::AppState, services::health::ReadinessStatus};
pub async fn health() -> Json<Value> {
    Json(json!({
        "status":"healthy",
        "status_code":200
    }))
}

pub async fn live() -> &'static str {
    "ok"
}

pub async fn ready(State(st): State<AppState>) -> (StatusCode, Json<Value>) {
    match st.health.readiness().await {
        ReadinessStatus::Ready => (StatusCode::OK, Json(json!({"status":"ready"}))),
        ReadinessStatus::Draining => {
            (StatusCode::SERVICE_UNAVAILABLE, Json(json!({"status":"draining"})))
        }
        ReadinessStatus::DatabaseUnavailable => {
            (StatusCode::SERVICE_UNAVAILABLE, Json(json!({"status":"database_unavailable"})))
        }
    }
}
