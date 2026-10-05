use crate::app::state::AppState;
use crate::handlers::{analytics, debug, health, metrics, redirect, shorten};
use crate::middleware::metrics::track;
use crate::middleware::{
    rate_limit::RateLimitLayer, request_id::MakeRequestUuid, tracing as trace_mw,
};
use axum::middleware::from_fn;
use axum::{
    Router,
    routing::{get, post},
};
use reqwest::StatusCode;
use tower::ServiceBuilder;
use tower_http::request_id::{PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::timeout::TimeoutLayer;
pub fn create(state: AppState) -> Router {
    let rate_limiter = state.rate_limiter.clone();
    let request_timeout = state.request_timeout;
    let mut router = Router::new()
        .route("/health",get(health::health))
        .route("/shorten", post(shorten::shorten))
        .route("/{code}/stats", get(analytics::stats))
        .route("/metrics", get(metrics::metrics));
    //Dev only
    if state.debug_routes {
        router = router
            .route("/debug/cache", get(debug::cache_stats))
            .route("/debug/cache/invalidate/{code}", post(debug::invalidate))
            .route("/debug/analytics", get(debug::analytics_stats))
    }
    let router = router
        .route("/{code}", get(redirect::redirect))
        .layer(
            ServiceBuilder::new()
                .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
                .layer(from_fn(track))
                .layer(trace_mw::layer())
                .layer(TimeoutLayer::with_status_code(StatusCode::REQUEST_TIMEOUT, request_timeout))
                .layer(RateLimitLayer::from_state(rate_limiter))
                .layer(PropagateRequestIdLayer::x_request_id()),
        );
        //Probes are merged after .layer(), so the middleware stack doesn't wrap them.
        // A health checker polling from one ip must never get a 429 from readiness
        let probes = Router::new()
        .route("/health/live", get(health::live))
        .route("/health/ready", get(health::ready));


        router.merge(probes).with_state(state)
}
