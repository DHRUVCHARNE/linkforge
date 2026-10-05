//! Layered configuration. Later layers override earlier ones:
//!
//!   configs/default.toml
//!   → configs/{APP_ENV}.toml
//!   → LINKFORGE__SECTION__KEY environment variables
//!   → secrets under their conventional names (DATABASE_URL, …)
//!
//! This is the only module that reads the environment.

mod settings;
pub use settings::*;

use figment::{
    providers::{Env, Format, Toml},
    Figment,
};

const DEFAULT_CONFIG: &str = "configs/default.toml";

pub fn load() -> anyhow::Result<Settings> {
    dotenvy::dotenv().ok(); // absent in containers; real env vars are used there

    anyhow::ensure!(
        std::path::Path::new(DEFAULT_CONFIG).exists(),
        "{DEFAULT_CONFIG} not found: run from the crate root (cwd: {})",
        std::env::current_dir()
            .map(|p| p.display().to_string())
            .unwrap_or_default()
    );

    // APP_ENV decides which file to load, so it can't come from the files.
    let env = std::env::var("APP_ENV").unwrap_or_else(|_| "development".into());
    load_from(figment_for(&env))
}

/// Separate from `load` so tests can build a Figment inside a `figment::Jail`.
pub fn figment_for(env: &str) -> Figment {
    Figment::new()
        .merge(Toml::file(DEFAULT_CONFIG))
        .merge(Toml::file(format!("configs/{env}.toml")))
        .merge(("env", env))
        // LINKFORGE__RATE_LIMIT__REQUESTS=500 → rate_limit.requests
        .merge(Env::prefixed("LINKFORGE__").split("__"))
        // Secrets keep their conventional names (sqlx-cli and Docker expect DATABASE_URL).
        .merge(Env::raw().only(&["DATABASE_URL"]).map(|_| "database.url".into()))
        .merge(Env::raw().only(&["ANALYTICS_IP_SALT"]).map(|_| "analytics.ip_salt".into()))
        .merge(Env::raw().only(&["JWT_SECRET"]).map(|_| "auth.jwt_secret".into()))
        .merge(Env::raw().only(&["REDIS_URL"]).map(|_| "redis.url".into()))
}

pub fn load_from(figment: Figment) -> anyhow::Result<Settings> {
    let settings: Settings = figment.extract()?;
    settings.validate()?;
    Ok(settings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use figment::Jail;

    fn setup(jail: &mut Jail) -> figment::error::Result<()> {
        jail.clear_env();
        jail.create_dir("configs")?;
        jail.create_file("configs/default.toml", include_str!("../../configs/default.toml"))?;
        jail.set_env("DATABASE_URL", "postgres://x@localhost/x");
        Ok(())
    }

    #[test]
    fn defaults_load_and_validate() {
        Jail::expect_with(|jail| {
            setup(jail)?;
            let s = load_from(figment_for("development")).expect("defaults must be valid");
            assert_eq!(s.analytics.click_mode, ClickMode::Async);
            assert_eq!(s.rate_limit.sweep_interval_secs, 300);
            Ok(())
        });
    }

    #[test]
    fn prefixed_env_overrides_toml() {
        Jail::expect_with(|jail| {
            setup(jail)?;
            jail.set_env("LINKFORGE__RATE_LIMIT__REQUESTS", "500");
            jail.set_env("LINKFORGE__ANALYTICS__CLICK_MODE", "sync");
            let s = load_from(figment_for("development")).unwrap();
            assert_eq!(s.rate_limit.requests, 500);
            assert_eq!(s.analytics.click_mode, ClickMode::Sync);
            Ok(())
        });
    }

    #[test]
    fn rejects_idle_ttl_shorter_than_window() {
        Jail::expect_with(|jail| {
            setup(jail)?;
            jail.set_env("LINKFORGE__RATE_LIMIT__IDLE_TTL_SECS", "1");
            jail.set_env("LINKFORGE__RATE_LIMIT__WINDOW_SECS", "60");
            let err = load_from(figment_for("development")).unwrap_err().to_string();
            assert!(err.contains("idle_ttl_secs"), "{err}");
            Ok(())
        });
    }

    #[test]
    fn rejects_inverted_timeouts() {
        Jail::expect_with(|jail| {
            setup(jail)?;
            jail.set_env("LINKFORGE__DATABASE__STATEMENT_TIMEOUT_SECS", "20");
            assert!(load_from(figment_for("development")).is_err());
            Ok(())
        });
    }

    #[test]
    fn production_requires_salt() {
        Jail::expect_with(|jail| {
            setup(jail)?;
            let err = load_from(figment_for("production")).unwrap_err().to_string();
            assert!(err.contains("ANALYTICS_IP_SALT"), "{err}");
            Ok(())
        });
    }

    #[test]
    fn production_rejects_debug_routes() {
        Jail::expect_with(|jail| {
            setup(jail)?;
            jail.set_env("ANALYTICS_IP_SALT", "x");
            jail.set_env("LINKFORGE__SERVER__DEBUG_ROUTES", "true");
            let err = load_from(figment_for("production")).unwrap_err().to_string();
            assert!(err.contains("debug_routes"), "{err}");
            Ok(())
        });
    }
}