use crate::cache::{Cache, Cached};
use crate::config::ClickMode;
use crate::domain::click::Click;
use crate::domain::short_code::ShortCode;
use crate::errors::app_error::AppError;
use crate::repositories::{ClickRepository, LinkRepository};
use crate::utils::hash::hash_ip;
use crate::workers::analytics_writer::ClickSender;
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use tokio::sync::{Mutex, broadcast};

type FlightResult = Result<Option<Arc<str>>, ()>;

pub struct RedirectService {
    links: Arc<dyn LinkRepository>,
    cache: Arc<dyn Cache>,
    inflight: Mutex<HashMap<ShortCode, broadcast::Sender<FlightResult>>>,
    clicks: ClickSender,
    ip_salt: Arc<str>,
    click_repo: Arc<dyn ClickRepository>, //used only in sync mode
    click_mode: ClickMode,
}

impl RedirectService {
    pub fn new(
        links: Arc<dyn LinkRepository>,
        cache: Arc<dyn Cache>,
        clicks: ClickSender,
        ip_salt: Arc<str>,
        click_mode: ClickMode,
        click_repo: Arc<dyn ClickRepository>,
    ) -> Self {
        Self {
            links,
            cache,
            inflight: Mutex::new(HashMap::new()),
            clicks,
            ip_salt,
            click_mode,
            click_repo,
        }
    }
    pub async fn resolve(&self, raw_code: &str, ip: Option<IpAddr>) -> Result<Arc<str>, AppError> {
        let (code, url) = self.lookup(raw_code).await?;
        //Fire-and-forget: try_send never awaits, so the redirect path
        //pays nanoseconds, not a DB round trip.
        let ip_hash = ip.map(|i| hash_ip(&i, &self.ip_salt));
        let click = Click::new(code, ip_hash);
        match self.click_mode {
            //Async: fire and forget. The redirect pays nanoseconds.
            ClickMode::Async => self.clicks.record(click),
            //The redirect waits for the INSERT this is the baseline
            //Phase 4 must beat. A failed write is logged, never surfaced:
            // A Broken analytics table must not break redirects.
            ClickMode::Sync => {
                if let Err(e) = self.click_repo.insert_batch(std::slice::from_ref(&click)).await {
                    tracing::error!(error=?e, "sync click insert failed");
                }
            }
        }
        Ok(url)
    }
    ///Pure lookup: cache -> single-flight -> DB
    async fn lookup(&self, raw_code: &str) -> Result<(ShortCode, Arc<str>), AppError> {
        // untrusted input from the URL path -> validate through the domain
        let code = ShortCode::parse(raw_code).map_err(|_| AppError::NotFound)?;
        // 1. Cache hit - fast path. including negative entries
        match self.cache.get(&code).await {
            Some(Cached::Hit(url)) => return Ok((code, url)),
            Some(Cached::Missing) => return Err(AppError::NotFound), // No db hit
            None => {}                                               //unknown, fall through
        }
        // 2. Miss . Either become the leader or subscribe to an existing flight.
        let leader_tx = {
            let mut inflight = self.inflight.lock().await;
            if let Some(tx) = inflight.get(&code) {
                //Someone else is already querying - wait for the result
                let mut rx = tx.subscribe();
                drop(inflight);
                return match rx.recv().await {
                    Ok(Ok(Some(url))) => Ok((code.clone(), url)),
                    Ok(Ok(None)) => Err(AppError::NotFound),
                    Ok(Err(())) | Err(_) => {
                        // Leader failed or dropped - fallback to your own query.
                        Ok((code.clone(), self.query_and_fill(&code).await?))
                    }
                };
            }
            //We are the leader. Register the flight
            let (tx, _) = broadcast::channel(1);
            inflight.insert(code.clone(), tx.clone());
            tx
        }; // Lock dropped here - critical: never hold it across the DB call
        // 3. Leader does the actual work
        let outcome = self.query_and_fill(&code).await;
        // 4. Deregister BEFORE broadcating, so late arrivals start a fresh flight
        self.inflight.lock().await.remove(&code);
        let shared: FlightResult = match &outcome {
            Ok(url) => Ok(Some(url.clone())),
            Err(AppError::NotFound) => Ok(None),
            Err(_) => Err(()),
        };
        let _ = leader_tx.send(shared); //Err just means none was waiting
        outcome.map(|url| (code, url))
    }
    async fn query_and_fill(&self, code: &ShortCode) -> Result<Arc<str>, AppError> {
        match self.links.find_by_code(code).await? {
            Some(link) => {
                let url: Arc<str> = Arc::from(link.target_url.as_str());
                self.cache.set(code.clone(), url.clone()).await;
                Ok(url)
            }
            None => {
                self.cache.set_missing(code.clone()).await;
                Err(AppError::NotFound)
            }
        }
    }
}
