use axum::{extract::State, http::HeaderValue, response::IntoResponse};
use reqwest::header;

use crate::app::state::AppState;

pub async fn metrics(State(st): State<AppState>) -> impl IntoResponse {
    (
        [(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/plain; version=0.0.4; charset=utf-8"),
        )],
        st.metrics.render(),
    )
}
