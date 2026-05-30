// Submodule definitions
pub mod bytes;
mod hashes;
mod lists;
pub mod lua;
mod sets;
mod strings;
pub mod types;
pub mod zset_index;
pub mod zsets;

// Re-export public types
pub use bytes::Bytes;
pub use types::{StorageValue, ZAddOption};
pub use zset_index::Score;
pub use zsets::Aggregate;

use mlua::Lua;
use std::collections::BTreeMap;

/// Inner storage structure
pub struct StorageInner {
    pub(crate) map: BTreeMap<u64, BTreeMap<Bytes, StorageValue>>,
    pub(crate) lua: Lua,
}

impl StorageInner {
    /// Create a new empty storage with Lua VM initialized
    pub fn new() -> Self {
        StorageInner {
            map: BTreeMap::new(),
            lua: lua::new_lua(),
        }
    }

    /// Get the first (minimum) keys in the database.
    /// Returns up to count keys.
    pub fn first(&self, db: u64, count: usize) -> Vec<Bytes> {
        if count == 0 {
            return Vec::new();
        }

        let Some(db_map) = self.map.get(&db) else {
            return Vec::new();
        };

        db_map.iter().take(count).map(|(key, _)| key.clone()).collect()
    }

    /// Get the last (maximum) keys in the database in reverse order.
    /// Returns up to count keys.
    pub fn last(&self, db: u64, count: usize) -> Vec<Bytes> {
        if count == 0 {
            return Vec::new();
        }

        let Some(db_map) = self.map.get(&db) else {
            return Vec::new();
        };

        db_map.iter().rev().take(count).map(|(key, _)| key.clone()).collect()
    }

    /// Get the next keys after the given key in the database.
    /// Returns up to count keys.
    pub fn next(&self, db: u64, key: &[u8], count: usize) -> Vec<Bytes> {
        use std::ops::Bound;

        if count == 0 {
            return Vec::new();
        }

        let Some(db_map) = self.map.get(&db) else {
            return Vec::new();
        };

        db_map
            .range::<[u8], _>((Bound::Excluded(key), Bound::Unbounded))
            .take(count)
            .map(|(key, _)| key.clone())
            .collect()
    }

    /// Get the previous keys before the given key in the database in reverse order.
    /// Returns up to count keys.
    pub fn prev(&self, db: u64, key: &[u8], count: usize) -> Vec<Bytes> {
        use std::ops::Bound;

        if count == 0 {
            return Vec::new();
        }

        let Some(db_map) = self.map.get(&db) else {
            return Vec::new();
        };

        db_map
            .range::<[u8], _>((Bound::Unbounded, Bound::Excluded(key)))
            .rev()
            .take(count)
            .map(|(key, _)| key.clone())
            .collect()
    }
}
