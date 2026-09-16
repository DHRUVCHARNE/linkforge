pub mod click_repository;
pub mod link_repository;

use async_trait::async_trait;

use crate::domain::{link::Link, short_code::ShortCode};

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
