//! Privacy-first username registry: commitments + uniqueness, never messages.
//!
//! On-chain / relay store only:
//! - nullifier = SHA256("horus-nullifier-v1" ‖ username)  → uniqueness
//! - commitment = SHA256("horus-commit-v1" ‖ username ‖ salt ‖ findable ‖ contact)
//! - optional contact blob (burnable invite) when findable
//!
//! Never stores a long-term public key as a public directory value.

mod icp;
mod spam;
mod stake;

pub use icp::{dfx_claim, dfx_is_taken, dfx_resolve, read_canister_id};
pub use spam::{RateLimitError, RateLimiter};
pub use stake::StakeBook;

use sha2::{Digest, Sha256};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

const NULLIFIER_DOMAIN: &[u8] = b"horus-nullifier-v1";
const COMMIT_DOMAIN: &[u8] = b"horus-commit-v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegistryEntry {
    pub nullifier_hex: String,
    pub commitment_hex: String,
    pub findable: bool,
    /// Burnable invite / sealed intro — only when findable. Not a permanent pubkey map.
    pub contact_blob: Option<String>,
}

#[derive(Debug, Default)]
pub struct Registry {
    /// Keyed by nullifier hex (opaque on the wire / chain).
    entries: HashMap<String, RegistryEntry>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum RegistryError {
    BadUsername,
    BadSalt,
    BadContact,
    Taken,
    NotFound,
    BadCommitment,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Reserve `@username`. `contact_blob` required when `findable` (invite URI for resolve).
    pub fn claim(
        &mut self,
        username: &str,
        salt: &[u8],
        findable: bool,
        contact_blob: Option<&str>,
    ) -> Result<RegistryEntry, RegistryError> {
        let name = normalize(username).ok_or(RegistryError::BadUsername)?;
        if salt.is_empty() || salt.len() > 64 {
            return Err(RegistryError::BadSalt);
        }
        let contact = normalize_contact(findable, contact_blob)?;
        let nullifier_hex = nullifier_hex(&name);
        if self.entries.contains_key(&nullifier_hex) {
            return Err(RegistryError::Taken);
        }
        let commitment_hex = commitment_hex(&name, salt, findable, contact.as_deref());
        let entry = RegistryEntry {
            nullifier_hex: nullifier_hex.clone(),
            commitment_hex,
            findable,
            contact_blob: contact,
        };
        self.entries.insert(nullifier_hex, entry.clone());
        Ok(entry)
    }

    /// Update findable flag / contact. Must present the same salt used at claim.
    pub fn update_contact(
        &mut self,
        username: &str,
        salt: &[u8],
        findable: bool,
        contact_blob: Option<&str>,
    ) -> Result<(), RegistryError> {
        let name = normalize(username).ok_or(RegistryError::BadUsername)?;
        let nullifier_hex = nullifier_hex(&name);
        let entry = self
            .entries
            .get(&nullifier_hex)
            .ok_or(RegistryError::NotFound)?
            .clone();
        if !opens_commitment(&entry, &name, salt) {
            return Err(RegistryError::BadCommitment);
        }
        let contact = normalize_contact(findable, contact_blob)?;
        let commitment_hex = commitment_hex(&name, salt, findable, contact.as_deref());
        self.entries.insert(
            nullifier_hex.clone(),
            RegistryEntry {
                nullifier_hex,
                commitment_hex,
                findable,
                contact_blob: contact,
            },
        );
        Ok(())
    }

    pub fn is_taken(&self, username: &str) -> bool {
        normalize(username)
            .map(|n| self.entries.contains_key(&nullifier_hex(&n)))
            .unwrap_or(false)
    }

    /// Returns contact blob only when the handle is findable. Never returns a pubkey directory.
    pub fn resolve(&self, username: &str) -> Option<&str> {
        let name = normalize(username)?;
        let entry = self.entries.get(&nullifier_hex(&name))?;
        if !entry.findable {
            return None;
        }
        entry.contact_blob.as_deref()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn entries(&self) -> Vec<RegistryEntry> {
        self.entries.values().cloned().collect()
    }

    pub fn load_entries(&mut self, entries: impl IntoIterator<Item = RegistryEntry>) {
        for e in entries {
            if e.nullifier_hex.len() == 64 {
                self.entries.insert(e.nullifier_hex.clone(), e);
            }
        }
    }

    /// Low-level claim with precomputed nullifier/commitment (ICP / remote clients).
    pub fn claim_precomputed(
        &mut self,
        nullifier_hex: &str,
        commitment_hex: &str,
        findable: bool,
        contact_blob: Option<&str>,
    ) -> Result<(), RegistryError> {
        if nullifier_hex.len() != 64 || !nullifier_hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(RegistryError::BadCommitment);
        }
        if commitment_hex.len() != 64 || !commitment_hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(RegistryError::BadCommitment);
        }
        if self.entries.contains_key(nullifier_hex) {
            return Err(RegistryError::Taken);
        }
        let contact = normalize_contact(findable, contact_blob)?;
        self.entries.insert(
            nullifier_hex.to_ascii_lowercase(),
            RegistryEntry {
                nullifier_hex: nullifier_hex.to_ascii_lowercase(),
                commitment_hex: commitment_hex.to_ascii_lowercase(),
                findable,
                contact_blob: contact,
            },
        );
        Ok(())
    }

