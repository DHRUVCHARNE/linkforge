use crate::cache::Cache;
use crate::domain::{link::Link, short_code::ShortCode};
use crate::errors::app_error::AppError;
use crate::repositories::LinkRepository;
use crate::utils::base62;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

// dyn tells the compiler that the concrete types of link and cache
// aren't know at runtime but they will implement the LinkRepository and Cache traits.
//..at the runtime
pub struct ShortenerService {
    links: Arc<dyn LinkRepository>,
    counter: AtomicU64,
    cache: Arc<dyn Cache>,
}

impl ShortenerService {
    pub fn new(links: Arc<dyn LinkRepository>, cache: Arc<dyn Cache>, start_id: u64) -> Self {
        Self { links, cache, counter: AtomicU64::new(start_id) }
    }
    pub async fn create(&self, url: String) -> Result<Link, AppError> {
        //1. Validate (business rule) - no framework types here
        let url = Self::validate_url(url)?;
        //2. generate a unique code without holding write lock
        let id = self.counter.fetch_add(1, Ordering::Relaxed);
        let code = ShortCode::from_generated(base62::encode(id));
        let link = Link::new(code.clone(), url.clone());
        // Durable write first if this fails nothing is cached.
        self.links.create(&link).await?;
        // Warm the cache only after the DB commit succeeded
        self.cache.set(code, Arc::from(url.as_str())).await;
        Ok(link)
    }

    fn validate_url(url: String) -> Result<String, AppError> {
        let trimmed = url.trim();
        if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
            Ok(trimmed.to_string())
        } else {
            Err(AppError::InvalidUrl)
        }
    }
}
