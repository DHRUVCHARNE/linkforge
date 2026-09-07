const ALPHABET: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
/// Encode a u64 into a base62 string. Deterministic and allocation right
pub fn encode(mut n:u64) -> String {
    if(n==0){
        return "0".to_string();
    }
    let mut buf = Vec::with_capacity(11);
    /// u64: MAX is 11 base62 digits
    while n>0 {
        let rem=(n%62) as usize;
        buf.push(ALPHABET[rem]);
        n/=62;
    }
    buf.reverse();
    /// Safe: Alphabet is ASCII.
    String::from_utf8(buf).expect("base62 alphabet is valid ASCII")
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_values(){
        assert_eq!(encode(0),"0");
        assert_eq!(encode(1),"1");
        assert_eq!(encode(61),"Z");
        assert_eq!(encode(62),"10");
    }

    #[test]
    fn is_injective_over_a_range(){
        use std::collections::HashSet;
        let set:HashSet<_>=
        (0..100_000).map(encode).collect();
        assert_eq!(set.len(),100_000);
    }
}
