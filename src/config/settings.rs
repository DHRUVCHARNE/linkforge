use std::time::Duration;

use serde::Deserialize;

/// Top-level configuration. Built once by `config::load()`, then read-only.
///
/// Every non-secret value comes from `configs/*.toml`; there are no Rust-side
/// defaults except for Phase 7 auth, which has no TOML section yet.
#[derive(Debug, Clone, Deserialize)]
pub struct Settings {
    pub env: Environment,
    pub server: ServerConfig,
    pub database: DatabaseSettings,
    pub cache: CacheConfig,
    pub rate_limit: RateLimitConfig,
    pub analytics: AnalyticsConfig,
    /// Phase 6. `None` until REDIS_URL is set.
    pub redis: Option<RedisConfig>,
    /// Phase 7. `None` until JWT_SECRET is set.
    pub auth: Option<AuthConfig>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Environment {
    Development,
    Production,
}

// ── server ──────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub request_timeout_secs: u64,
    pub debug_routes: bool,
    pub shutdown_delay_secs: u64,
}

impl ServerConfig {
    pub fn request_timeout(&self) -> Duration {
        Duration::from_secs(self.request_timeout_secs)
    }
    pub fn shutdown_delay(&self) -> Duration {
        Duration::from_secs(self.shutdown_delay_secs)
    }
}

// ── database ────────────────────────────────────────────────

#[derive(Clone, Deserialize)]
pub struct DatabaseSettings {
    /// Secret: from DATABASE_URL only.
    pub url: String,
    pub max_connections: u32,
    pub statement_timeout_secs: u64,
    pub acquire_timeout_secs: u64,
    pub idle_timeout_secs: u64,
}

impl DatabaseSettings {
    pub fn statement_timeout(&self) -> Duration {
        Duration::from_secs(self.statement_timeout_secs)
    }
    pub fn acquire_timeout(&self) -> Duration {
        Duration::from_secs(self.acquire_timeout_secs)
    }
    pub fn idle_timeout(&self) -> Duration {
        Duration::from_secs(self.idle_timeout_secs)
    }
}

impl std::fmt::Debug for DatabaseSettings {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DatabaseSettings")
            .field("url", &"<redacted>")
            .field("max_connections", &self.max_connections)
            .field("statement_timeout_secs", &self.statement_timeout_secs)
            .field("acquire_timeout_secs", &self.acquire_timeout_secs)
            .field("idle_timeout_secs", &self.idle_timeout_secs)
            .finish()
    }
}

// ── cache ───────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct CacheConfig {
    pub negative_ttl_secs: u64,
}

impl CacheConfig {
    pub fn negative_ttl(&self) -> Duration {
        Duration::from_secs(self.negative_ttl_secs)
    }
}

// ── rate limit ──────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct RateLimitConfig {
    pub requests: u32,
    pub window_secs: u64,
    pub sweep_interval_secs: u64,
    pub idle_ttl_secs: u64,
}

impl RateLimitConfig {
    pub fn window(&self) -> Duration {
        Duration::from_secs(self.window_secs)
    }
    pub fn sweep_interval(&self) -> Duration {
        Duration::from_secs(self.sweep_interval_secs)
    }
    pub fn idle_ttl(&self) -> Duration {
        Duration::from_secs(self.idle_ttl_secs)
    }
}

// ── analytics ───────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClickMode {
    Sync,
    Async,
}

impl ClickMode {
    pub fn as_str(self) -> &'static str {
        match self {
            ClickMode::Sync => "sync",
            ClickMode::Async => "async",
        }
    }
}

#[derive(Clone, Deserialize)]
pub struct AnalyticsConfig {
    /// Bounded channel depth; the memory ceiling is capacity × sizeof(Click).
    pub channel_capacity: usize,
    /// Rows per INSERT. Postgres allows 65,535 bind params; clicks use 3 per row.
    pub max_batch: usize,
    /// How long the writer waits to fill a partial batch.
    pub batch_wait_ms: u64,
    pub click_mode: ClickMode,
    /// Secret: from ANALYTICS_IP_SALT only. Empty is rejected in production.
    #[serde(default)]
    pub ip_salt: String,
}

impl AnalyticsConfig {
    pub fn batch_wait(&self) -> Duration {
        Duration::from_millis(self.batch_wait_ms)
    }
}

impl std::fmt::Debug for AnalyticsConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AnalyticsConfig")
            .field("channel_capacity", &self.channel_capacity)
            .field("max_batch", &self.max_batch)
            .field("batch_wait_ms", &self.batch_wait_ms)
            .field("click_mode", &self.click_mode)
            .field("ip_salt", &"<redacted>")
            .finish()
    }
}

// ── redis / auth (later phases) ─────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct RedisConfig {
    pub url: String,
}

#[derive(Clone, Deserialize)]
pub struct AuthConfig {
    /// Secret: from JWT_SECRET only.
    pub jwt_secret: String,
    /// Has a Rust default because there's no [auth] TOML section until Phase 7.
    #[serde(default = "default_jwt_expiry_secs")]
    pub jwt_expiry_secs: u64,
}

fn default_jwt_expiry_secs() -> u64 {
    3600
}

impl std::fmt::Debug for AuthConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthConfig")
            .field("jwt_secret", &"<redacted>")
            .field("jwt_expiry_secs", &self.jwt_expiry_secs)
            .finish()
    }
}

// ── validation ──────────────────────────────────────────────

impl Settings {
    /// Fail at startup, not at the first request.
    pub fn validate(&self) -> anyhow::Result<()> {
        use anyhow::ensure;
        let (s, db, rl, an) = (&self.server, &self.database, &self.rate_limit, &self.analytics);

        ensure!(!db.url.is_empty(), "DATABASE_URL must be set");

        ensure!(
            db.statement_timeout_secs < db.acquire_timeout_secs
                && db.acquire_timeout_secs < s.request_timeout_secs,
            "timeouts must satisfy statement ({}s) < acquire ({}s) < request ({}s)",
            db.statement_timeout_secs,
            db.acquire_timeout_secs,
            s.request_timeout_secs
        );

        ensure!(
            rl.requests > 0 && rl.window_secs > 0,
            "rate_limit.requests and rate_limit.window_secs must be > 0"
        );
        ensure!(
            rl.idle_ttl_secs >= rl.window_secs,
            "rate_limit.idle_ttl_secs ({}) must be >= rate_limit.window_secs ({}): \
             evicting a bucket mid-window resets that client's limit",
            rl.idle_ttl_secs,
            rl.window_secs
        );
        ensure!(rl.sweep_interval_secs > 0, "rate_limit.sweep_interval_secs must be > 0");

        ensure!(
            (1..=10_000).contains(&an.max_batch),
            "analytics.max_batch ({}) must be in 1..=10000 (Postgres limit: 65535 params / 3 per row)",
            an.max_batch
        );
        ensure!(
            an.channel_capacity >= an.max_batch,
            "analytics.channel_capacity ({}) must be >= analytics.max_batch ({})",
            an.channel_capacity,
            an.max_batch
        );
        ensure!(
            s.shutdown_delay_secs + s.request_timeout_secs + 10 < 30,
            "shutdown_delay + request_timeout  + 10s writer drain must fit the 30s stop grace period"
        );
        if self.env == Environment::Production {
            ensure!(!an.ip_salt.is_empty(), "ANALYTICS_IP_SALT is required in production");
            ensure!(!s.debug_routes, "server.debug_routes must be false in production");
            ensure!(
                an.click_mode == ClickMode::Async,
                "analytics.click_mode=sync is not allowed in production"
            );
        }
        Ok(())
    }
}
