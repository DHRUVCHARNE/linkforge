use linkforge::config;
use tokio::net::TcpListener;

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> anyhow::Result<()> {
    let settings = config::load()?;
    let state = linkforge::app::state::AppState::build(&settings).await?;
    let app = linkforge::app::router::create(state);

    let addr = format!("{}:{}", settings.server.host, settings.server.port);
    let listener = TcpListener::bind(&addr).await?;
    println!("Server is live at http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
