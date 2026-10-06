use std::time::Duration;
use metrics_exporter_prometheus::{Matcher, PrometheusBuilder, PrometheusHandle};

pub fn init() -> anyhow::Result<PrometheusHandle> {
    let handle = PrometheusBuilder::new()
        .set_buckets_for_metric(
            Matcher::Full(HTTP_DURATION.to_string()),
            &[0.00001, 0.000025, 0.00005, 0.0001, 0.00025, 0.0005,
              0.001, 0.0025, 0.005, 0.01, 0.025, 0.1],
        )?
        .install_recorder()?;

    describe();          // HELP text
    zero_lazy_series();  // dropped / failures / rejections start at 0
    Ok(handle)
}

/// Call from AppState::build / main. Keeps exporter state tidy.
pub fn spawn_upkeep(handle: PrometheusHandle) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(5));
        loop { tick.tick().await; handle.run_upkeep(); }
    });
}

fn describe() {
    metrics::describe_counter!(HTTP_REQUESTS, "HTTP requests by method, route template, status");
    metrics::describe_histogram!(HTTP_DURATION, metrics::Unit::Seconds, "Server-side request latency");
    metrics::describe_counter!(CACHE_LOOKUPS, "Cache lookups by result (hit|negative_hit|miss)");
    metrics::describe_counter!(CLICKS_ENQUEUED, "Clicks accepted into the channel");
    metrics::describe_counter!(CLICKS_DROPPED, "Clicks dropped because the channel was full");
    metrics::describe_counter!(CLICK_ROWS_WRITTEN, "Click rows persisted to Postgres");
    metrics::describe_counter!(CLICK_BATCHES, "Successful click batch INSERTs");
    metrics::describe_counter!(CLICK_BATCH_FAILURES, "Failed click batch INSERTs");
    metrics::describe_gauge!(CLICK_QUEUE_DEPTH, "Clicks waiting in the channel");
    metrics::describe_counter!(RATE_LIMIT_REJECTIONS, "Requests rejected with 429");
    metrics::describe_gauge!(RATE_LIMIT_BUCKETS, "Live rate-limit buckets");
}

fn zero_lazy_series() {
    metrics::counter!(CLICKS_DROPPED).absolute(0);
    metrics::counter!(CLICK_BATCH_FAILURES).absolute(0);
    metrics::counter!(RATE_LIMIT_REJECTIONS).absolute(0);
}
pub const HTTP_REQUESTS: &str = "linkforge_http_requests_total";
pub const HTTP_DURATION: &str = "linkforge_http_request_duration_seconds";
pub const CACHE_LOOKUPS: &str = "linkforge_cache_lookups_total";
pub const CLICKS_ENQUEUED: &str = "linkforge_clicks_enqueued_total";
pub const CLICKS_DROPPED: &str = "linkforge_clicks_dropped_total";
pub const CLICK_ROWS_WRITTEN: &str = "linkforge_click_rows_written_total";
pub const CLICK_BATCHES: &str = "linkforge_click_batches_total";
pub const CLICK_BATCH_FAILURES: &str = "linkforge_click_batch_failures_total";
pub const CLICK_QUEUE_DEPTH: &str = "linkforge_click_queue_depth";
pub const RATE_LIMIT_REJECTIONS: &str = "linkforge_rate_limit_rejections_total";
pub const RATE_LIMIT_BUCKETS: &str = "linkforge_rate_limit_buckets";