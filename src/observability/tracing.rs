use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use crate::config::{Environment, Settings};

/// Initialise tracing. Call ONCE at startup, before anything else.
///
/// Returns a `WorkerGuard` that MUST be held for the process lifetime —
/// dropping it flushes and stops the background writer, so buffered logs
/// are lost. Bind it in `main`: `let _guard = init(&settings);`
pub fn init(settings: &Settings) -> WorkerGuard {
    // Default filter is quieter than before: tower_http=debug logged an event
    // per request/response, which is pure cost at ~9k req/s.
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new("linkforge=info,tower_http=warn,sqlx=warn,warn")
    });

    // Non-blocking writer: log formatting + the write() syscall move off the
    // request's thread onto a background worker fed by a bounded channel.
    // Same pattern as Phase 4's click pipeline, arriving early for logs.
    let (writer, guard) = tracing_appender::non_blocking(std::io::stdout());

    let registry = tracing_subscriber::registry().with(filter);

    match settings.env {
        // Production: JSON, machine-parseable, ready for a log aggregator.
        Environment::Production => registry
            .with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .flatten_event(true)
                    .with_writer(writer),
            )
            .init(),

        // Development: human-readable, span path visible. Still non-blocking
        // so dev and prod share one code path.
        Environment::Development => registry
            .with(
                tracing_subscriber::fmt::layer()
                    .pretty()
                    .with_target(true)
                    .with_writer(writer),
            )
            .init(),
    }

    guard
}
