use sha2::{Digest, Sha256};
use std::net::IpAddr;
/// Truncated SHA-256 with a per-deployment salt.
///  Not reversible, and the salt prevents rainbow-table recovery of IPv4 space
/// (only 2^32 values).
pub fn hash_ip(ip: &IpAddr, salt: &str) -> String {
    let mut h = Sha256::new();
    h.update(salt.as_bytes());
    h.update(ip.to_string().as_bytes());
    let hex_string = hex::encode(h.finalize());
    hex_string[..16].to_string()
}
