use reqwest::Url;

use crate::cache::Cache;
use crate::domain::{link::Link, short_code::ShortCode};
use crate::errors::app_error::AppError;
use crate::repositories::LinkRepository;
use crate::utils::base62;
use std::net::IpAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// Ranges that must never be a redirect target: RFC1918 private space,
/// link-local (incl. the 169.254.169.254 cloud metadata endpoint),
/// carrier-grade NAT, and IPv6 unique-local / link-local.
fn is_private(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_private()            // 10/8, 172.16/12, 192.168/16
                || v4.is_link_local()  // 169.254/16  <- metadata endpoint
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.octets()[0] == 100 && (v4.octets()[1] & 0xC0) == 64 // 100.64/10 CGNAT
                || v4.octets()[0] == 0
        }
        IpAddr::V6(v6) => {
            let seg = v6.segments();
            (seg[0] & 0xfe00) == 0xfc00     // fc00::/7 unique local
                || (seg[0] & 0xffc0) == 0xfe80 // fe80::/10 link local
                || v6.to_ipv4_mapped().map(|m| is_private(&IpAddr::V4(m))).unwrap_or(false)
        }
    }
}
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
        let start = std::time::Instant::now();
        let result = self.links.create(&link).await;
        tracing::debug!(elapsed_us = start.elapsed().as_micros(), "db_insert");
        if let Err(ref e) = result {
            tracing::error!(error = ?e,"link creation failed");
        }
        // Warm the cache only after the DB commit succeeded
        self.cache.set(code, Arc::from(url.as_str())).await;
        Ok(link)
    }

    fn validate_url(url: String) -> Result<String, AppError> {
        let parsed = Url::parse(url.trim()).map_err(|_| AppError::InvalidUrl)?;
        match parsed.scheme() {
            "http" | "https" => {}
            _ => return Err(AppError::InvalidUrl),
        }
        let host = parsed.host_str().ok_or(AppError::InvalidUrl)?;
        // Block loopback, link-local, and private ranges.
        if host == "localhost" || host.ends_with(".localhost") {
            return Err(AppError::InvalidUrl);
        }
        if let Ok(ip) = host.parse::<std::net::IpAddr>()
            && (ip.is_loopback() || ip.is_unspecified() || is_private(&ip))
        {
            return Err(AppError::InvalidUrl);
        }
        Ok(parsed.to_string())
    }
}
