use axum::http::Request;
use tower_http::request_id::{MakeRequestId, RequestId};
use uuid::Uuid;

/// Generates a UUID v4 when the client didn't supply an x-request-id.
#[derive(Clone, Default)]
pub struct MakeRequestUuid;
impl MakeRequestId for MakeRequestUuid {
    fn make_request_id<B>(&mut self, _: &Request<B>) -> Option<RequestId> {
        let id = Uuid::new_v4().to_string().parse().ok()?;
        Some(RequestId::new(id))
    }
}
