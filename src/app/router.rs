use crate::app::state::AppState;
use crate::handlers::{debug, health, redirect, shorten};
use axum::{
    Router,
    routing::{get, post},
};

pub fn create(state: AppState) -> Router {
    let mut router = Router::new()
        .route("/health", get(health::health))
        .route("/shorten", post(shorten::shorten));
       //Dev only 
       if state.debug_routes {
        router = router
        .route("/debug/cache",get(debug::cache_stats))
        .route("/debug/cache/invalidate/{code}", post(debug::invalidate))
       }
        router
        .route("/{code}", get(redirect::redirect))
        .with_state(state)
}
