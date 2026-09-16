use std::sync::atomic::{AtomicU64, Ordering};

use async_trait::async_trait;
use sqlx::postgres::PgPool;

use super::{LinkRepository, RepoError};
use crate::domain::{link::Link, short_code::ShortCode};

pub struct SqlxLinkRepository {
    pool: PgPool,
    queries:AtomicU64
}

impl SqlxLinkRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool,queries:AtomicU64::new(0) }
    }
   
}

#[async_trait]
impl LinkRepository for SqlxLinkRepository {
    async fn create(&self, link: &Link) -> Result<(), RepoError> {
        let result = sqlx::query!(
            "INSERT INTO links (code,url) VALUES ($1,$2)",
            link.code.as_str(),
            link.target_url.as_str()
        )
        .execute(&self.pool)
        .await;
        match result {
            Ok(_) => Ok(()),
            Err(sqlx::Error::Database(e)) if e.code().as_deref() == Some("23505") => {
                Err(RepoError::Duplicate)
            }
            Err(e) => Err(RepoError::Database(e)),
        }
    }
    async fn find_by_code(&self, code: &ShortCode) -> Result<Option<Link>, RepoError> {
        self.queries.fetch_add(1,Ordering::Relaxed);
        let row = sqlx::query!("SELECT code, url FROM links WHERE code = $1", code.as_str())
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.map(|r| Link::new(ShortCode::from_generated(r.code), r.url)))
    }
    fn query_count(&self) -> u64 {
        self.queries.load(Ordering::Relaxed)
    } 
}
