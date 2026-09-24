use crate::cache::{Cache, InMemoryCache};
use crate::config::{Environment, RateLimitConfig, Settings};
use crate::repositories::LinkRepository;
use crate::repositories::link_repository::SqlxLinkRepository;
use crate::services::{redirect::RedirectService, shortener::ShortenerService};
use std::sync::Arc;
use std::time::Duration;

#[derive(Clone)]
pub struct AppState {
    pub shortener: Arc<ShortenerService>,
    pub redirect: Arc<RedirectService>,
    pub base_url: Arc<str>,
    pub cache: Arc<dyn Cache>,
    pub links: Arc<dyn LinkRepository>,
    pub debug_routes: bool,
    pub rate_limit: RateLimitConfig,
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
        let cache_for_stats = cache.clone();
        let links_for_stats = links.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(30));
            loop {
                ticker.tick().await;
                let s = cache_for_stats.stats();
                if s.total() > 0 {
                    tracing::info!(
                        hit_ratio = s.hit_ratio(),
                        hits = s.hits,
                        negative_hits = s.negative_hits,
                        misses = s.misses,
                        db_queries = links_for_stats.query_count(),
                        "cache stats"
                    );
                }
            }
        });
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
            rate_limit: settings.rate_limit.clone(),
        })
    }
}
