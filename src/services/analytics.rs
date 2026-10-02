use std::sync::Arc;

use serde::Serialize;

use crate::{
    domain::short_code::ShortCode,
    errors::app_error::AppError,
    repositories::{ClickRepository, LinkRepository},
};
#[derive(Debug, Serialize)]
pub struct LinkStats {
    code: String,
    clicks: i64,
}
pub struct AnalyticsService {
    clicks: Arc<dyn ClickRepository>,
    links: Arc<dyn LinkRepository>,
}

impl AnalyticsService {
    pub fn new(clicks: Arc<dyn ClickRepository>, links: Arc<dyn LinkRepository>) -> Self {
        Self { clicks, links }
    }
    pub async fn stats_for(&self, raw_code: &str) -> Result<LinkStats, AppError> {
        let code = ShortCode::parse(raw_code).map_err(|_| AppError::NotFound)?;
        //404 for a code that never existed, rather than reporting 0 clicks
        self.links.find_by_code(&code).await?.ok_or(AppError::NotFound)?;
        Ok(LinkStats {
            code: code.as_str().to_string(),
            clicks: self.clicks.count_for(&code).await?,
        })
    }
}
