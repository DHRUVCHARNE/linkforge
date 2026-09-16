use serde::Deserialize;
use std::time::Duration;


/// Top-level application configuration
/// Built once at startup by `config::load()`, then treated as read-only

#[derive(Debug, Clone, Deserialize)]
pub struct Settings {
    pub server: ServerConfig,
    pub database: DatabaseSettings,
    pub redis: RedisConfig,
    pub rate_limit: RateLimitConfig,
    pub auth: AuthConfig,
    pub env: Environment,
    pub cache:CacheConfig
}

#[derive(Debug, Clone, Deserialize)]
pub struct ServerConfig {
    #[serde(default = "default_host")]
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DatabaseSettings {
    pub url: String,
    #[serde(default = "default_max_connections")]
    pub max_connections: u32,
    #[serde(default = "default_acquire_timeout_secs")]
    pub acquire_timeout_secs: u64,
    pub idle_timeout_secs: u64,
    
}

impl DatabaseSettings {
    pub fn acquire_timeout(&self) -> Duration {
        Duration::from_secs(self.acquire_timeout_secs)
    }
    pub fn idle_timeout(&self) -> Duration {
        Duration::from_secs(self.idle_timeout_secs)
    }
}

#[derive(Debug,Clone,Deserialize)]
pub struct CacheConfig {
    #[serde(default="default_negative_ttl_secs")]
    pub negative_ttl_secs:u64,
}

impl CacheConfig {
    pub fn negative_ttl(&self) -> Duration {
        Duration::from_secs(self.negative_ttl_secs)
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct RedisConfig {
    pub url: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RateLimitConfig {
    #[serde(default = "default_rate_requests")]
    pub requests: u32,
    #[serde(default = "default_rate_window_secs")]
    pub window_secs: u64,
}

impl RateLimitConfig {
    pub fn window(&self) -> Duration {
        Duration::from_secs(self.window_secs)
    }
}

#[derive(Clone, Deserialize)]
pub struct AuthConfig {
    pub jwt_secret: String,
    #[serde(default = "default_jwt_expiry_secs")]
    pub jwt_expiry_secs: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Environment {
    #[default]
    Development,
    Production,
}

// ── Defaults (used when a var is absent) ─────────────────────
fn default_host() -> String {
    "0.0.0.0".into()
}

fn default_port() -> u16 {
    3000
}

fn default_max_connections() -> u32 {
    20
}

fn default_acquire_timeout_secs() -> u64 {
    3
}

fn default_rate_requests() -> u32 {
    100
}

fn default_rate_window_secs() -> u64 {
    60
}

fn default_jwt_expiry_secs() -> u64 {
    3600
}

fn default_negative_ttl_secs() -> u64 {
    30
}

impl std::fmt::Debug for AuthConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthConfig")
            .field("jwt_secret", &"<redacted>")
            .field("jwt_expiry_secs", &self.jwt_expiry_secs)
            .finish()
    }
}
