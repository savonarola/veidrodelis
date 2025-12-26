use std::collections::{BTreeMap, BTreeSet as StdBTreeSet, HashMap};
use std::cmp::Ordering;
use std::sync::Arc;
use im::Vector;
use indexset::BTreeSet;
use ordered_float::OrderedFloat;
use ouroboros::self_referencing;
use std::borrow::Borrow;
use std::ops::Bound;


pub type Score = OrderedFloat<f64>;

#[derive(Clone, Debug)]
pub struct Bytes(Arc<Vec<u8>>);

impl Bytes {
    fn new(data: &[u8]) -> Self {
        Bytes(Arc::new(data.to_vec()))
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl Borrow<[u8]> for Bytes {
    fn borrow(&self) -> &[u8] {
        &self.0
    }
}

impl PartialEq for Bytes {
    fn eq(&self, other: &Self) -> bool {
        self.0.as_slice() == other.0.as_slice()
    }
}

impl Eq for Bytes {}

impl PartialOrd for Bytes {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Bytes {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.as_slice().cmp(other.0.as_slice())
    }
}

impl std::hash::Hash for Bytes {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.0.as_slice().hash(state);
    }
}

enum ZSetIndexKeyRef<'a> {
    #[allow(dead_code)]
    MinKey,
    #[allow(dead_code)]
    MaxKey,
    MinScoreKey(Score),
    MaxScoreKey(Score),
    Key { score: Score, entry: &'a [u8] },
}

enum ZSetIndexKeyData {
    #[allow(dead_code)]
    MinKey,
    #[allow(dead_code)]
    MaxKey,
    MinScoreKey(Score),
    MaxScoreKey(Score),
    Key{ score: Score, entry: Bytes },
}

#[self_referencing]
struct ZSetIndexKeyN {
    data: ZSetIndexKeyData,
    #[borrows(data)]
    #[covariant]
    ref_view: ZSetIndexKeyRef<'this>,
}

impl ZSetIndexKeyN {
    fn create(score: Score, data: &[u8]) -> Self {
        ZSetIndexKeyNBuilder {
            data: ZSetIndexKeyData::Key { score: score, entry: Bytes::new(data)},
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::Key { score, entry } => ZSetIndexKeyRef::Key { score: *score, entry: entry.borrow() },
                _ => unreachable!(),
            },
        }
        .build()
    }

    fn min_score_key(score: Score) -> Self {
        ZSetIndexKeyNBuilder {
            data: ZSetIndexKeyData::MinScoreKey(score),
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::MinScoreKey(score) => ZSetIndexKeyRef::MinScoreKey(*score),
                _ => unreachable!(),
            },
        }
        .build()
    }

    fn max_score_key(score: Score) -> Self {
        ZSetIndexKeyNBuilder {
            data: ZSetIndexKeyData::MaxScoreKey(score),
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::MaxScoreKey(score) => ZSetIndexKeyRef::MaxScoreKey(*score),
                _ => unreachable!(),
            },
        }
        .build()
    }

    fn get_entry_and_score(&self) -> Option<(Bytes, Score)> {
        self.with_data(|data| {
            if let ZSetIndexKeyData::Key { score, entry } = data {
                Some((entry.clone(), *score))
            } else {
                None
            }
        })
    }
}

impl Borrow<ZSetIndexKeyRef<'static>> for ZSetIndexKeyN {
    fn borrow(&self) -> &ZSetIndexKeyRef<'static> {
        unsafe { std::mem::transmute(self.borrow_ref_view()) }
    }
}

impl<'a> ZSetIndexKeyRef<'a> {
    fn lookup_key_ref(score: Score, member: &'a [u8]) -> ZSetIndexKeyRef<'static> {
        unsafe { ZSetIndexKeyRef::Key { score, entry: std::mem::transmute(member) } }
    }
}

impl ZSetIndexKeyN {
    fn as_ref<'a>(&'a self) -> &'a ZSetIndexKeyRef<'a> {
        self.borrow_ref_view()
    }
}

// Implement ordering traits by delegating to the contained ZSetIndexKeyRef
impl PartialEq for ZSetIndexKeyN {
    fn eq(&self, other: &Self) -> bool {
        self.as_ref() == other.as_ref()
    }
}

impl Eq for ZSetIndexKeyN {}

