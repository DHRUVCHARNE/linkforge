use crate::app::state::AppState;
use crate::handlers::{analytics, debug, health, redirect, shorten};
use crate::middleware::{
    rate_limit::RateLimitLayer, request_id::MakeRequestUuid, tracing as trace_mw,
};
use axum::{
    Router,
    routing::{get, post},
};
use tower::ServiceBuilder;
use tower_http::request_id::{PropagateRequestIdLayer, SetRequestIdLayer};
pub fn create(state: AppState) -> Router {
    let mut router = Router::new()
        .route("/health", get(health::health))
        .route("/shorten", post(shorten::shorten))
        .route("/{code}/stats", get(analytics::stats));
    //Dev only
    if state.debug_routes {
        router = router
            .route("/debug/cache", get(debug::cache_stats))
            .route("/debug/cache/invalidate/{code}", post(debug::invalidate))
            .route("/debug/analytics",get(debug::analytics_stats))
    }
    router
        .route("/{code}", get(redirect::redirect))
        .layer(
            ServiceBuilder::new()
                .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
                .layer(trace_mw::layer())
                .layer(RateLimitLayer::from_state(state.rate_limiter.clone()))
                .layer(PropagateRequestIdLayer::x_request_id()),
        )
        .with_state(state)
}
