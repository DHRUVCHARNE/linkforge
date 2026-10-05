use std::str::FromStr;

use sqlx::postgres::{PgConnectOptions, PgPool, PgPoolOptions};

use crate::config::DatabaseSettings;

pub async fn create(cfg: &DatabaseSettings) -> anyhow::Result<PgPool> {
    let statement_timeout_ms = cfg.statement_timeout().as_millis().to_string();
    let connect = PgConnectOptions::from_str(&cfg.url)?
        .options([("statement_timeout", statement_timeout_ms.as_str())]);
    let pool = PgPoolOptions::new()
        .max_connections(cfg.max_connections)
        .acquire_timeout(cfg.acquire_timeout())
        .idle_timeout(cfg.idle_timeout())
        .connect_with(connect)
        .await?;
    Ok(pool)
}
