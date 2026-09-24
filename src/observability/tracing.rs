use crate::config::{Environment, Settings};
use tracing_subscriber::{EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

pub fn init(settings: &Settings) {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("linkforge=debug,tower_http=debug,info"));
    let registry = tracing_subscriber::registry().with(filter);
    match settings.env {
        //Production: JSON machine-parseable, ready for a log aggregator
        Environment::Production => {
            registry.with(tracing_subscriber::fmt::layer().json().flatten_event(true)).init();
        }
        //Development: human-readable, with the span path visible.
        Environment::Development => {
            registry.with(tracing_subscriber::fmt::layer().pretty().with_target(true)).init()
        }
    }
}
