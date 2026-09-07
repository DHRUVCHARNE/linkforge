use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;
use tracing;

#[derive(Debug)]
pub enum AppError {
    NotFound,
    InvalidUrl,
    Internal(anyhow::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            AppError::NotFound => (StatusCode::NOT_FOUND, "short code not found"),
            AppError::InvalidUrl => (StatusCode::BAD_REQUEST, "invalid_url"),
            AppError::Internal(e) => {
                /// Log the cause , never leak internals to the client
                tracing::error!(error=?e,"internal error");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal_server_error")
            }
        };
        (status, Json(json!({"error":message}))).into_response()
    }
}
