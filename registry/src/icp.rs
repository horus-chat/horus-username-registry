//! Optional ICP registry client (local dfx). Messages never go on-chain.
//! Canister stores nullifier → commitment + optional contact (never plaintext pubkey map).

use std::fs;
use std::path::Path;
use std::process::Command;

/// Read canister id written by `deploy_local.sh`.
pub fn read_canister_id(canister_dir: &Path) -> Option<String> {
    let p = canister_dir.join(".canister_id");
    fs::read_to_string(p)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Claim with precomputed nullifier + commitment (client hashes username locally).
pub fn dfx_claim(
    nullifier_hex: &str,
    commitment_hex: &str,
    findable: bool,
    contact: Option<&str>,
) -> Result<(), String> {
    let contact_candid = match contact {
        Some(c) => format!("opt \"{c}\""),
        None => "null".into(),
    };
    let findable_c = if findable { "true" } else { "false" };
    let arg = format!(
        "(\"{nullifier_hex}\", \"{commitment_hex}\", {findable_c}, {contact_candid})"
    );
    let out = Command::new("dfx")
        .args([
            "canister",
            "call",
            "username_registry",
            "claim",
            &arg,
            "--network",
            "local",
        ])
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).into_owned())
    }
}

pub fn dfx_is_taken(nullifier_hex: &str) -> Result<bool, String> {
    let out = Command::new("dfx")
        .args([
            "canister",
            "call",
            "username_registry",
            "isTaken",
            &format!("(\"{nullifier_hex}\")"),
            "--network",
            "local",
        ])
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).into_owned());
    }
    let text = String::from_utf8_lossy(&out.stdout);
    Ok(text.contains("true"))
}

/// Resolve contact blob if findable.
pub fn dfx_resolve(nullifier_hex: &str) -> Result<Option<String>, String> {
    let out = Command::new("dfx")
        .args([
            "canister",
            "call",
            "username_registry",
            "resolve",
            &format!("(\"{nullifier_hex}\")"),
            "--network",
            "local",
        ])
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).into_owned());
    }
    let text = String::from_utf8_lossy(&out.stdout);
    if text.contains("null") && !text.contains("opt \"") {
        return Ok(None);
    }
    if let Some(start) = text.find('"') {
        if let Some(end) = text[start + 1..].find('"') {
            return Ok(Some(text[start + 1..start + 1 + end].to_string()));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn missing_canister_id_is_none() {
        let dir = PathBuf::from("/tmp/horus-no-canister-dir-xyz");
        assert!(read_canister_id(&dir).is_none());
    }
}
