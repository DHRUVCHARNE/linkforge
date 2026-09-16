// benches/redirect_bench.rs
use std::sync::Arc;
use std::time::Duration;

use criterion::{Criterion, black_box, criterion_group, criterion_main};

use linkforge::cache::{Cache, InMemoryCache};
use linkforge::domain::{link::Link, short_code::ShortCode};
use linkforge::repositories::LinkRepository;
use linkforge::repositories::link_repository::SqlxLinkRepository;

fn bench_cache_hit(c: &mut Criterion) {
    let rt = tokio::runtime::Builder::new_current_thread().build().expect("runtime");

    let cache = InMemoryCache::new(Duration::from_secs(30));
    let code = ShortCode::parse("abc123").expect("valid code");
    rt.block_on(cache.set(code.clone(), Arc::from("https://example.com")));

    c.bench_function("cache_hit", |b| {
        b.iter(|| rt.block_on(async { black_box(cache.get(black_box(&code)).await) }))
    });
}

fn bench_db_miss(c: &mut Criterion) {
    // Skip rather than panic when no database is available (CI, offline builds).
    let Ok(url) = std::env::var("DATABASE_URL") else {
        eprintln!("skipping db_find_by_code — DATABASE_URL not set");
        return;
    };

    // Multi-thread runtime here: sqlx's pool spawns background tasks.
    let rt = tokio::runtime::Runtime::new().expect("runtime");

    let Ok(pool) = rt.block_on(sqlx::postgres::PgPool::connect(&url)) else {
        eprintln!("skipping db_find_by_code — could not connect to {url}");
        return;
    };
    let repo = SqlxLinkRepository::new(pool);

    // Seed once. Ignore the duplicate error on repeat runs.
    let code = ShortCode::parse("bench1").expect("valid code");
    let link = Link::new(code.clone(), "https://example.com".to_string());
    let _ = rt.block_on(repo.create(&link));

    c.bench_function("db_find_by_code", |b| {
        b.iter(|| rt.block_on(async { black_box(repo.find_by_code(black_box(&code)).await) }))
    });
}

criterion_group!(benches, bench_cache_hit, bench_db_miss);
criterion_main!(benches);
