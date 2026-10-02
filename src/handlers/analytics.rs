use axum::{
    Json,
    extract::{Path, State},
};

use crate::{app::state::AppState, errors::app_error::AppError, services::analytics::LinkStats};

pub async fn stats(
    State(st): State<AppState>,
    Path(code): Path<String>,
) -> Result<Json<LinkStats>, AppError> {
    let stats = st.analytics.stats_for(&code).await?;
    Ok(Json(stats))
}
