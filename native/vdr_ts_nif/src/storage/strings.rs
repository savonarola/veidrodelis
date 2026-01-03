use std::collections::BTreeMap;
use std::collections::btree_map::Entry as BTreeEntry;
use super::bytes::Bytes;
use super::types::StorageValue;
use crate::storage::StorageInner;

impl StorageInner {
    /// Set a key-value pair in a specific database
    pub fn set(&mut self, db: u64, key: &[u8], value: &[u8]) {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
        db_map.insert(Bytes::new(key), StorageValue::String(Bytes::new(value)));
    }

    /// Set multiple key-value pairs atomically in a specific database
    pub fn mset(&mut self, db: u64, pairs: &[(&[u8], &[u8])]) {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);
        for (key, value) in pairs {
            db_map.insert(Bytes::new(key), StorageValue::String(Bytes::new(value)));
        }
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

    /// Null handler for PEXPIREAT - accepts but ignores expiration timestamp
    /// In future, this could store expiration metadata and trigger background cleanup
    pub fn pexpireat(&mut self, _db: u64, _key: &[u8], _timestamp_ms: i64) -> Result<(), &'static str> {
        // For now, just accept and ignore the expiration
        // TODO: Implement actual expiration tracking and background cleanup
        Ok(())
    }

    /// Rename a key. Overwrites destination key if it exists.
    pub fn rename(&mut self, db: u64, old_key: &[u8], new_key: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        // Remove old key and get its value
        let Some(value) = db_map.remove(old_key) else {
            return Ok(());
        };

        // Insert at new key (overwrites if exists)
        db_map.insert(Bytes::new(new_key), value);
        Ok(())
    }

    /// Rename a key only if the new key doesn't exist.
    pub fn renamenx(&mut self, db: u64, old_key: &[u8], new_key: &[u8]) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        // Check if destination already exists
        if db_map.contains_key(new_key) {
            return Ok(());
        }

        // Remove old key and get its value
        let Some(value) = db_map.remove(old_key) else {
            return Ok(());
        };

        // Insert at new key
        db_map.insert(Bytes::new(new_key), value);
        Ok(())
    }

    /// Move a key from one database to another. Overwrites destination key if it exists.
    pub fn move_key(&mut self, source_db: u64, dest_db: u64, key: &[u8]) -> Result<(), &'static str> {
        // Get value from source db
        let value = {
            let Some(source_map) = self.map.get_mut(&source_db) else {
                return Ok(());
            };

            let Some(value) = source_map.remove(key) else {
                return Ok(());
            };

            value
        };

        // Insert into destination db
        let dest_map = self.map.entry(dest_db).or_insert_with(BTreeMap::new);
        dest_map.insert(Bytes::new(key), value);

        Ok(())
    }

    /// Append value to an existing string. Creates key if it doesn't exist.
    pub fn append(&mut self, db: u64, key: &[u8], value: &[u8]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        match db_map.entry(Bytes::new(key)) {
            BTreeEntry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::String(existing) => {
                        // Create new concatenated value
                        let mut new_bytes = existing.as_slice().to_vec();
                        new_bytes.extend_from_slice(value);
                        *existing = Bytes::new(&new_bytes);
                        Ok(())
                    }
                    _ => Err("WRONGTYPE Operation against a key holding the wrong kind of value")
                }
            }
            BTreeEntry::Vacant(e) => {
                // Key doesn't exist, create it
                e.insert(StorageValue::String(Bytes::new(value)));
                Ok(())
            }
        }
    }

    /// Clear all entries from all databases
    pub fn clear(&mut self) {
        self.map.clear();
    }
}
