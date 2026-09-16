use crate::cache::{Cache, InMemoryCache};
use crate::config::{Environment, Settings};
use crate::repositories::LinkRepository;
use crate::repositories::link_repository::SqlxLinkRepository;
use crate::services::{redirect::RedirectService, shortener::ShortenerService};
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub shortener: Arc<ShortenerService>,
    pub redirect: Arc<RedirectService>,
    pub base_url: Arc<str>,
    pub cache: Arc<dyn Cache>,
    pub links: Arc<dyn LinkRepository>,
    pub debug_routes: bool,
}

impl AppState {
    pub async fn build(settings: &Settings) -> anyhow::Result<Self> {
        let pool = crate::db::pool::create(&settings.database).await?;
        crate::db::migrations::run(&pool).await?;
        //Resume the counter past the highest existing id otherwise a
        // restart restart reissues codes that already exist in the db
        let start_id: i64 = sqlx::query_scalar!("SELECT COALESCE(MAX(id),0) FROM links")
            .fetch_one(&pool)
            .await?
            .unwrap_or(0);
        let links: Arc<dyn LinkRepository> = Arc::new(SqlxLinkRepository::new(pool));
        let cache: Arc<dyn Cache> = Arc::new(InMemoryCache::new(settings.cache.negative_ttl()));
        let shortener =
            Arc::new(ShortenerService::new(links.clone(), cache.clone(), start_id as u64 + 1));
        let redirect = Arc::new(RedirectService::new(links.clone(), cache.clone()));
        let base_url: Arc<str> =
            format!("http://{}:{}", settings.server.host, settings.server.port).into();
        Ok(Self {
            shortener,
            redirect,
            base_url,
            links: Arc::clone(&links),
            cache: Arc::clone(&cache),
            debug_routes: settings.env == Environment::Development,
        })
    }
}
