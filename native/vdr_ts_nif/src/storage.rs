use std::collections::{BTreeMap, BTreeSet};
use std::cmp::Ordering;
use im::Vector;

type Score = f64;

/// Ordered wrapper for f64 to use in BTreeSet
/// Treats NaN as equal to NaN and less than all other values
#[derive(Clone, Copy, Debug)]
struct OrderedFloat(f64);

impl OrderedFloat {
    fn new(f: f64) -> Self {
        OrderedFloat(f)
    }

    fn get(&self) -> f64 {
        self.0
    }
}

impl PartialEq for OrderedFloat {
    fn eq(&self, other: &Self) -> bool {
        self.0 == other.0 || (self.0.is_nan() && other.0.is_nan())
    }
}

impl Eq for OrderedFloat {}

impl PartialOrd for OrderedFloat {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for OrderedFloat {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self.0.is_nan(), other.0.is_nan()) {
            (true, true) => Ordering::Equal,
            (true, false) => Ordering::Less,
            (false, true) => Ordering::Greater,
            (false, false) => self.0.partial_cmp(&other.0).unwrap(),
        }
    }
}

/// Sorted set (zset) data structure
/// Maintains both a sorted index and a member->score map for efficient operations
#[derive(Clone)]
pub struct ZSet {
    /// Sorted index for range queries and sorted iteration
    /// Ordered by (score, member) to handle duplicate scores
    index: BTreeSet<(OrderedFloat, Vec<u8>)>,
    /// Member to score mapping for quick lookups
    entries: BTreeMap<Vec<u8>, Score>,
}

impl ZSet {
    fn new() -> Self {
        ZSet {
            index: BTreeSet::new(),
            entries: BTreeMap::new(),
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
#[derive(Clone)]
pub enum StorageValue {
    String(Vec<u8>),
    Set(BTreeSet<Vec<u8>>),
    List(Vector<Vec<u8>>),
    Hash(BTreeMap<Vec<u8>, Vec<u8>>),
    ZSet(ZSet),
}

/// Inner storage structure
pub struct StorageInner {
    map: BTreeMap<u64, BTreeMap<Vec<u8>, StorageValue>>,
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
        db_map.insert(key.to_vec(), StorageValue::String(value.to_vec()));
    }

    /// Get a value by key from a specific database
    pub fn get(&self, db: u64, key: &[u8]) -> Result<Option<&[u8]>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::String(value)) => Ok(Some(value.as_slice())),
            Some(StorageValue::Set(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) | Some(StorageValue::ZSet(_)) => {
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
    pub fn sadd(&mut self, db: u64, key: &[u8], members: &[Vec<u8>]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::Set(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the set
        let set = db_map
            .entry(key.to_vec())
            .or_insert_with(|| StorageValue::Set(BTreeSet::new()));

        // Extract the set from the StorageValue
        let set = match set {
            StorageValue::Set(s) => s,
            _ => unreachable!(), // We already validated the type above
        };

        let mut added = 0;
        for member in members {
            if set.insert(member.clone()) {
                added += 1;
            }
        }

        Ok(added)
    }

    /// Remove members from a set. Removes key if set becomes empty.
    pub fn srem(&mut self, db: u64, key: &[u8], members: &[Vec<u8>]) -> Result<usize, &'static str> {
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
            if set.remove(member) {
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

        // Check and remove member from source set
        let member_existed = match db_map.get_mut(source_key) {
            Some(StorageValue::Set(set)) => {
                let existed = set.remove(member);
                if existed && set.is_empty() {
                    // Mark for deletion by setting a flag
                    true
                } else {
                    existed
                }
            }
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => return Ok(false),
        };

        if !member_existed {
            return Ok(false);
        }

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
        match db_map.entry(dest_key.to_vec()) {
            std::collections::btree_map::Entry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::Set(set) => {
                        set.insert(member.to_vec());
                    }
                    StorageValue::String(_) | StorageValue::List(_) | StorageValue::Hash(_) | StorageValue::ZSet(_) => {
                        return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                    }
                }
            }
            std::collections::btree_map::Entry::Vacant(e) => {
                let mut new_set = BTreeSet::new();
                new_set.insert(member.to_vec());
                e.insert(StorageValue::Set(new_set));
            }
        }

        Ok(true)
    }

    /// Store union of multiple sets in destination key.
    pub fn sunionstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[Vec<u8>]) -> Result<usize, &'static str> {
        // First delete destination
        self.del(db, dest_key);

        // Collect all unique members from source sets
        let mut union_set = BTreeSet::new();

        if let Some(db_map) = self.map.get(&db) {
            for source_key in source_keys {
                if let Some(value) = db_map.get(source_key.as_slice()) {
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
            db_map.insert(dest_key.to_vec(), StorageValue::Set(union_set));
        }

        Ok(cardinality)
    }

    /// Store intersection of multiple sets in destination key.
    pub fn sinterstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[Vec<u8>]) -> Result<usize, &'static str> {
        // First delete destination
        self.del(db, dest_key);

        if source_keys.is_empty() {
            return Ok(0);
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        // Start with first set
        let mut intersection_set = match db_map.get(source_keys[0].as_slice()) {
            Some(StorageValue::Set(set)) => set.clone(),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => BTreeSet::new(),
        };

        // Intersect with remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(source_key.as_slice()) {
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
            db_map.insert(dest_key.to_vec(), StorageValue::Set(intersection_set));
        }

        Ok(cardinality)
    }

