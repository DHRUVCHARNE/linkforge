// src/config/mod.rs
mod settings;
pub use settings::*;

use anyhow::Context;

/// Load configuration once at startup.
/// Reads `.env` (via dotenvy) then pulls typed values from the environment.
pub fn load() -> anyhow::Result<Settings> {
    dotenvy::dotenv().ok(); // load .env if present; ignore if missing (prod uses real env)

    Ok(Settings {
        server: ServerConfig {
            host: env_or("APP_HOST", "0.0.0.0"),
            port: env_parse("APP_PORT", 3000)?,
        },
        database: DatabaseSettings {
            url: std::env::var("DATABASE_URL").context("DATABASE_URL must be set")?,
            max_connections: env_parse("DATABASE_MAX_CONNECTIONS", 20)?,
            acquire_timeout_secs: env_parse("DATABASE_ACQUIRE_TIMEOUT_SECS", 3)?,
            idle_timeout_secs: env_parse("DATABASE_IDLE_TIMEOUT_SECS", 3)?,
        },
        redis: RedisConfig { url: env_or("REDIS_URL", "redis://localhost:6379") },
        rate_limit: RateLimitConfig {
            requests: env_parse("RATE_LIMIT_REQUESTS", 100)?,
            window_secs: env_parse("RATE_LIMIT_WINDOW_SECS", 60)?,
        },
        auth: AuthConfig {
            jwt_secret: std::env::var("JWT_SECRET").context("JWT_SECRET must be set")?,
            jwt_expiry_secs: env_parse("JWT_EXPIRY_SECS", 3600)?,
        },
        env: match std::env::var("APP_ENV").as_deref() {
            Ok("production") => Environment::Production,
            _ => Environment::Development,
        },
        cache:CacheConfig { negative_ttl_secs: env_parse("CACHE_NEGATIVE_TTL",30)? }
    })
}

// ── tiny helpers ──
fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.into())
}

fn env_parse<T: std::str::FromStr>(key: &str, default: T) -> anyhow::Result<T>
where
    T::Err: std::fmt::Display,
{
    match std::env::var(key) {
        Ok(v) => v.parse().map_err(|e| anyhow::anyhow!("invalid {key}: {e}")),
        Err(_) => Ok(default),
    }
}
