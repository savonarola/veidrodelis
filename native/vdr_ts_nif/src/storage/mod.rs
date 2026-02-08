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
}
