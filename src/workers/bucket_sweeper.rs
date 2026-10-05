use std::time::Duration;

use crate::middleware::rate_limit::RateLimitState;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

pub fn spawn(
    state: RateLimitState,
    interval: Duration,
    idle: Duration,
    cancel: CancellationToken,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(interval);
        tracing::info!(
            sweep_interval_secs = interval.as_secs(),
            idle_ttl_secs = idle.as_secs(),
            "bucket sweeper started"
        );
        ticker.tick().await;
        metrics::gauge!("linkforge_rate_limit_buckets").set(state.bucket_count() as f64);
        loop {
            tokio::select! {
                _=cancel.cancelled() => {
                    tracing::info!("bucket sweeper stopped");
                    break;
                }
                _=ticker.tick() => {

                    let evicted = state.sweep(idle);
                                        metrics::gauge!("linkforge_rate_limit_buckets").set(state.bucket_count() as f64);

                    if evicted > 0 {
                        tracing::info!(evicted,buckets_remaining=state.bucket_count(), "swept idle rate-limiting buckets");
                    }
                }
            }
        }
    })
}
