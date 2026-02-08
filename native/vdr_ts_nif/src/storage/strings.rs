use super::bytes::Bytes;
use super::types::StorageValue;
use crate::storage::StorageInner;
use std::collections::btree_map::Entry as BTreeEntry;
use std::collections::BTreeMap;

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
            Some(StorageValue::Set(_))
            | Some(StorageValue::List(_))
            | Some(StorageValue::Hash(_))
            | Some(StorageValue::ZSet(_)) => {
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
    #[allow(dead_code)]
    pub fn pexpireat(
        &mut self,
        _db: u64,
        _key: &[u8],
        _timestamp_ms: i64,
    ) -> Result<(), &'static str> {
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
    pub fn renamenx(
        &mut self,
        db: u64,
        old_key: &[u8],
        new_key: &[u8],
    ) -> Result<(), &'static str> {
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
    pub fn move_key(
        &mut self,
        source_db: u64,
        dest_db: u64,
        key: &[u8],
    ) -> Result<(), &'static str> {
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

    /// Copy a key to another key. If replace is false, won't overwrite existing destination.
    pub fn copy_key(
        &mut self,
        db: u64,
        source: &[u8],
        destination: &[u8],
        replace: bool,
    ) -> Result<(), &'static str> {
        let Some(db_map) = self.map.get_mut(&db) else {
            return Ok(());
        };

        // Check if destination already exists and replace is false
        if !replace && db_map.contains_key(destination) {
            return Ok(());
        }

        // Get source value and clone it
        let Some(value) = db_map.get(source) else {
            return Ok(());
        };
        let cloned_value = value.clone();

        // Insert at destination
        db_map.insert(Bytes::new(destination), cloned_value);
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
                    _ => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
                }
            }
            BTreeEntry::Vacant(e) => {
                // Key doesn't exist, create it
                e.insert(StorageValue::String(Bytes::new(value)));
                Ok(())
            }
        }
    }

    /// Overwrite part of a string at the specified offset.
    /// If the key doesn't exist, creates it with zero-byte padding.
    /// If the offset is beyond the current string length, pads with zero bytes.
    pub fn setrange(
        &mut self,
        db: u64,
        key: &[u8],
        offset: usize,
        value: &[u8],
    ) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        match db_map.entry(Bytes::new(key)) {
            BTreeEntry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::String(existing) => {
                        let mut bytes = existing.as_slice().to_vec();
                        let end_pos = offset + value.len();

                        // Extend with zero bytes if needed
                        if end_pos > bytes.len() {
                            bytes.resize(end_pos, 0);
                        }

                        // Overwrite bytes at offset
                        bytes[offset..end_pos].copy_from_slice(value);
                        *existing = Bytes::new(&bytes);
                        Ok(())
                    }
                    _ => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
                }
            }
            BTreeEntry::Vacant(e) => {
                // Key doesn't exist, create with zero-byte padding
                let end_pos = offset + value.len();
                let mut bytes = vec![0u8; end_pos];
                bytes[offset..end_pos].copy_from_slice(value);
                e.insert(StorageValue::String(Bytes::new(&bytes)));
                Ok(())
            }
        }
    }

    /// Increment the integer value of a key by 1. Creates key if it doesn't exist (starting from 0).
    pub fn incr(&mut self, db: u64, key: &[u8]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        match db_map.entry(Bytes::new(key)) {
            BTreeEntry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::String(existing) => {
                        // Parse current value as integer
                        let current_str = String::from_utf8_lossy(existing.as_slice());
                        let current: i64 = current_str
                            .parse()
                            .map_err(|_| "value is not an integer or out of range")?;

                        let new_value = current.checked_add(1).ok_or("increment would overflow")?;

                        *existing = Bytes::new(new_value.to_string().as_bytes());
                        Ok(())
                    }
                    _ => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
                }
            }
            BTreeEntry::Vacant(e) => {
                // Key doesn't exist, start from 0 and increment to 1
                e.insert(StorageValue::String(Bytes::new(b"1")));
                Ok(())
            }
        }
    }

    /// Increment the integer value of a key by the given amount. Creates key if it doesn't exist (starting from 0).
    pub fn incrby(&mut self, db: u64, key: &[u8], increment: i64) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        match db_map.entry(Bytes::new(key)) {
            BTreeEntry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::String(existing) => {
                        // Parse current value as integer
                        let current_str = String::from_utf8_lossy(existing.as_slice());
                        let current: i64 = current_str
                            .parse()
                            .map_err(|_| "value is not an integer or out of range")?;

                        let new_value = current
                            .checked_add(increment)
                            .ok_or("increment would overflow")?;

                        *existing = Bytes::new(new_value.to_string().as_bytes());
                        Ok(())
                    }
                    _ => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
                }
            }
            BTreeEntry::Vacant(e) => {
                // Key doesn't exist, start from 0 and add increment
                e.insert(StorageValue::String(Bytes::new(
                    increment.to_string().as_bytes(),
                )));
                Ok(())
            }
        }
    }

    /// Decrement the integer value of a key by 1. Creates key if it doesn't exist (starting from 0).
    pub fn decr(&mut self, db: u64, key: &[u8]) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        match db_map.entry(Bytes::new(key)) {
            BTreeEntry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::String(existing) => {
                        // Parse current value as integer
                        let current_str = String::from_utf8_lossy(existing.as_slice());
                        let current: i64 = current_str
                            .parse()
                            .map_err(|_| "value is not an integer or out of range")?;

                        let new_value = current.checked_sub(1).ok_or("decrement would overflow")?;

                        *existing = Bytes::new(new_value.to_string().as_bytes());
                        Ok(())
                    }
                    _ => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
                }
            }
            BTreeEntry::Vacant(e) => {
                // Key doesn't exist, start from 0 and decrement to -1
                e.insert(StorageValue::String(Bytes::new(b"-1")));
                Ok(())
            }
        }
    }

    /// Decrement the integer value of a key by the given amount. Creates key if it doesn't exist (starting from 0).
    pub fn decrby(&mut self, db: u64, key: &[u8], decrement: i64) -> Result<(), &'static str> {
        let db_map = self.map.entry(db).or_insert_with(BTreeMap::new);

        match db_map.entry(Bytes::new(key)) {
            BTreeEntry::Occupied(mut e) => {
                match e.get_mut() {
                    StorageValue::String(existing) => {
                        // Parse current value as integer
                        let current_str = String::from_utf8_lossy(existing.as_slice());
                        let current: i64 = current_str
                            .parse()
                            .map_err(|_| "value is not an integer or out of range")?;

                        let new_value = current
                            .checked_sub(decrement)
                            .ok_or("decrement would overflow")?;

                        *existing = Bytes::new(new_value.to_string().as_bytes());
                        Ok(())
                    }
                    _ => Err("WRONGTYPE Operation against a key holding the wrong kind of value"),
                }
            }
            BTreeEntry::Vacant(e) => {
                // Key doesn't exist, start from 0 and subtract decrement
                let neg_decrement = decrement.checked_neg().ok_or("decrement would overflow")?;
                e.insert(StorageValue::String(Bytes::new(
                    neg_decrement.to_string().as_bytes(),
                )));
                Ok(())
            }
        }
    }

    /// Clear all entries from all databases
    pub fn clear(&mut self) {
        self.map.clear();
    }

    /// Clear all entries from all databases (FLUSHALL)
    pub fn flushall(&mut self) -> Result<(), &'static str> {
        self.map.clear();
        Ok(())
    }

    /// Clear all entries from a specific database (FLUSHDB)
    pub fn flushdb(&mut self, db: u64) -> Result<(), &'static str> {
        self.map.remove(&db);
        Ok(())
    }

    /// Swap the contents of two databases (SWAPDB)
    pub fn swapdb(&mut self, db1: u64, db2: u64) -> Result<(), &'static str> {
        // Get db1 content (or empty map if doesn't exist)
        let content1 = self.map.remove(&db1);
        // Get db2 content (or empty map if doesn't exist)
        let content2 = self.map.remove(&db2);

        // Swap: insert db1 content into db2, and db2 content into db1
        if let Some(c1) = content1 {
            self.map.insert(db2, c1);
        }
        if let Some(c2) = content2 {
            self.map.insert(db1, c2);
        }

        Ok(())
    }
}
