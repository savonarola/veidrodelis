// Submodule definitions
pub mod bytes;
pub mod zset_index;
pub mod types;
pub mod zsets;
pub mod lua;
mod strings;
mod sets;
mod lists;
mod hashes;

// Re-export public types
pub use bytes::Bytes;
pub use zset_index::Score;
pub use types::StorageValue;
pub use zsets::Aggregate;

// Internal re-exports for use within the storage module
pub(crate) use zset_index::{ZSetIndexKey, ZSetIndexKeyRef};
pub(crate) use types::ZSet;

use std::collections::BTreeMap;
use mlua::Lua;

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
