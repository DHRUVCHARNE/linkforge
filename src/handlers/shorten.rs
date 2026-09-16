use crate::app::state::AppState;
use crate::errors::app_error::AppError;
use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct CreateLinkRequest {
    pub url: String,
}

#[derive(Serialize)]
pub struct CreateLinkResponse {
    pub code: String,
    pub short_url: String,
}

pub async fn shorten(
    State(st): State<AppState>,
    Json(req): Json<CreateLinkRequest>,
) -> Result<Json<CreateLinkResponse>, AppError> {
    let link = st.shortener.create(req.url).await?;
    let code = link.code.as_str().to_string();
    Ok(Json(CreateLinkResponse { short_url: format!("http://{}/{}", st.base_url, code), code }))
}