impl PartialOrd for ZSetIndexKeyN {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ZSetIndexKeyN {
    fn cmp(&self, other: &Self) -> Ordering {
        self.as_ref().cmp(other.as_ref())
    }
}


impl<'a> PartialEq for ZSetIndexKeyRef<'a> {
    fn eq(&self, other: &Self) -> bool {
        matches!(self.cmp(other), Ordering::Equal)
    }
}

impl<'a> Eq for ZSetIndexKeyRef<'a> {}

impl<'a> PartialOrd for ZSetIndexKeyRef<'a> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<'a> Ord for ZSetIndexKeyRef<'a> {
    fn cmp(&self, other: &Self) -> Ordering {
        use ZSetIndexKeyRef::*;

        match (self, other) {
            // MinKey is less than everything except itself
            (MinKey, MinKey) => Ordering::Equal,
            (MinKey, _) => Ordering::Less,
            (_, MinKey) => Ordering::Greater,

            // MaxKey is greater than everything except itself
            (MaxKey, MaxKey) => Ordering::Equal,
            (MaxKey, _) => Ordering::Greater,
            (_, MaxKey) => Ordering::Less,

            // MinScoreKey comparisons
            (MinScoreKey(s1), MinScoreKey(s2)) => s1.cmp(s2),
            (MinScoreKey(s1), MaxScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less,  // MinScore < MaxScore for same score
                    other => other,
                }
            }
            (MinScoreKey(s1), Key { score: s2, .. }) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less,  // MinScore < Key for same score
                    other => other,
                }
            }

            // MaxScoreKey comparisons
            (MaxScoreKey(s1), MinScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater,  // MaxScore > MinScore for same score
                    other => other,
                }
            }
            (MaxScoreKey(s1), MaxScoreKey(s2)) => s1.cmp(s2),
            (MaxScoreKey(s1), Key { score: s2, .. }) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater,  // MaxScore > Key for same score
                    other => other,
                }
            }

            // Key comparisons
            (Key { score: s1, .. }, MinScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater,  // Key > MinScore for same score
                    other => other,
                }
            }
            (Key { score: s1, .. }, MaxScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less,  // Key < MaxScore for same score
                    other => other,
                }
            }
            (Key { score: s1, entry: e1 }, Key { score: s2, entry: e2 }) => {
                // First compare scores, then entries lexicographically
                match s1.cmp(s2) {
                    Ordering::Equal => e1.cmp(e2),
                    other => other,
                }
            }
        }
    }
}

/// Sorted set (zset) data structure
/// Maintains both a sorted index and a member->score map for efficient operations
pub struct ZSet {
    /// Sorted index for range queries and sorted iteration
    /// Uses indexset::BTreeSet for efficient rank and range operations
    /// Ordered by ZSetIndexKeyN which contains ZSetIndexKeyRef for zero-copy lookups
    index: BTreeSet<ZSetIndexKeyN>,
    /// Member to score mapping for quick lookups
    /// Uses HashMap for O(1) average case lookups
    /// Keys are Bytes which implement Borrow<[u8]> for zero-copy lookups
    entries: HashMap<Bytes, Score>,
}

impl ZSet {
    fn new() -> Self {
        ZSet {
            index: BTreeSet::new(),
            entries: HashMap::new(),
        }
    }

    fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn len(&self) -> usize {
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

/// Inner storage structure
pub struct StorageInner {
    map: BTreeMap<u64, BTreeMap<Bytes, StorageValue>>,
}

impl StorageInner {
    /// Create a new empty storage
    pub fn new() -> Self {
        StorageInner {
            map: BTreeMap::new(),
        }
    }

    /// Set a key-value pair in a specific database
    pub fn set(&mut self, db: u64, key: &[u8], value: &[u8]) {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
        db_map.insert(Bytes::new(key), StorageValue::String(Bytes::new(value)));
    }

    /// Get a value by key from a specific database
    pub fn get(&self, db: u64, key: &[u8]) -> Result<Option<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::String(value)) => Ok(Some(value.clone())),
            Some(StorageValue::Set(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => Ok(None),
        }
    }

    /// Delete a key from a specific database
    pub fn del(&mut self, db: u64, key: &[u8]) {
        if let Some(db_map) = self.map.get_mut(&db) {
            db_map.remove(key);
        }
    }

    /// Clear all entries from all databases
    pub fn clear(&mut self) {
        self.map.clear();
    }

    /// Add members to a set. Returns number of members actually added (excluding duplicates).
    pub fn sadd(&mut self, db: u64, key: &[u8], members: &[&[u8]]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::Set(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the set
        let set = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::Set(StdBTreeSet::new()));

        // Extract the set from the StorageValue
        let set = match set {
            StorageValue::Set(s) => s,
            _ => unreachable!(), // We already validated the type above
        };

        let mut added = 0;
        for member in members {
            if set.insert(Bytes::new(member)) {
                added += 1;
            }
        }

        Ok(added)
    }

    /// Remove members from a set. Removes key if set becomes empty.
    pub fn srem(&mut self, db: u64, key: &[u8], members: &[&[u8]]) -> Result<usize, &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(0);
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(0);
        };

