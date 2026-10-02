use super::short_code::ShortCode;
use chrono::{DateTime, Utc};

/// A Single redirect event. Deliberately small and `Clone` thousands of
/// these move through a channel per second
#[derive(Debug, Clone)]
pub struct Click {
    pub code: ShortCode,
    pub ts: DateTime<Utc>,
    /// Hashed, never raw. A raw IP in an analytics table is a privacy liability;
    /// the hash preserves uniqueness for counting without storing an identifier.
    pub ip_hash: Option<String>,
}

impl Click {
    pub fn new(code: ShortCode, ip_hash: Option<String>) -> Self {
        Self { code, ts: Utc::now(), ip_hash }
    }
}
