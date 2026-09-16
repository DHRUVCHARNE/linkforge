use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;
use tracing;

use crate::repositories::RepoError;

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
                tracing::error!(error=?e,"internal error");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal_server_error")
            }
        };
        (status, Json(json!({"error":message}))).into_response()
    }
}

impl From<RepoError> for AppError {
    fn from(e: RepoError) -> Self {
        match e {
            RepoError::Duplicate => AppError::Internal(anyhow::anyhow!("code collision")),
            RepoError::Database(e) => AppError::Internal(e.into()),
        }
    }
}