    /// Store difference of sets in destination key.
    pub fn sdiffstore(&mut self, db: u64, dest_key: &[u8], source_keys: &[Vec<u8>]) -> Result<usize, &'static str> {
        // First delete destination
        self.del(db, dest_key);

        if source_keys.is_empty() {
            return Ok(0);
        }

        let Some(db_map) = self.map.get(&db) else {
            return Ok(0);
        };

        // Start with first set
        let mut diff_set = match db_map.get(source_keys[0].as_slice()) {
            Some(StorageValue::Set(set)) => set.clone(),
            Some(StorageValue::String(_)) | Some(StorageValue::List(_)) | Some(StorageValue::Hash(_)) | Some(StorageValue::ZSet(_)) => {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value")
            }
            None => BTreeSet::new(),
        };

        // Subtract remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(source_key.as_slice()) {
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
            db_map.insert(dest_key.to_vec(), StorageValue::Set(diff_set));
        }

        Ok(cardinality)
    }

    /// Get all members of a set.
    pub fn smembers(&self, db: u64, key: &[u8]) -> Result<Vec<Vec<u8>>, &'static str> {
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
    pub fn lpush(&mut self, db: u64, key: &[u8], values: &[Vec<u8>]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the list
        let list = db_map
            .entry(key.to_vec())
            .or_insert_with(|| StorageValue::List(Vector::new()));

        // Extract the list from the StorageValue
        let list = match list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        // Push values to the front in order (each one becomes the new head)
        for value in values {
            list.push_front(value.clone());
        }

        Ok(list.len())
    }

    /// Push elements to the right (tail) of the list.
    pub fn rpush(&mut self, db: u64, key: &[u8], values: &[Vec<u8>]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(value) = db_map.get(key) {
            if !matches!(value, StorageValue::List(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the list
        let list = db_map
            .entry(key.to_vec())
            .or_insert_with(|| StorageValue::List(Vector::new()));

        // Extract the list from the StorageValue
        let list = match list {
            StorageValue::List(l) => l,
            _ => unreachable!(),
        };

        // Push values to the back
        for value in values {
            list.push_back(value.clone());
        }

        Ok(list.len())
    }

    /// Pop element from the left (head) of the list. Returns the element or None.
    pub fn lpop(&mut self, db: u64, key: &[u8]) -> Result<Option<Vec<u8>>, &'static str> {
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
    pub fn rpop(&mut self, db: u64, key: &[u8]) -> Result<Option<Vec<u8>>, &'static str> {
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
    pub fn lrange(&self, db: u64, key: &[u8], start: i64, stop: i64) -> Result<Vec<Vec<u8>>, &'static str> {
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

                let result: Vec<Vec<u8>> = list
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

        *list = list.update(pos as usize, value.to_vec());
        Ok(true)
    }

    /// Atomically pop from the right of source and push to the left of destination.
    pub fn rpoplpush(&mut self, db: u64, source_key: &[u8], dest_key: &[u8]) -> Result<Option<Vec<u8>>, &'static str> {
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
            .entry(dest_key.to_vec())
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
            .entry(key.to_vec())
            .or_insert_with(|| StorageValue::Hash(BTreeMap::new()));

        let hash = match hash {
            StorageValue::Hash(h) => h,
            _ => unreachable!(),
        };

        // Insert returns None if field didn't exist (new field)
        let is_new = hash.insert(field.to_vec(), value.to_vec()).is_none();
        Ok(is_new)
    }

    /// Set multiple fields in hash. Returns number of new fields added.
    pub fn hmset(&mut self, db: u64, key: &[u8], fields: &[(Vec<u8>, Vec<u8>)]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::Hash(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the hash
        let hash = db_map
            .entry(key.to_vec())
            .or_insert_with(|| StorageValue::Hash(BTreeMap::new()));

        let hash = match hash {
            StorageValue::Hash(h) => h,
            _ => unreachable!(),
        };

        let mut new_fields = 0;
        for (field, value) in fields {
            if hash.insert(field.clone(), value.clone()).is_none() {
                new_fields += 1;
            }
        }

        Ok(new_fields)
    }

    /// Get field value from hash. Returns None if key or field doesn't exist.
    pub fn hget(&self, db: u64, key: &[u8], field: &[u8]) -> Result<Option<Vec<u8>>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.get(field).cloned()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Get multiple field values from hash.
    pub fn hmget(&self, db: u64, key: &[u8], fields: &[Vec<u8>]) -> Result<Vec<Option<Vec<u8>>>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => {
                let values = fields.iter().map(|field| hash.get(field).cloned()).collect();
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
    pub fn hgetall(&self, db: u64, key: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>, &'static str> {
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
    pub fn hkeys(&self, db: u64, key: &[u8]) -> Result<Vec<Vec<u8>>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Hash(hash)) => Ok(hash.keys().cloned().collect()),
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get all values from hash.
    pub fn hvals(&self, db: u64, key: &[u8]) -> Result<Vec<Vec<u8>>, &'static str> {
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
    pub fn hdel(&mut self, db: u64, key: &[u8], fields: &[Vec<u8>]) -> Result<usize, &'static str> {
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
            if hash.remove(field).is_some() {
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
    pub fn zadd(&mut self, db: u64, key: &[u8], members: &[(Score, Vec<u8>)]) -> Result<usize, &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        // Check if key exists and validate type
        if let Some(val) = db_map.get(key) {
            if !matches!(val, StorageValue::ZSet(_)) {
                return Err("WRONGTYPE Operation against a key holding the wrong kind of value");
            }
        }

        // Get or create the zset
        let zset = db_map
            .entry(key.to_vec())
            .or_insert_with(|| StorageValue::ZSet(ZSet::new()));

        let zset = match zset {
            StorageValue::ZSet(z) => z,
            _ => unreachable!(),
        };

        let mut added = 0;
        for (score, member) in members {
            // If member exists, remove old index entry
            if let Some(old_score) = zset.entries.get(member) {
                zset.index.remove(&(OrderedFloat::new(*old_score), member.clone()));
            } else {
                added += 1;
            }

            // Add new entries
            zset.entries.insert(member.clone(), *score);
            zset.index.insert((OrderedFloat::new(*score), member.clone()));
        }

        Ok(added)
    }

    /// Remove members from sorted set. Returns number of members removed.
    pub fn zrem(&mut self, db: u64, key: &[u8], members: &[Vec<u8>]) -> Result<usize, &'static str> {
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
            if let Some(score) = zset.entries.remove(member) {
                zset.index.remove(&(OrderedFloat::new(score), member.clone()));
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
    pub fn zrange(&self, db: u64, key: &[u8], start: i64, stop: i64, with_scores: bool) -> Result<Vec<(Vec<u8>, Option<Score>)>, &'static str> {
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

                let result: Vec<(Vec<u8>, Option<Score>)> = zset
                    .index
                    .iter()
                    .skip(start_pos)
                    .take(stop_pos - start_pos + 1)
                    .map(|(score, member)| {
                        if with_scores {
                            (member.clone(), Some(score.get()))
                        } else {
                            (member.clone(), None)
                        }
                    })
                    .collect();

                Ok(result)
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Get range of members by score. Returns list of (member, score) tuples.
    pub fn zrangebyscore(&self, db: u64, key: &[u8], min: Score, max: Score, with_scores: bool) -> Result<Vec<(Vec<u8>, Option<Score>)>, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                let min_ord = OrderedFloat::new(min);
                let max_ord = OrderedFloat::new(max);
                let result: Vec<(Vec<u8>, Option<Score>)> = zset
                    .index
                    .iter()
                    .filter(|(score, _)| *score >= min_ord && *score <= max_ord)
                    .map(|(score, member)| {
                        if with_scores {
                            (member.clone(), Some(score.get()))
                        } else {
                            (member.clone(), None)
                        }
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
                // Get the score for this member
                let Some(score) = zset.entries.get(member) else {
                    return Ok(None);
                };

                let score_ord = OrderedFloat::new(*score);
                let member_vec = member.to_vec();
                // Count how many entries come before this one
                let rank = zset
                    .index
                    .iter()
                    .take_while(|(s, m)| *s < score_ord || (*s == score_ord && m < &member_vec))
                    .count();

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
                // Get the score for this member
                let Some(score) = zset.entries.get(member) else {
                    return Ok(None);
                };

                let score_ord = OrderedFloat::new(*score);
                let member_vec = member.to_vec();
                // Count how many entries come after this one (in reverse order)
                let rev_rank = zset
                    .index
                    .iter()
                    .rev()
                    .take_while(|(s, m)| *s > score_ord || (*s == score_ord && m > &member_vec))
                    .count();

                Ok(Some(rev_rank))
            }
            Some(_) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(None),
        }
    }

    /// Count members in sorted set with scores between min and max (inclusive).
    pub fn zcount(&self, db: u64, key: &[u8], min: Score, max: Score) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::ZSet(zset)) => {
                let min_ord = OrderedFloat::new(min);
                let max_ord = OrderedFloat::new(max);
                let count = zset
                    .index
                    .iter()
                    .filter(|(score, _)| *score >= min_ord && *score <= max_ord)
                    .count();
                Ok(count)
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
            .entry(key.to_vec())
            .or_insert_with(|| StorageValue::ZSet(ZSet::new()));

        let zset = match zset {
            StorageValue::ZSet(z) => z,
            _ => unreachable!(),
        };

        // Get current score or default to 0.0
        let old_score = zset.entries.get(member).copied().unwrap_or(0.0);
        let new_score = old_score + delta;

        // Remove old index entry if exists
        if zset.entries.contains_key(member) {
            zset.index.remove(&(OrderedFloat::new(old_score), member.to_vec()));
        }

        // Add new entries
        zset.entries.insert(member.to_vec(), new_score);
        zset.index.insert((OrderedFloat::new(new_score), member.to_vec()));

        Ok(new_score)
    }
}
