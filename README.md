## Baseline — Phase 1 (in-memory)

Env: GitHub Codespaces, 2 vCPU · load generator co-located (see caveat)
Hot read path `GET /:code`, oha 10s, keepalive on

| c   | req/s  | p50     | p99      |
|-----|--------|---------|----------|
| 50  | 10,394 | 4.57 ms | 11.66 ms |
| 100 |  9,763 | 9.82 ms | 23.04 ms |

Correctness: 10,000 concurrent POSTs → 0 duplicate codes.

⚠️ Caveat: throughput is environment-bound at ~10k req/s. DashMap vs
RwLock<HashMap> and worker_threads 2 vs 10 produced no measurable
difference — the ceiling is CPU contention with the co-located load
generator, not application code. Treat p99 @ c=50 as the comparison
point for Phase 4, and only compare runs taken on identical hardware.
### Application-level benchmark (criterion, HTTP excluded)

`ShortenerService::lookup` (cache hit): **39.75 ns** [37.9, 41.7]

→ Application logic is 0.0004% of the 9.82 ms observed p50.
→ Theoretical single-core ceiling: ~25M lookups/sec vs ~10K req/s measured.
→ Conclusion: Phase 1 is entirely transport- and environment-bound.
   No further in-memory optimization is justified.