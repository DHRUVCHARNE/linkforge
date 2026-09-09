// benches/redirect_bench.rs
use criterion::{black_box, criterion_group, criterion_main, Criterion};
use linkforge::services::shortener::ShortenerService;

fn bench_lookup(c: &mut Criterion) {
    let svc = ShortenerService::new();
    let link = svc.create("https://example.com".into()).unwrap();
    let code = link.code.clone();

    c.bench_function("lookup_hit", |b| {
        b.iter(|| black_box(svc.lookup(black_box(&code))))
    });
}

criterion_group!(benches, bench_lookup);
criterion_main!(benches);
