use async_trait::async_trait;
use sqlx::{PgPool, Postgres, QueryBuilder};

use crate::{
    domain::{click::Click, short_code::ShortCode},
    repositories::{ClickRepository, RepoError},
};

pub struct SqlxClickRepository {
    pool: PgPool,
}

#[async_trait]
impl ClickRepository for SqlxClickRepository {
    async fn insert_batch(&self, clicks: &[Click]) -> Result<(), RepoError> {
        if clicks.is_empty() {
            return Ok(());
        }
        //One multi-row INSERT, not N statements. One round trip one Transaction, one fsync
        let mut qb = QueryBuilder::<Postgres>::new("INSERT INTO clicks (code,ts,ip_hash)");
        qb.push_values(clicks, |mut row, c| {
            row.push_bind(c.code.as_str()).push_bind(c.ts).push_bind(c.ip_hash.as_deref());
        });
        qb.build().execute(&self.pool).await?;
        Ok(())
    }
    async fn count_for(&self, code: &ShortCode) -> Result<i64, RepoError> {
        let n = sqlx::query_scalar!("SELECT COUNT(*) FROM clicks WHERE code=$1", code.as_str())
            .fetch_one(&self.pool)
            .await?
            .unwrap_or(0);
        Ok(n)
    }
}

impl SqlxClickRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}
