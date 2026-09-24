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
    cargo run

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

# ─────────────────────────────── Docker ────────────────────────────

# Start Postgres + Redis in the background
up:
    docker compose up -d

# Stop containers (keeps data)
stop:
    docker compose stop

# Stop and remove containers (data survives in the volume)
down:
    docker compose down

# Stop, remove, AND wipe the data volume (fresh DB)
down-hard:
    docker compose down -v

# List running containers
ps:
    docker compose ps

# List ALL containers (including crashed/exited)
ps-all:
    docker compose ps -a

# Follow Postgres logs live
logs:
    docker compose logs -f postgres

# Open a psql shell inside the Postgres container
psql:
    docker compose exec postgres psql -U app_user -d linkforge

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

# ─────────────────────────────── Workflows ─────────────────────────

# One-shot local bootstrap: start DB, wait for health, run migrations
dev: up
    @echo "Waiting for Postgres to become healthy..."
    @until docker compose exec -T postgres pg_isready -U app_user -d linkforge > /dev/null 2>&1; do sleep 1; done
    @just migrate
    @echo "✅ Stack is up and migrated. Run 'just run' to start the app."

# Load test (Phase 3 harness)
load-test:
    just down 
    just up
    LINKFORGE__RATE_LIMIT__REQUESTS=100000000 \
    LINKFORGE__RATE_LIMIT__WINDOW_SECS=1 \
    ./scripts/load_test.sh