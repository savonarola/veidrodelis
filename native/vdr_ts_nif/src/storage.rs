use std::collections::{BTreeMap, BTreeSet};

/// Storage value types
#[derive(Clone)]
pub enum StorageValue {
    String(Vec<u8>),
    Set(BTreeSet<Vec<u8>>),
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
            Some(StorageValue::Set(_)) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
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
            StorageValue::String(_) => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
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
            Some(StorageValue::String(_)) => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => return Ok(false),
        };

        if !member_existed {
            return Ok(false);
        }

        // Check if source set is now empty and should be deleted
        let should_delete_source = match db_map.get(source_key) {
            Some(StorageValue::Set(set)) => set.is_empty(),
            _ => false,
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
                    StorageValue::String(_) => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
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
                        StorageValue::String(_) => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
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
            Some(StorageValue::String(_)) => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => BTreeSet::new(),
        };

        // Intersect with remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(source_key.as_slice()) {
                Some(StorageValue::Set(set)) => {
                    intersection_set = intersection_set.intersection(set).cloned().collect();
                }
                Some(StorageValue::String(_)) => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
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
            Some(StorageValue::String(_)) => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => BTreeSet::new(),
        };

        // Subtract remaining sets
        for source_key in &source_keys[1..] {
            match db_map.get(source_key.as_slice()) {
                Some(StorageValue::Set(set)) => {
                    diff_set = diff_set.difference(set).cloned().collect();
                }
                Some(StorageValue::String(_)) => return Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
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
            Some(StorageValue::String(_)) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(Vec::new()),
        }
    }

    /// Check if member exists in set.
    pub fn sismember(&self, db: u64, key: &[u8], member: &[u8]) -> Result<bool, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Set(set)) => Ok(set.contains(member)),
            Some(StorageValue::String(_)) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(false),
        }
    }

    /// Get the number of members in a set.
    pub fn scard(&self, db: u64, key: &[u8]) -> Result<usize, &'static str> {
        match self.map.get(&db).and_then(|db_map| db_map.get(key)) {
            Some(StorageValue::Set(set)) => Ok(set.len()),
            Some(StorageValue::String(_)) => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
            None => Ok(0),
        }
    }
}
