use axum::{Json, Router, routing::get};
use linkforge::config;
use serde_json::json;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let settings = config::load()?;
    let app = Router::new().route(
        "/health",
        get(|| async {
            Json(json!({
                "status":"healthy",
                "status_code":200
            }))
        }),
    );
    let addr = format!("{}:{}", settings.server.host, settings.server.port);
    let listener = TcpListener::bind(&addr).await?;
    println!("Server is live at http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
