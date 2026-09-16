pub mod redis_cache;

use async_trait::async_trait;
use dashmap::DashMap;
use sqlx::encode::IsNull::No;
use std::{
    sync::{Arc, atomic::{AtomicU64, Ordering}}, time::{Duration, Instant},
};

use crate::domain::short_code::ShortCode;

#[derive(Debug, Clone)]
pub enum Cached {
    Hit(Arc<str>),
    Missing,
}
#[async_trait]
pub trait Cache: Send + Sync {
    async fn get(&self, code: &ShortCode) -> Option<Cached>;
    async fn set(&self, code: ShortCode, url: Arc<str>);
    async fn invalidate(&self, code: &ShortCode);
    async fn set_missing(&self, code: ShortCode); //Negative caching to avoid cache stampede
    //Snapshot of lookup counters. Not synchronized -values may be
    //momentarily inconsistent with each other, which is fine for a metric
    fn stats(&self) -> CacheStats;
}

//Phase 2 implementation: process-local, unbounded, no different impl
//Phase 6 replaces this with redis cace and lua scripts -same trait different impl
#[derive(Clone)]
struct Entry {
    value: Option<Arc<str>>,     //None = known-missing
    expires_at: Option<Instant>, // None= never expires
}

pub struct InMemoryCache {
    map: DashMap<ShortCode, Entry>,
    negative_ttl: Duration,
    hits: AtomicU64,
    negative_hits: AtomicU64,
    misses: AtomicU64,
}

impl InMemoryCache {
    pub fn new(negative_ttl: Duration) -> Self {
        Self {
            map: DashMap::new(),
            negative_ttl,
            hits: AtomicU64::new(0),
            negative_hits: AtomicU64::new(0),
            misses: AtomicU64::new(0),
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct CacheStats {
    pub hits: u64,
    pub negative_hits: u64,
    pub misses: u64,
}

impl CacheStats {
    pub fn total(&self) -> u64 {
        self.hits+self.negative_hits + self.misses
    }
    // Fraction of lookups without touching the database
    pub fn hit_ratio(&self) -> f64 {
        let total = self.total();
        if total==0 {
            return 0.0;
        }
        (self.hits+self.negative_hits) as f64 / total as f64
    }
}

#[async_trait]
impl Cache for InMemoryCache {
    async fn get(&self, code: &ShortCode) -> Option<Cached> {
        //Clone out and drop the guard immedeately - never hold the dashmap
        // reference acroxx an await point.
        let entry = match self.map.get(code).map(|e| e.value().clone()) {
            Some(e)=>e,
            None=>{
                self.misses.fetch_add(1,Ordering::Relaxed);
                return None;
            }
        };
        if let Some(exp) = entry.expires_at
            && Instant::now() >= exp
        {
            self.map.remove(code);
            self.misses.fetch_add(1,Ordering::Relaxed);
            return None; //lazy eviction
        }
        Some(match &entry.value {
            Some(url) =>{
                self.hits.fetch_add(1, Ordering::Relaxed);
                Cached::Hit(url.clone())
            },
            None =>{
                self.negative_hits.fetch_add(1,Ordering::Relaxed);
                Cached::Missing
            },
        })
    }
    async fn set(&self, code: ShortCode, url: Arc<str>) {
        self.map.insert(code, Entry { value: Some(url), expires_at: None });
    }
    async fn invalidate(&self, code: &ShortCode) {
        self.map.remove(code);
    }
    async fn set_missing(&self, code: ShortCode) {
        self.map.insert(
            code,
            Entry { value: None, expires_at: Some(Instant::now() + self.negative_ttl) },
        );
    }
    fn stats(&self) -> CacheStats {
        CacheStats { hits: self.hits.load(Ordering::Relaxed),
             negative_hits: self.negative_hits.load(Ordering::Relaxed),
              misses: self.misses.load(Ordering::Relaxed) }
    }
}
