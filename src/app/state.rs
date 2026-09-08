use crate::config::Settings;
use crate::services::{redirect::RedirectService, shortener::ShortenerService};
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub shortener: Arc<ShortenerService>,
    pub redirect: Arc<RedirectService>,
    pub base_url: Arc<str>,
}

impl AppState {
    pub fn build(settings: &Settings) -> Self {
        let shortener = Arc::new(ShortenerService::new());
        let redirect = Arc::new(RedirectService::new(shortener.clone()));
        let base_url: Arc<str> =
            format!("http://{}:{}", settings.server.host, settings.server.port).into();
        Self { shortener, redirect, base_url }
    }
}
