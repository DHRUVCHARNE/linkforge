use std::time::Duration;

use crate::middleware::rate_limit::RateLimitState;

pub fn spawn(state: RateLimitState, interval: Duration, idle: Duration) {
    tokio::spawn(async move {
        
        let mut ticker = tokio::time::interval(interval);
        tracing::info!(
            sweep_interval_secs=interval.as_secs(),
            idle_ttl_secs=idle.as_secs(),
            "bucket sweeper started"
        );
        ticker.tick().await;
        loop {
            ticker.tick().await;
            let evicted = state.sweep(idle);
            if evicted > 0 {
                tracing::info!(evicted, "swept idle rate-limiting buckets");
            }
        }
    });
}
