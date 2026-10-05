use std::{net::SocketAddr, time::Duration};

use tokio::signal;

use crate::services::health::Readiness;

pub mod router;
pub mod state;

pub async fn serve(router: axum::Router, addr: SocketAddr,readiness:Readiness,shutdown_delay:Duration) -> anyhow::Result<()> {
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(%addr,"listening");
    axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(shutdown_signal(readiness,shutdown_delay))
        .await?;
    tracing::info!("http server stopped accepting; in-flight requests drained");
    Ok(())
}

async fn shutdown_signal(readiness:Readiness,delay:Duration) {
    let ctrl_c = async { signal::ctrl_c().await.expect("ctrl_c handler") };
    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("SIGTERM handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _= ctrl_c => tracing::info!("SIGINT received"),
        _=terminate => tracing::info!("SIGTERM received"),
    }
    readiness.start_draining();
    tracing::info!(delay_secs=delay.as_secs(),
"readiness failing; waiting before drain");
tokio::time::sleep(delay).await;
}
