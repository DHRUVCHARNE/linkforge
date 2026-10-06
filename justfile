# ─────────────────────────────────────────────────────────────
# LinkForge — task runner
# Run `just` with no args to see all recipes.
# ─────────────────────────────────────────────────────────────

# Load variables from .env (DATABASE_URL, etc.) into every recipe
set dotenv-load:=true

# Benchmark
bench:
     cargo bench --bench redirect_bench -- --save-baseline phase2
# Show the list of available recipes when `just` is run bare
bench-compare:
      cargo bench --bench redirect_bench -- --baseline phase2
default:
    @just --list

# ─────────────────────────────── App ───────────────────────────────

# Run application
run:
    cargo run --release

# Run application with live-reload (needs cargo-watch)
watch:
    cargo watch -x run

# Build release binary
build:
    cargo build --release

# ─────────────────────────────── Quality ───────────────────────────

# Run tests
test:
    cargo test --all-features

# Format source
fmt:
    cargo fmt

# Verify formatting
fmt-check:
    cargo fmt --check

# Clippy checks
lint:
    cargo clippy --all-targets --all-features -- -D warnings

# Full CI pipeline (fmt + lint + test)
check: fmt-check lint test

# Clean build artifacts
clean:
    cargo clean

# ─────────────────────────────── Database ──────────────────────────

# Add a new migration:  just migrate-add create_links
migrate-add name:
    sqlx migrate add {{name}}

# Apply all pending migrations
migrate:
    sqlx migrate run

# Revert the last migration
migrate-revert:
    sqlx migrate revert

# Regenerate offline query cache (.sqlx/) for CI builds
prepare:
    cargo sqlx prepare

# ─────────────────────────────── Docker ────────────────────────────

# Start infrastructure only (Postgres + Redis). The app is started separately.
up:
    docker compose up -d postgres redis

# Stop containers (keeps data)
stop:
    docker compose stop

# Stop and remove containers (data survives in the volume)
down:
    docker compose down

# Stop, remove, AND wipe the data volume (fresh DB)
down-hard:
    docker compose down -v

# Fresh database + infrastructure
reset:
    docker compose down -v
    docker compose up -d postgres redis

# Run the app in a container with normal settings
up-app:
    docker compose up -d --build app

# Follow app logs
logs-app:
    docker compose logs -f app

# ─────────────────────────────── Benchmarks ────────────────────────

# Host server in bench mode. Usage: just bench-server sync|async
bench-server mode="async":
    LINKFORGE__RATE_LIMIT__REQUESTS=100000000 \
    LINKFORGE__RATE_LIMIT__WINDOW_SECS=1 \
    LINKFORGE__ANALYTICS__CLICK_MODE={{mode}} \
    cargo run --release 2>&1 | tee /tmp/run.log

# Load test against the CONTAINER in bench mode, on a fresh DB.
# Usage: just load-test sync|async
load-test mode="async": reset
    LINKFORGE__RATE_LIMIT__REQUESTS=100000000 \
    LINKFORGE__RATE_LIMIT__WINDOW_SECS=1 \
    LINKFORGE__ANALYTICS__CLICK_MODE={{mode}} \
    docker compose up -d --build app
    @echo "waiting for readiness..."
    @until curl -sf localhost:3000/health/ready >/dev/null; do sleep 0.5; done
    docker compose logs app | grep 'rate limiter configured'
    CLICK_MODE={{mode}} ./scripts/load_test.sh

bench-app:
    LINKFORGE__RATE_LIMIT__REQUESTS=100000000 \
    LINKFORGE__RATE_LIMIT__WINDOW_SECS=1 \
    docker compose up -d --build app
    @until curl -sf localhost:3000/health/ready >/dev/null; do sleep 0.5; done
    docker compose logs app | grep 'rate limiter configured'

metrics-test: bench-app
    ./scripts/metrics_test.sh