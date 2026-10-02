use std::net::SocketAddr;

use axum::{
    extract::{ConnectInfo, Path, State},
    response::Redirect,
};

use crate::app::state::AppState;
use crate::errors::app_error::AppError;

pub async fn redirect(
    State(st): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Path(code): Path<String>,
) -> Result<Redirect, AppError> {
    let target = st.redirect.resolve(&code, Some(addr.ip())).await?;
    //302 Found: browsers won't cache the mapping (better while iterating)
    // Switch to Redirect::permanent(308) once codes are truly immutable
    Ok(Redirect::temporary(&target))
}
