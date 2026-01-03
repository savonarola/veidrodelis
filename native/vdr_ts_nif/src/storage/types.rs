use std::collections::{BTreeMap, BTreeSet as StdBTreeSet};
use indexset::BTreeSet;
use im::Vector;
use super::bytes::Bytes;
use super::zset_index::{Score, ZSetIndexKey};

/// Sorted set (zset) data structure
/// Maintains both a sorted index and a member->score map for efficient operations
pub struct ZSet {
    /// Sorted index for range queries and sorted iteration
    /// Uses indexset::BTreeSet for efficient rank and range operations
    /// Ordered by ZSetIndexKey which contains ZSetIndexKeyRef for zero-copy lookups
    pub(crate) index: BTreeSet<ZSetIndexKey>,
    /// Member to score mapping for quick lookups and lexicographic range queries
    /// Uses BTreeMap for O(log n) lookups and efficient range operations
    /// Keys are Bytes which implement Borrow<[u8]> for zero-copy lookups
    pub(crate) entries: BTreeMap<Bytes, Score>,
}

impl ZSet {
    pub fn new() -> Self {
        ZSet {
            index: BTreeSet::new(),
            entries: BTreeMap::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

/// ZADD command options
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZAddOption {
    /// NX: Only add new elements, don't update existing ones
    NX,
    /// XX: Only update existing elements, don't add new ones
    XX,
    /// GT: Only update if new score > current score
    GT,
    /// LT: Only update if new score < current score
    LT,
    /// CH: Return count of elements changed (not just added)
    CH,
    /// INCR: Increment the score instead of setting it
    INCR,
}

/// Storage value types
pub enum StorageValue {
    String(Bytes),
    Set(StdBTreeSet<Bytes>),
    List(Vector<Bytes>),
    Hash(BTreeMap<Bytes, Bytes>),
    ZSet(ZSet),
}
