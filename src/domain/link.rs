
use super::short_code::ShortCode;

#[derive(Debug,Clone)]
pub struct Link {
    pub code:ShortCode,
    pub target_url:String,
}

impl Link {
    pub fn new(code:ShortCode,target_url:String) -> Self {
        Self {code,target_url}
    }
}