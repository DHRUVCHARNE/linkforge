use std::time::Instant;

use axum::{
    extract::{MatchedPath, Request},
    middleware::Next,
    response::Response,
};

use crate::observability::metrics::{HTTP_DURATION, HTTP_REQUESTS};


pub async fn track(req: Request, next: Next) -> Response {
    let start = Instant::now();
    let method = req.method().clone();
    let route = req
        .extensions()
        .get::<MatchedPath>()
        .map(|path| path.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".to_owned());
    let response = next.run(req).await;
    let status = response.status().as_u16().to_string();
    let elapsed = start.elapsed().as_secs_f64();

    metrics::counter!(
        HTTP_REQUESTS,
        "method"=>method.to_string(),
        "route"=>route.clone(),
        "status"=>status
    )
    .increment(1);
    metrics::histogram!(HTTP_DURATION
    , "method"=>method.to_string(),
    "route"=>route
    )
    .record(elapsed);
    response
}