    pub fn is_taken_nullifier(&self, nullifier_hex: &str) -> bool {
        self.entries
            .contains_key(&nullifier_hex.to_ascii_lowercase())
    }

    pub fn resolve_nullifier(&self, nullifier_hex: &str) -> Option<&str> {
        let entry = self.entries.get(&nullifier_hex.to_ascii_lowercase())?;
        if !entry.findable {
            return None;
        }
        entry.contact_blob.as_deref()
    }
}

fn opens_commitment(entry: &RegistryEntry, name: &str, salt: &[u8]) -> bool {
    entry.commitment_hex
        == commitment_hex(name, salt, entry.findable, entry.contact_blob.as_deref())
}

fn normalize_contact(
    findable: bool,
    contact_blob: Option<&str>,
) -> Result<Option<String>, RegistryError> {
    match (findable, contact_blob.map(str::trim).filter(|s| !s.is_empty())) {
        (true, Some(c)) => {
            if c.len() < 8 || c.len() > 8192 {
                return Err(RegistryError::BadContact);
            }
            Ok(Some(c.to_string()))
        }
        (true, None) => Err(RegistryError::BadContact),
        (false, _) => Ok(None),
    }
}

pub fn normalize(username: &str) -> Option<String> {
    let s = username.trim().trim_start_matches('@').to_ascii_lowercase();
    if s.len() < 3 || s.len() > 32 {
        return None;
    }
    if !s
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
    {
        return None;
    }
    if s.starts_with('_') || s.ends_with('_') {
        return None;
    }
    Some(s)
}

pub fn nullifier_hex(normalized_username: &str) -> String {
    let mut h = Sha256::new();
    h.update(NULLIFIER_DOMAIN);
    h.update(normalized_username.as_bytes());
    to_hex(&h.finalize())
}

pub fn commitment_hex(
    normalized_username: &str,
    salt: &[u8],
    findable: bool,
    contact: Option<&str>,
) -> String {
    let mut h = Sha256::new();
    h.update(COMMIT_DOMAIN);
    h.update(normalized_username.as_bytes());
    h.update(salt);
    h.update([u8::from(findable)]);
    if let Some(c) = contact {
        h.update(c.as_bytes());
    }
    to_hex(&h.finalize())
}

fn to_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0xf) as usize] as char);
    }
    out
}

pub fn nullifier_for_username(username: &str) -> Option<String> {
    normalize(username).map(|n| nullifier_hex(&n))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claim_taken_and_resolve_findable() {
        let mut r = Registry::new();
        let salt = b"salt-one-aaaaaaaa";
        let invite = "horus://invite/testdata";
        r.claim("alice", salt, true, Some(invite)).unwrap();
        assert!(r.is_taken("Alice"));
        assert_eq!(r.resolve("alice"), Some(invite));
        assert_eq!(
            r.claim("alice", salt, true, Some(invite)),
            Err(RegistryError::Taken)
        );
    }

    #[test]
    fn not_findable_resolve_is_none() {
        let mut r = Registry::new();
        r.claim("bob", b"salt-two-bbbbbbbb", false, None).unwrap();
        assert!(r.is_taken("bob"));
        assert_eq!(r.resolve("bob"), None);
    }

    #[test]
    fn update_contact_requires_salt() {
        let mut r = Registry::new();
        let salt = b"salt-three-cccccc";
        r.claim("carol", salt, false, None).unwrap();
        assert_eq!(
            r.update_contact("carol", b"wrong-salt-xxxxxx", true, Some("horus://invite/x")),
            Err(RegistryError::BadCommitment)
        );
        r.update_contact("carol", salt, true, Some("horus://invite/x"))
            .unwrap();
        assert_eq!(r.resolve("carol"), Some("horus://invite/x"));
    }

    #[test]
    fn persist_roundtrip() {
        let mut r = Registry::new();
        r.claim("dave", b"salt-four-dddddddd", true, Some("horus://invite/d"))
            .unwrap();
        let snap = r.entries();
        let mut r2 = Registry::new();
        r2.load_entries(snap);
        assert!(r2.is_taken("dave"));
        assert_eq!(r2.resolve("dave"), Some("horus://invite/d"));
    }

    #[test]
    fn rejects_bad_username() {
        let mut r = Registry::new();
        assert_eq!(
            r.claim("ab", b"salt", false, None),
            Err(RegistryError::BadUsername)
        );
    }
}
