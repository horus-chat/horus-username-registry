//! Simple per-key rate limiter (spam protection without linking identities on-chain).

use std::collections::HashMap;
use std::time::{Duration, Instant};

#[derive(Debug)]
pub struct RateLimiter {
    window: Duration,
    max_per_window: u32,
    hits: HashMap<String, (Instant, u32)>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum RateLimitError {
    Limited,
}

impl RateLimiter {
    pub fn new(window: Duration, max_per_window: u32) -> Self {
        Self {
            window,
            max_per_window,
            hits: HashMap::new(),
        }
    }

    /// `key` should be an opaque queue id or hashed pubkey — never plaintext.
    pub fn check(&mut self, key: &str) -> Result<(), RateLimitError> {
        let now = Instant::now();
        let entry = self.hits.entry(key.to_string()).or_insert((now, 0));
        if now.duration_since(entry.0) > self.window {
            *entry = (now, 0);
        }
        if entry.1 >= self.max_per_window {
            return Err(RateLimitError::Limited);
        }
        entry.1 += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_then_limits() {
        let mut rl = RateLimiter::new(Duration::from_secs(60), 2);
        assert!(rl.check("q").is_ok());
        assert!(rl.check("q").is_ok());
        assert_eq!(rl.check("q"), Err(RateLimitError::Limited));
        assert!(rl.check("other").is_ok());
    }
}
