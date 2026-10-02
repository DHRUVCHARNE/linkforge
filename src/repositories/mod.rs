pub mod click_repository;
pub mod link_repository;

use async_trait::async_trait;

use crate::domain::{click::Click, link::Link, short_code::ShortCode};

#[derive(Debug, thiserror::Error)]
pub enum RepoError {
    #[error("duplicate code")]
    Duplicate,
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),
}

#[async_trait]
pub trait LinkRepository: Send + Sync {
    async fn create(&self, link: &Link) -> Result<(), RepoError>;
    async fn find_by_code(&self, code: &ShortCode) -> Result<Option<Link>, RepoError>;
    fn query_count(&self) -> u64 {
        0
    }
}

#[async_trait]
pub trait ClickRepository: Send + Sync + 'static {
    /// Batched insert. the whole point of the worker is that
    /// this is called once per BATCH, not once per redirect
    async fn insert_batch(&self, clicks: &[Click]) -> Result<(), RepoError>;
    async fn count_for(&self, code: &ShortCode) -> Result<i64, RepoError>;
}
