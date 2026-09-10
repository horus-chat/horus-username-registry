//! Relay stake book — tracks bonded stake for relay operators (incentives stub).

use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct StakeBook {
    /// relay_id → stake units
    bonds: HashMap<String, u64>,
}

impl StakeBook {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn bond(&mut self, relay_id: &str, amount: u64) -> Result<(), &'static str> {
        if relay_id.trim().is_empty() || amount == 0 {
            return Err("bad bond");
        }
        *self.bonds.entry(relay_id.to_string()).or_insert(0) += amount;
        Ok(())
    }

    pub fn unbond(&mut self, relay_id: &str, amount: u64) -> Result<(), &'static str> {
        let entry = self.bonds.get_mut(relay_id).ok_or("unknown relay")?;
        if *entry < amount {
            return Err("insufficient");
        }
        *entry -= amount;
        if *entry == 0 {
            self.bonds.remove(relay_id);
        }
        Ok(())
    }

    pub fn stake_of(&self, relay_id: &str) -> u64 {
        self.bonds.get(relay_id).copied().unwrap_or(0)
    }

    pub fn total(&self) -> u64 {
        self.bonds.values().sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bond_unbond() {
        let mut book = StakeBook::new();
        book.bond("relay-a", 100).unwrap();
        book.bond("relay-a", 50).unwrap();
        assert_eq!(book.stake_of("relay-a"), 150);
        book.unbond("relay-a", 150).unwrap();
        assert_eq!(book.stake_of("relay-a"), 0);
        assert_eq!(book.total(), 0);
    }
}
