use crate::cache::{Cache, InMemoryCache};
use crate::config::{ClickMode, Environment, RateLimitConfig, Settings};
use crate::middleware::rate_limit::RateLimitState;
use crate::repositories::click_repository::SqlxClickRepository;
use crate::repositories::link_repository::SqlxLinkRepository;
use crate::repositories::{ClickRepository, LinkRepository};
use crate::services::analytics::AnalyticsService;
use crate::services::{redirect::RedirectService, shortener::ShortenerService};
use crate::workers::analytics_writer::ClickSender;
use crate::workers::bucket_sweeper;
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
    pub analytics: Arc<AnalyticsService>,
    pub rate_limiter: RateLimitState,
    pub clicks: ClickSender,
    pub click_mode: ClickMode,
}

impl AppState {
    pub async fn build(settings: &Settings) -> anyhow::Result<Self> {
        let pool = crate::db::pool::create(&settings.database).await?;
        crate::db::migrations::run(&pool).await?;
        tracing::info!(click_mode=settings.analytics.click_mode.clone().as_str(), "analytics configured");

        //Resume the counter past the highest existing id otherwise a
        // restart restart reissues codes that already exist in the db
        let start_id: i64 = sqlx::query_scalar!("SELECT COALESCE(MAX(id),0) FROM links")
            .fetch_one(&pool)
            .await?
            .unwrap_or(0);
        let links: Arc<dyn LinkRepository> = Arc::new(SqlxLinkRepository::new(pool.clone()));
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
        let click_repo: Arc<dyn ClickRepository> = Arc::new(SqlxClickRepository::new(pool));
        let clicks =
            crate::workers::analytics_writer::spawn(click_repo.clone(), &settings.analytics);
        let analytics = Arc::new(AnalyticsService::new(click_repo.clone(), links.clone()));
        let click_mode = settings.analytics.click_mode.clone();
        let redirect = Arc::new(RedirectService::new(
            links.clone(),
            cache.clone(),
            clicks.clone(),
            Arc::from(settings.analytics.ip_salt.as_str()),
            click_mode.clone(),
            click_repo.clone(),
        ));
        let rate_limiter = RateLimitState::from_config(&settings.rate_limit);
        let idle_ttl_secs = settings.rate_limit.idle_ttl;
        let window_secs = settings.rate_limit.window_secs;
        if idle_ttl_secs < window_secs {
            anyhow::bail!(
                "RATE_LIMIT_IDLE_TTL_SECS ({}) must be >= RATE_LIMIT_WINDOW_SECS ({}); \
                evicting a bucket mid-window resets the client's limit",
                idle_ttl_secs,
                window_secs
            );
        }
        let sweep_interval = Duration::from_secs(settings.rate_limit.sweep_interval);
        let idle_time = Duration::from_secs(idle_ttl_secs);
        bucket_sweeper::spawn(rate_limiter.clone(), sweep_interval, idle_time);
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
            analytics,
            rate_limiter,
            clicks,
            click_mode,
        })
    }
}
