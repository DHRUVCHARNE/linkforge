use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Instant,
};

use axum::{
    body::Body,
    extract::{ConnectInfo, Request},
    http::Response,
};
use dashmap::DashMap;
use reqwest::StatusCode;
use tower::Service;

use crate::config::RateLimitConfig;

///The Bucket
#[derive(Debug)]
pub struct Bucket {
    tokens: f64,
    last_refill: Instant,
}

impl Bucket {
    fn new(capacity: f64) -> Self {
        Self { tokens: capacity, last_refill: Instant::now() }
    }
    /// Lazy refill: tokens accrue at `rate` per second, capped at  `capacity`
    /// O(1) on access - no background  ticker walking every bucket.
    fn try_consume(&mut self, capacity: f64, rate: f64) -> bool {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_refill).as_secs_f64();
        self.tokens = (self.tokens + elapsed * rate).min(capacity);
        self.last_refill = now;
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

#[derive(Clone)]
pub struct RateLimitState {
    buckets: Arc<DashMap<IpAddr, Bucket>>,
    capacity: f64,
    refill_per_sec: f64,
}

impl RateLimitState {
    pub fn from_config(cfg: &RateLimitConfig) -> Self {
        // `requests` per `window_secs` -> a sustained rate plus burst capacity
        let capacity = cfg.requests as f64;
        let refill_per_sec = cfg.requests as f64 / cfg.window_secs as f64;
        tracing::info!(capacity, refill_per_sec, "rate limiter configured");
        Self { buckets: Arc::new(DashMap::new()), capacity, refill_per_sec }
    }
}

#[derive(Clone)]
pub struct RateLimitLayer {
    state: RateLimitState,
}

impl RateLimitLayer {
    pub fn new(cfg: RateLimitConfig) -> Self {
        Self { state: RateLimitState::from_config(&cfg) }
    }
}

impl<S> tower::Layer<S> for RateLimitLayer {
    type Service = RateLimitService<S>;
    fn layer(&self, inner: S) -> RateLimitService<S> {
        RateLimitService { inner, state: self.state.clone() }
    }
}

#[derive(Clone)]
pub struct RateLimitService<S> {
    inner: S,
    state: RateLimitState,
}

impl<S> Service<Request<Body>> for RateLimitService<S>
where
    S: Service<Request<Body>, Response = Response<Body>> + Clone + Send + 'static,
    S::Future: Send + 'static,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = futures_util::future::BoxFuture<'static, Result<Self::Response, Self::Error>>;
    /// Tower's contract: ask before you call. We add no readiness constraint
    /// of our own, so delegate to the inner service.
    fn poll_ready(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }
    fn call(&mut self, req: Request<Body>) -> Self::Future {
        let ip = extract_ip(&req);
        //Scoped so the dashmap guard drops before any await point.
        let allowed = {
            let mut bucket =
                self.state.buckets.entry(ip).or_insert_with(|| Bucket::new(self.state.capacity));
            bucket.try_consume(self.state.capacity, self.state.refill_per_sec)
        };
        if !allowed {
            tracing::warn!(%ip, "rate limit exceeded");
            let retry_after = self.state.refill_per_sec.recip().ceil() as u64;
            let resp = Response::builder()
                .status(StatusCode::TOO_MANY_REQUESTS)
                .header("retry_after", retry_after.to_string())
                .header("content-type", "application/json")
                .body(Body::from(r#"{"error":"rate limit exceeded"}"#))
                .expect("static 429 response is not valid");
            return Box::pin(async move { Ok(resp) });
        }
        // The clone dance: `call` needs a 'static future, but a freshly cloned
        // service has not been poll_ready'd. Swap so we call the READY one.
        let clone = self.inner.clone();
        let mut inner = std::mem::replace(&mut self.inner, clone);
        Box::pin(async move { inner.call(req).await })
    }
}

// Client IP extraction
///SECURITY: `x-forwarded-for` is client-controlled unless a trusted proxy overwrites it. Trusting it on a directly-exposed server lets anyone defeat
/// the limiter by rotating the header. Only honour it behind a proxy you own.
fn extract_ip(req: &Request<Body>) -> IpAddr {
    #[cfg(feature = "trust_proxy_headers")]
    if let Some(fwd) = req.headers().get("x-forwarded-for")
        && let Some(first) = fwd.to_str().ok().and_then(|s| s.split(',').next())
        && let Ok(ip) = first.trim().parse::<IpAddr>()
    {
        return ip;
    }
    req.extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ci| ci.0.ip())
        .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED))
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn allows_up_to_capacity_then_rejects() {
        let mut b = Bucket::new(3.0);
        assert!(b.try_consume(3.0, 1.0));
        assert!(b.try_consume(3.0, 1.0));
        assert!(b.try_consume(3.0, 1.0));
        assert!(!b.try_consume(3.0, 1.0), "4th request must be rejected"); //4th request must be rejected
    }
    #[test]
    fn refills_over_time() {
        let mut b = Bucket::new(1.0);
        assert!(b.try_consume(1.0, 100.0));
        assert!(!b.try_consume(1.0, 100.0));
        std::thread::sleep(std::time::Duration::from_millis(50));
        // 50 ms at 100 tokens/sec = 5 tokens, capped at capacity 1
        assert!(b.try_consume(1.0, 100.0), "bucket should have refilled");
    }
    #[test]
    fn never_exceeds_capacity() {
        let mut b = Bucket::new(2.0);
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert!(b.try_consume(2.0, 1000.0));
        assert!(b.try_consume(2.0, 1000.0));
        assert!(!b.try_consume(2.0, 1000.0), "capacity must cap accrual");
    }
}
