use crate::domain::short_code::ShortCode;
use crate::errors::app_error::AppError;
use crate::services::shortener::ShortenerService;
use std::sync::Arc;

pub struct RedirectService {
    shortener: Arc<ShortenerService>,
}

impl RedirectService {
    pub fn new(shortener: Arc<ShortenerService>) -> Self {
        Self { shortener }
    }
    pub fn resolve(&self, raw_code: &str) -> Result<Arc<str>, AppError> {
        // untrusted input from the URL path -> validate through the domain
        let code = ShortCode::parse(raw_code).map_err(|_| AppError::NotFound)?;
        self.shortener.lookup(&code)?.ok_or(AppError::NotFound)
    }
}
