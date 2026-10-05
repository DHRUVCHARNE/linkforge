use linkforge::{app, config};
use std::net::SocketAddr;
#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> anyhow::Result<()> {
    let settings = config::load()?;
    let _guard = linkforge::observability::tracing::init(&settings);
    let metrics = linkforge::observability::metrics::init()?;
    let (state, workers) = app::state::AppState::build(&settings, metrics).await?;
    let readiness=state.health.readiness_handle();
    let router = app::router::create(state);
    let addr: SocketAddr = format!("{}:{}", settings.server.host, settings.server.port).parse()?;
    app::serve(router, addr,readiness,settings.server.shutdown_delay()).await?;
    workers.shutdown().await;
    tracing::info!("shutdown complete");
    Ok(())
}
