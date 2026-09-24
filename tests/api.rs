mod common;

#[path = "api/health.rs"]
mod health;

#[path = "api/redirect.rs"]
mod redirect;

#[path = "api/shorten.rs"]
mod shorten;

#[path = "phase2/cache_test.rs"]
mod cache;

#[path = "phase2/db_restart.rs"]
mod db;

#[path = "api/rate_limit.rs"]
mod rate_limit;
