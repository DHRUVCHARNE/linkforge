use axum::{body::Body, http::Request};
use tower_http::trace::{DefaultOnResponse, TraceLayer};
use tracing::{Level, Span, info_span};

pub fn layer() -> TraceLayer<
    tower_http::classify::SharedClassifier<tower_http::classify::ServerErrorsAsFailures>,
    impl Fn(&Request<Body>) -> Span + Clone,
> {
    TraceLayer::new_for_http().make_span_with(|req: &Request<Body>| {
        //Health checks are pure noise at this scale
        if req.uri().path()=="/health" {
            return tracing::Span::none();
        }
        let request_id =
            req.headers().get("x-request-id").and_then(|v| v.to_str().ok()).unwrap_or("unknown");
        // `Empty` fields are recorded later by handlers via Span::current().
        info_span!(
            "http_request",
            method=req.method().as_str(),
            uri=req.uri().path(),
            request_id=request_id,
            status=tracing::field::Empty,
        )
    })
    .on_response(DefaultOnResponse::new().level(Level::DEBUG))
}
