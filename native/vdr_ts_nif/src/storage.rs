use std::collections::BTreeMap;

/// Inner storage structure
pub struct StorageInner {
    map: BTreeMap<u64, BTreeMap<Vec<u8>, Vec<u8>>>,
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
        db_map.insert(key.to_vec(), value.to_vec());
    }

    /// Get a value by key from a specific database
    pub fn get(&self, db: u64, key: &[u8]) -> Option<&[u8]> {
        self.map.get(&db).and_then(|db_map| db_map.get(key).map(|v| v.as_slice()))
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
}
