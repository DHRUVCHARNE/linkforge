use sqlx::postgres::{PgPool, PgPoolOptions};

use crate::config::DatabaseSettings;

pub async fn create(cfg: &DatabaseSettings) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(cfg.max_connections)
        .acquire_timeout(cfg.acquire_timeout())
        .idle_timeout(cfg.idle_timeout())
        .connect(&cfg.url)
        .await?;
    Ok(pool)
}
