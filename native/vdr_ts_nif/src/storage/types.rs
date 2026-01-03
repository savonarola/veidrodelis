use std::collections::{BTreeMap, BTreeSet as StdBTreeSet, HashMap};
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
    /// Member to score mapping for quick lookups
    /// Uses HashMap for O(1) average case lookups
    /// Keys are Bytes which implement Borrow<[u8]> for zero-copy lookups
    pub(crate) entries: HashMap<Bytes, Score>,
}

impl ZSet {
    pub fn new() -> Self {
        ZSet {
            index: BTreeSet::new(),
            entries: HashMap::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

/// Storage value types
pub enum StorageValue {
    String(Bytes),
    Set(StdBTreeSet<Bytes>),
    List(Vector<Bytes>),
    Hash(BTreeMap<Bytes, Bytes>),
    ZSet(ZSet),
}
