use crate::app::state::AppState;
use crate::handlers::{health, redirect, shorten};
use axum::{
    Router,
    routing::{get, post},
};

pub fn create(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health::health))
        .route("/shorten", post(shorten::shorten))
        .route("/{code}", get(redirect::redirect))
        .with_state(state)
}