        let set = match value {
            StorageValue::Set(set) => set,
            StorageValue::String(_) | StorageValue::List(_) | StorageValue::Hash(_) | StorageValue::ZSet(_) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
        };

        let mut removed = 0;
        for member in members {
            if set.remove(*member) {
                removed += 1;
            }
        }

        // Remove key if set is empty
        if set.is_empty() {
            db_map.remove(key);
        }

        Ok(removed)
    }

    /// Move a member from source to destination set. Deletes source if it becomes empty.
    pub fn smove(&mut self, db: u64, source_key: &[u8], dest_key: &[u8], member: &[u8]) -> Result<bool, &'static str> {
        // Get mutable access to database
        let db_map = match self.map.get_mut(&db) {
            Some(map) => map,
            None => return Ok(false),
        };

        // Check source type
        match db_map.get(source_key) {
            Some(StorageValue::Set(_)) => {},
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => return Ok(false),
        };

        // Remove from source using take() which returns the Arc if it exists
        let member_arc = match db_map.get_mut(source_key) {
            Some(StorageValue::Set(set)) => set.take(member),
            _ => None,
        };

        let Some(member_arc) = member_arc else {
            return Ok(false);
        };

        // Check if source set is now empty and should be deleted
        let should_delete_source = match db_map.get(source_key) {
            Some(StorageValue::Set(set)) => set.is_empty(),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) | None => false,
        };

        // Delete source if empty
        if should_delete_source {
            db_map.remove(source_key);
        }

        // Add member to destination set
        match db_map.entry(Bytes::new(dest_key)) {
            std::collections::btree_map::Entry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::Set(set) => {
                        set.insert(member_arc);
                    }
                    StorageValue::String(_) | StorageValue::List(_) | StorageValue::Hash(_) | StorageValue::ZSet(_) => {
                        return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                    }
                }
            }
            std::collections::btree_map::Entry::Vacant(e) => {
                let mut new_set = StdBTreeSet::new();
                new_set.insert(member_arc);
                e.insert(StorageValue::Set(new_set));
            }
        }

        Ok(true)
    }

    /// Store union of multiple sets in destination key.
    pub fn sunionstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[&[u8]]) -> Result<usize, &'static str> {
        // First delete destination
        self.del(db, dest_key);

        // Collect all unique members from source sets
        let mut union_set = StdBTreeSet::new();

        if let Some(db_map) = self.map.get(&db) {
            for source_key in source_keys {
                if let Some(value) = db_map.get(*source_key) {
                    match value {
                        StorageValue::Set(set) => {
                            union_set.extend(set.iter().cloned());
                        }
                        StorageValue::String(_) | StorageValue::List(_) | StorageValue::Hash(_) | StorageValue::ZSet(_) => {
                            return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                        }
                    }
                }
            }
        }

        let cardinality = union_set.len();

        // Store result if non-empty
        if !union_set.is_empty() {
            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(union_set));
        }

        Ok(cardinality)
    }

    /// Store intersection of multiple sets in destination key.
    pub fn sinterstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[&[u8]]) -> Result<usize, &'static str> {
        // First delete destination
        self.del(db, dest_key);

        if source_keys.is_empty() {
            return Ok(0);
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        // Start with first set - collect into a new set
        let mut intersection_set = match db_map.get(source_keys[0]) {
            Some(StorageValue::Set(set)) => set.iter().cloned().collect(),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => StdBTreeSet::new(),
        };

        // Intersect with remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(*source_key) {
                Some(StorageValue::Set(set)) => {
                    intersection_set = intersection_set.intersection(set).cloned().collect();
                }
                Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => {
                    // Intersection with empty set is empty
                    intersection_set.clear();
                    break;
                }
            }
        }

        let cardinality = intersection_set.len();

        // Store result if non-empty
        if !intersection_set.is_empty() {
            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(intersection_set));
        }

        Ok(cardinality)
    }

    /// Store difference of sets in destination key.
    pub fn sdiffstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[&[u8]]) -> Result<usize, &'static str> {
        // First delete destination
        self.del(db, dest_key);

        if source_keys.is_empty() {
            return Ok(0);
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        // Start with first set - collect into a new set
        let mut diff_set = match db_map.get(source_keys[0]) {
            Some(StorageValue::Set(set)) => set.iter().cloned().collect(),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => StdBTreeSet::new(),
        };

        // Subtract remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(*source_key) {
                Some(StorageValue::Set(set)) => {
                    diff_set = diff_set.difference(set).cloned().collect();
                }
                Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                    return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
                None => {
                    // Difference with empty set doesn't change result
                    continue;
                }
            }
        }

        let cardinality = diff_set.len();

        // Store result if non-empty
        if !diff_set.is_empty() {
            let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
            db_map.insert(Bytes::new(dest_key), StorageValue::Set(diff_set));
        }

        Ok(cardinality)
    }

    /// Get all members of a set.
    pub fn smembers(&self, db: u64, key: &[u8]) -> Result<Vec<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Set(set)) => Ok(set.iter().cloned().collect()),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => Ok(Vec::new()),
        }
    }

    /// Check if member exists in set.
    pub fn sismember(&self, db: u64, key: &[u8], member: &[u8]) -> Result<bool, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Set(set)) => Ok(set.contains(member)),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => Ok(false),
        }
    }

    /// Get the number of members in a set.
    pub fn scard(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Set(set)) => Ok(set.len()),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => Ok(0),
        }
    }

    // List operations

    /// Push elements to the left (head) of the list.
    pub fn lpush(&mut self, db: u64, key: &[u8], values: &[&[u8]]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the list
        let list = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::List(Vector::new()));

        // Extract the list from the StorageValue
        let list = match list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        // Push values to the front in order (each one becomes the new head)
        for value in values {
            list.push_front(Bytes::new(value));
        }

        Ok(list.len())
    }

    /// Push elements to the right (tail) of the list.
    pub fn rpush(&mut self, db: u64, key: &[u8], values: &[&[u8]]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the list
        let list = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::List(Vector::new()));

        // Extract the list from the StorageValue
        let list = match list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        // Push values to the back
        for value in values {
            list.push_back(Bytes::new(value));
        }

        Ok(list.len())
    }

    /// Pop element from the left (head) of the list. Returns the element or None.
    pub fn lpop(&mut self, db: u64, key: &[u8]) -> Result<Option<Bytes>, &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(None);
        };

        let list = match value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        if list.is_empty() {
            return Ok(None);
        }

        let popped = list.pop_front().unwrap();

        // Remove key if list is empty
        if list.is_empty() {
            db_map.remove(key);
        }

        Ok(Some(popped))
    }

    /// Pop element from the right (tail) of the list. Returns the element or None.
    pub fn rpop(&mut self, db: u64, key: &[u8]) -> Result<Option<Bytes>, &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(None);
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(None);
        };

        let list = match value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        if list.is_empty() {
            return Ok(None);
        }

        let popped = list.pop_back().unwrap();

        // Remove key if list is empty
        if list.is_empty() {
            db_map.remove(key);
        }

        Ok(Some(popped))
    }

    /// Get the length of a list.
    pub fn llen(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::List(list)) => Ok(list.len()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Get a range of elements from the list.
    /// Both start and stop are inclusive and support negative indices.
    pub fn lrange(&self, db: u64, key: &[u8], start: i64, stop: i64) -> Result<Vec<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::List(list)) => {
                let len = list.len() as i64;

                if len == 0 {
                    return Ok(Vec::new());
                }

                // Normalize negative indices
                let start_pos = if start < 0 {
                    (len + start).max(0) as usize
                } else {
                    start.min(len - 1).max(0) as usize
                };

                let stop_pos = if stop < 0 {
                    (len + stop).max(0) as usize
                } else {
                    stop.min(len - 1).max(0) as usize
                };

                if start_pos > stop_pos || start_pos >= len as usize {
                    return Ok(Vec::new());
                }

                let result: Vec<Bytes> = list
                    .iter()
                    .skip(start_pos)
                    .take(stop_pos - start_pos + 1)
                    .cloned()
                    .collect();

                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Set the list element at index to value.
    pub fn lset(&mut self, db: u64, key: &[u8], index: i64, value: &[u8]) -> Result<bool, &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(false);
        };

        let Some(storage_value) = db_map.get_mut(key) else {
            return Ok(false);
        };

        let list = match storage_value {
            StorageValue::List(list) => list,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        let len = list.len() as i64;

        // Normalize index
        let pos = if index < 0 {
            len + index
        } else {
            index
        };

        if pos < 0 || pos >= len {
            return Ok(false);
        }

        *list = list.update(pos as usize, Bytes::new(value));
        Ok(true)
    }

    /// Atomically pop from the right of source and push to the left of destination.
    pub fn rpoplpush(&mut self, db: u64, source_key: &[u8], dest_key: &[u8]) -> Result<Option<Bytes>, &'static str> {
        // Special case: same key means rotate
        if source_key == dest_key {
            let Some(db_map) = self.map.get_mut(&db) else {
                return Ok(None);
            };

            let Some(value) = db_map.get_mut(source_key) else {
                return Ok(None);
            };

            let list = match value {
                StorageValue::List(list) => list,
                _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            };

            if list.is_empty() {
                return Ok(None);
            }

            let popped = list.pop_back().unwrap();
            list.push_front(popped.clone());
            return Ok(Some(popped));
        }

        // Different keys: pop from source
        let popped = {
            let Some(db_map) = self.map.get_mut(&db) else {
                return Ok(None);
            };

            let Some(value) = db_map.get_mut(source_key) else {
                return Ok(None);
            };

            let list = match value {
                StorageValue::List(list) => list,
                _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            };

            if list.is_empty() {
                return Ok(None);
            }

            let popped = list.pop_back().unwrap();

            // Remove source key if list is empty
            let should_delete = list.is_empty();
            if should_delete {
                db_map.remove(source_key);
            }

            popped
        };

        // Push to destination
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check destination type
        if let Some(value) = db_map.get(dest_key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        let dest_list = db_map
            .entry(Bytes::new(dest_key))
            .or_insert_with(|| StorageValue::List(Vector::new()));

        let dest_list = match dest_list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        dest_list.push_front(popped.clone());

        Ok(Some(popped))
    }

    // Hash operations

    /// Set field in hash to value. Creates hash if it doesn't exist.
    pub fn hset(&mut self, db: u64, key: &[u8], field: &[u8], value: &[u8]) -> Result<bool, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::Hash(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the hash
        let hash = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::Hash(BTreeMap::new()));

        let hash = match hash {
            StorageValue::Hash(h) => h,
            _ => unreachable!(),
        };

        // Insert returns None if field didn't exist (new field)
        let is_new = hash.insert(Bytes::new(field), Bytes::new(value)).is_none();
        Ok(is_new)
    }

    /// Set multiple fields in hash. Returns number of new fields added.
    pub fn hmset(&mut self, db: u64, key: &[u8], fields: &[(&[u8], &[u8])]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::Hash(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the hash
        let hash = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::Hash(BTreeMap::new()));

        let hash = match hash {
            StorageValue::Hash(h) => h,
            _ => unreachable!(),
        };

        let mut new_fields = 0;
        for (field, value) in fields {
            if hash.insert(Bytes::new(field), Bytes::new(value)).is_none() {
                new_fields += 1;
            }
        }

        Ok(new_fields)
    }

    /// Get field value from hash. Returns None if key or field doesn't exist.
    pub fn hget(&self, db: u64, key: &[u8], field: &[u8]) -> Result<Option<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.get(field).cloned()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get multiple field values from hash.
    pub fn hmget(&self, db: u64, key: &[u8], fields: &[&[u8]]) -> Result<Vec<Option<Bytes>>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                let values = fields.iter().map(|field| hash.get(*field).cloned()).collect();
                Ok(values)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => {
                // Return vec of None for each field
                Ok(vec![None; fields.len()])
            }
        }
    }

    /// Get all field-value pairs from hash.
    pub fn hgetall(&self, db: u64, key: &[u8]) -> Result<Vec<(Bytes, Bytes)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                let pairs = hash.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
                Ok(pairs)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get all field names from hash.
    pub fn hkeys(&self, db: u64, key: &[u8]) -> Result<Vec<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.keys().cloned().collect()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get all values from hash.
    pub fn hvals(&self, db: u64, key: &[u8]) -> Result<Vec<Bytes>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.values().cloned().collect()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get number of fields in hash.
    pub fn hlen(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.len()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Check if field exists in hash.
    pub fn hexists(&self, db: u64, key: &[u8], field: &[u8]) -> Result<bool, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.contains_key(field)),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(false),
        }
    }

    /// Delete fields from hash. Returns number of fields deleted.
    pub fn hdel(&mut self, db: u64, key: &[u8], fields: &[&[u8]]) -> Result<usize, &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(0);
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(0);
        };

        let hash = match value {
            StorageValue::Hash(hash) => hash,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        let mut deleted = 0;
        for field in fields {
            if hash.remove(*field).is_some() {
                deleted += 1;
            }
        }

        // Remove key if hash is empty
        if hash.is_empty() {
            db_map.remove(key);
        }

        Ok(deleted)
    }

    // Sorted set (zset) operations

    /// Add members with scores to sorted set. Returns number of new members added.
    pub fn zadd(&mut self, db: u64, key: &[u8], members: &[(Score, &[u8])]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::ZSet(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the zset
        let zset = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::ZSet(ZSet::new()));

        let zset = match zset {
            StorageValue::ZSet(z) => z,
            _ => unreachable!(),
        };

        let mut added = 0;
        for (score, member) in members {
            // Check if member exists - use direct HashMap lookup with &[u8]
            if let Some(old_score) = zset.entries.get(*member) {
                // Member exists - update score
                // Use ZSetIndexKeyRef for lookup
                let lookup_key = ZSetIndexKeyRef::lookup_key_ref(*old_score, member);
                zset.index.remove(&lookup_key);

                zset.entries.insert(Bytes::new(member), *score);
                // Use ZSetIndexKeyN for insertion
                zset.index.insert(ZSetIndexKeyN::create(*score, member));
            } else {
                // New member
                added += 1;
                zset.entries.insert(Bytes::new(member), *score);
                // Use ZSetIndexKeyN for insertion
                zset.index.insert(ZSetIndexKeyN::create(*score, member));
            }
        }

        Ok(added)
    }

    /// Remove members from sorted set. Returns number of members removed.
    pub fn zrem(&mut self, db: u64, key: &[u8], members: &[&[u8]]) -> Result<usize, &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(0);
        };

        let Some(value) = db_map.get_mut(key) else {
            return Ok(0);
        };

        let zset = match value {
            StorageValue::ZSet(zset) => zset,
            _ => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
        };

        let mut removed = 0;
        for member in members {
            // Use direct HashMap removal with &[u8]
            if let Some(score) = zset.entries.remove(*member) {
                // Use ZSetIndexKeyRef for removal
                let lookup_key = ZSetIndexKeyRef::lookup_key_ref(score, member);
                zset.index.remove(&lookup_key);
                removed += 1;
            }
        }

        // Remove key if zset is empty
        if zset.is_empty() {
            db_map.remove(key);
        }

        Ok(removed)
    }

    /// Get the score of a member in sorted set.
    pub fn zscore(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<Score>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => Ok(zset.entries.get(member).copied()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the cardinality (number of members) of sorted set.
    pub fn zcard(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => Ok(zset.len()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Get range of members by index (rank). Supports negative indices.
    /// Returns list of (member, score) tuples.
    pub fn zrange(&self, db: u64, key: &[u8], start: i64, stop: i64, with_scores: bool) -> Result<Vec<(Bytes, Option<Score>)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                let len = zset.len() as i64;

                if len == 0 {
                    return Ok(Vec::new());
                }

                // Normalize negative indices
                let start_pos = if start < 0 {
                    (len + start).max(0) as usize
                } else {
                    start.min(len - 1).max(0) as usize
                };

                let stop_pos = if stop < 0 {
                    (len + stop).max(0) as usize
                } else {
                    stop.min(len - 1).max(0) as usize
                };

                if start_pos > stop_pos || start_pos >= len as usize {
                    return Ok(Vec::new());
                }

                // Use indexset's efficient range_idx() method for O(log n) range access
                let result: Vec<(Bytes, Option<Score>)> = zset
                    .index
                    .range_idx(start_pos..=stop_pos)
                    .filter_map(|key| {
                        // Clone the Arc-wrapped Bytes directly instead of reconstructing
                        key.get_entry_and_score().map(|(entry, score)| {
                            if with_scores {
                                (entry, Some(score))
                            } else {
                                (entry, None)
                            }
                        })
                    })
                    .collect();

                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get range of members by score. Returns list of (member, score) tuples.
    /// Optimized to use BTreeSet::range() for O(log n + k) instead of O(n) where k is result size.
    pub fn zrangebyscore(&self, db: u64, key: &[u8], min: Score, max: Score, with_scores: bool) -> Result<Vec<(Bytes, Option<Score>)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                // Create boundary keys for efficient range query
                let min_key = ZSetIndexKeyN::min_score_key(min);
                let max_key = ZSetIndexKeyN::max_score_key(max);

                // Use range() for O(log n) seek + O(k) iteration, avoiding full tree scan
                // Explicitly specify the query type to resolve type inference
                let result: Vec<(Bytes, Option<Score>)> = zset
                    .index
                    .range::<_, ZSetIndexKeyN>((Bound::Included(&min_key), Bound::Included(&max_key)))
                    .filter_map(|key| {
                        // Clone the Arc-wrapped Bytes directly instead of reconstructing
                        key.get_entry_and_score().map(|(entry, score)| {
                            if with_scores {
                                (entry, Some(score))
                            } else {
                                (entry, None)
                            }
                        })
                    })
                    .collect();

                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get the rank (index) of a member in sorted set (0-based, ascending order).
    pub fn zrank(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<usize>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                // Use direct HashMap lookup for score with &[u8]
                let Some(score) = zset.entries.get(member) else {
                    return Ok(None);
                };

                // Use indexset's efficient rank() method - O(log n) instead of O(n)
                // Use ZSetIndexKeyRef for lookup
                let lookup_key = ZSetIndexKeyRef::lookup_key_ref(*score, member);
                let rank = zset.index.rank(&lookup_key);

                Ok(Some(rank))
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get the reverse rank (index from highest to lowest) of a member.
    pub fn zrevrank(&self, db: u64, key: &[u8], member: &[u8]) -> Result<Option<usize>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                // Use direct HashMap lookup for score with &[u8]
                let Some(score) = zset.entries.get(member) else {
                    return Ok(None);
                };

                // Use indexset's efficient rank() method, then convert to reverse rank
                // Reverse rank = (total_count - 1) - rank
                // Use ZSetIndexKeyRef for lookup
                let lookup_key = ZSetIndexKeyRef::lookup_key_ref(*score, member);
                let rank = zset.index.rank(&lookup_key);
                let rev_rank = zset.len() - 1 - rank;

                Ok(Some(rev_rank))
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Count members in sorted set with scores between min and max (inclusive).
    /// Optimized to use rank difference instead of iteration: O(log n) instead of O(n).
    pub fn zcount(&self, db: u64, key: &[u8], min: Score, max: Score) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                // Create boundary keys for the score range
                let min_key = ZSetIndexKeyN::min_score_key(min);
                let max_key = ZSetIndexKeyN::max_score_key(max);

                // Get ranks: min_rank is where first element >= min starts,
                // max_rank is where last element <= max ends
                let min_rank = zset.index.rank(&min_key);
                let max_rank = zset.index.rank(&max_key);

                // Count is the difference of ranks
                // Handle inverted range (min > max) by returning 0
                if max_rank < min_rank {
                    Ok(0)
                } else {
                    Ok(max_rank - min_rank)
                }
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }

    /// Increment the score of a member by delta. Creates member if it doesn't exist.
    pub fn zincrby(&mut self, db: u64, key: &[u8], delta: Score, member: &[u8]) -> Result<Score, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::ZSet(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the zset
        let zset = db_map
            .entry(Bytes::new(key))
            .or_insert_with(|| StorageValue::ZSet(ZSet::new()));

        let zset = match zset {
            StorageValue::ZSet(z) => z,
            _ => unreachable!(),
        };

        // Use direct HashMap lookup for old score with &[u8]
        let old_score = zset.entries.get(member).copied().unwrap_or(OrderedFloat(0.0));
        let new_score = old_score + delta;

        // Remove old index entry if member existed
        if old_score != OrderedFloat(0.0) || zset.entries.contains_key(member) {
            // Use ZSetIndexKeyRef for removal
            let lookup_key = ZSetIndexKeyRef::lookup_key_ref(old_score, member);
            zset.index.remove(&lookup_key);
        }

        // Add new entries
        zset.entries.insert(Bytes::new(member), new_score);
        // Use ZSetIndexKeyN for insertion
        zset.index.insert(ZSetIndexKeyN::create(new_score, member));

        Ok(new_score)
    }
}
