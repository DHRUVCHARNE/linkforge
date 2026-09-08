#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ShortCode(String);

#[derive(Debug)]
pub enum DomainError {
    InvalidCode,
}

const BASE62: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

impl ShortCode {
    // The only way to construct a ShortCode - enforces charset + length
    pub fn parse(s: &str) -> Result<Self, DomainError> {
        let ok_len = (1..=10).contains(&s.len());
        let ok_charset = s.bytes().all(|b| BASE62.contains(&b));
        if ok_len && ok_charset { Ok(Self(s.to_string())) } else { Err(DomainError::InvalidCode) }
    }
    /// Trusted constructor for codes we generate (base62 guarantees validity).
    pub(crate) fn from_generated(s: String) -> Self {
        Self(s)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Some basic unit tests
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reject_empty_and_bad_charset() {
        assert!(ShortCode::parse("").is_err());
        assert!(ShortCode::parse("has space").is_err());
        assert!(ShortCode::parse("under_score").is_err());
    }
    #[test]
    fn accept_valid_base62() {
        assert!(ShortCode::parse("aZ09").is_ok());
    }
}
