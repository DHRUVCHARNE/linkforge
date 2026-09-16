use crate::cache::{Cache, Cached};
use crate::domain::short_code::ShortCode;
use crate::errors::app_error::AppError;
use crate::repositories::LinkRepository;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, broadcast};

type FlightResult = Result<Option<Arc<str>>, ()>;

pub struct RedirectService {
    links: Arc<dyn LinkRepository>,
    cache: Arc<dyn Cache>,
    inflight: Mutex<HashMap<ShortCode, broadcast::Sender<FlightResult>>>,
}

impl RedirectService {
    pub fn new(links: Arc<dyn LinkRepository>, cache: Arc<dyn Cache>) -> Self {
        Self { links, cache, inflight: Mutex::new(HashMap::new()) }
    }
    pub async fn resolve(&self, raw_code: &str) -> Result<Arc<str>, AppError> {
        // untrusted input from the URL path -> validate through the domain
        let code = ShortCode::parse(raw_code).map_err(|_| AppError::NotFound)?;
        // 1. Cache hit - fast path. including negative entries
        match self.cache.get(&code).await {
            Some(Cached::Hit(url)) => return Ok(url),
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
                    Ok(Ok(Some(url))) => Ok(url),
                    Ok(Ok(None)) => Err(AppError::NotFound),
                    Ok(Err(())) | Err(_) => {
                        // Leader failed or dropped - fallback to your own query.
                        self.query_and_fill(&code).await
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
        outcome
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
