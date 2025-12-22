use std::collections::BTreeMap;

/// Inner storage structure
pub struct StorageInner {
    map: BTreeMap<Vec<u8>, Vec<u8>>,
}

impl StorageInner {
    /// Create a new empty storage
    pub fn new() -> Self {
        StorageInner {
            map: BTreeMap::new(),
        }
    }

    /// Set a key-value pair
    pub fn set(&mut self, key: &[u8], value: &[u8]) {
        self.map.insert(key.to_vec(), value.to_vec());
    }

    /// Get a value by key
    pub fn get(&self, key: &[u8]) -> Option<&[u8]> {
        self.map.get(key).map(|v| v.as_slice())
    }

    /// Delete a key
    pub fn del(&mut self, key: &[u8]) {
        self.map.remove(key);
    }

    /// Clear all entries
    pub fn clear(&mut self) {
        self.map.clear();
    }
}
