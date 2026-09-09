use std::sync::{Arc};
use std::sync::atomic::{AtomicU64, Ordering};
use crate::domain::{link::Link, short_code::ShortCode};
use crate::errors::app_error::AppError;
use crate::utils::base62;
use dashmap::DashMap;
pub struct ShortenerService {
    // read-heavy map: RwLock allows multiple readers or one writer to proceed in parallel
    store:DashMap<ShortCode, Arc<str>>,
    // lock-free monotonic id source - the anti-duplicate guarantee
    counter: AtomicU64,
}

impl ShortenerService {
    pub fn new() -> Self {
        Self { store: DashMap::new(), counter: AtomicU64::new(1) }
    }
    pub fn create(&self, url: String) -> Result<Link, AppError> {
        //1. Validate (business rule) - no framework types here
        let url = Self::validate_url(url)?;
        //2. generate a unique code without holding write lock
        let id = self.counter.fetch_add(1, Ordering::Relaxed);
        let code = ShortCode::from_generated(base62::encode(id));
        //3. Write lock held only for the insert
        //Why the braces the braces create a separate scope
        // When execution reaches } the map variable is destroyed
        // and when the write guard is destroyed, the write lock is released
        // Why are we immedeately releasing the lock as holding them is expensive so release it asap
        // {
        //     let mut map = self
        //         .store
        //         .write()
        //         .map_err(|_| AppError::Internal(anyhow::anyhow!("store lock poisoned")))?;
        //     map.insert(code.clone(), url.clone());
        // }
        let shared:Arc<str> = Arc::from(url.as_str());
        self.store.insert(code.clone(), shared);
        Ok(Link::new(code, url))
    }
    // Shared by the redirect service
    pub fn lookup(&self, code: &ShortCode) -> Result<Option<Arc<str>>, AppError> {
        Ok(self.store.get(code).map(|entry| entry.value().clone()))
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

impl Default for ShortenerService {
    fn default() -> Self {
        Self::new()
    }
}
